# Application state machines

Audit baseline: `a41ffe9` (Sema 1.37.0). This file is the single inventory,
invariant register, transition reference, and issue ledger for this audit.
States below include implicit combinations of globals, not just enum values.
Function names are searchable evidence anchors; tests exercise production code.
Provider/runtime internals are outside this repository: their callbacks and
cancellation contracts are boundaries, not proof of provider-side exactly-once
execution. No live provider is needed by the regressions.

## Confirmed failures, ordered by impact

| Priority | Issue / grouped fix | Evidence before fix | Status |
| --- | --- | --- | --- |
| High | [#6](https://github.com/sema-lisp/sema-coder/issues/6): empty session / queue lifecycle | `state_machines_test`: removing the last queued input preserves it on disk; `/clear` with zero messages preserves queue/pause/session identity. `new-session!` timestamp+PID also permits same-millisecond ID reuse. Restored removed work may execute tools. | Fixed: empty updates are saved; explicit reset flag; timestamp/PID/sequence IDs. `state_machines_test`: 8 checks green; session/restore/audit suites: 58 checks green. |
| High for concurrent extensions | [#8](https://github.com/sema-lisp/sema-coder/issues/8): MCP attempt ownership | `mcp_races_test`: disconnect→late connect reconnects; changed endpoint→late connect publishes old tools; removed endpoint→late handle is leaked. Seven assertions fail with real MCP handles and deterministic channel barriers. Built-in modal calls are serialized; async extensions can overlap these public functions. | Fixed: per-attempt ownership, duplicate-connect guard and superseded-handle cleanup. `mcp_races_test`: 18 checks green (initially 7 failures); MCP/reconcile suites also pass. |
| Medium | [#7](https://github.com/sema-lisp/sema-coder/issues/7): executed input visibility | `state_machines_test`: direct+queued input both run, but only direct input has a user block. `on-enter` owns user rendering while queue drain bypasses it. Steers share the bypass. | Fixed: common turn entry owns the user block. Direct+queue and interrupt+steer assertions went red→green; state/controller/e2e suites pass 110 checks. |

| Medium | [#9](https://github.com/sema-lisp/sema-coder/issues/9): input action freshness | `event_boundaries_test` initially fails 3 assertions: actual Kitty release bytes insert text/quit; transcript mutation between drag move and release copies stale coordinates. Releases require a terminal reporting event types. | Fixed: ignore key-up; revalidate transcript version on release. 101 input/selection/decoder checks pass. |

## 1. Process and front-end lifecycle

Owners: `coder.sema`, `tui-run`, `run-turn`, `run-turn-streaming`.
States: boot, configured, one-shot prose/JSON, REPL idle/running, TUI
idle/running, shutting down, exited(success/failure).

| From | Event / guard | To / action |
| --- | --- | --- |
| Boot | help/version | Successful exit before provider setup |
| Boot | invalid CLI or absent key | Failure exit; JSON mode emits a structured failure |
| Boot | config/plugins/MCP/provider ready | Construct agent; choose front end |
| Configured | print prompt | Run one turn; emit response/result; exit |
| Configured | TTY / non-TTY | TUI / line REPL |
| REPL idle | prompt / slash command | Run turn / dispatch command; return idle |
| REPL idle | EOF or quit | Exit |
| TUI idle | submit / quit | Controller running / shutdown |
| TUI running | Ctrl-C | Request cancellation; app remains alive |
| Shutdown | normal TUI exit | Stop input, background monitor and children; restore terminal |

Invariants: only TUI persists conversations; structured stdout contains one JSON
result; command errors preserve the conversational map; raw/alt-screen terminal
guards restore terminal modes when their body exits. Abrupt OS termination
cannot guarantee cleanup or saving the active turn. REPL failures keep the last
successful history; they do not currently recover partial tool rounds.

## 2. Turn controller and streaming

Owner: `src/tui.sema` (`run-one-agent-turn!`, `run-agent-turn!`,
`request-interrupt-for!`, `pump-input!`); history repair: `src/turn.sema`.
States: idle; model streaming; tool executing; cancellation requested;
provider settled but reveal buffer draining; completed/interrupted/failed
terminal settlement; idle again. Terminal events are records, not durable
controller modes. `turn-controller-state` projects running/idle and model/tool;
it does not expose every substate separately.

| From | Event / guard | To / action |
| --- | --- | --- |
| Idle | direct/queued/steer input | Allocate turn ID; capture prior messages; busy; start runner and sibling pump |
| Model | text delta for active ID | Queue chunks for reveal and interrupted-history capture |
| Model | tool start | Flush reveal; reset round text; indexed running tool block |
| Tool | tool end | Set indexed block done/failed; clear tool index; new assistant target |
| Running | interrupt matching active ID | Record one cancel request; stop foreground processes; cancel task |
| Cancelling | repeated matching interrupt | Idempotent; steer may upgrade stop |
| Any | stale turn ID callback/interrupt | Ignore |
| Running/cancelling | runner returns successfully | Drain reveal; preserve prior metadata prefix; completed event + save |
| Cancelling | runner throws | Repair partial history/tool results; interruption marker; pause ordinary queue; interrupted event + save |
| Running | runner throws without user interrupt | Repair failed history; failed tool block/event + save |
| Terminal | settlement complete | Clear busy/active ID/interrupt/tool state; decide next input |

Invariants: one active turn; callbacks are fenced by ID; one terminal event per
turn; cancellation request is distinct from cancellation acknowledgment. A
success that wins the cancellation race remains completed. Unanswered tool
calls receive correlated terminal results before continuing; side effects may
be partial, so repair adds model-visible warning context and never retries a
tool automatically. Successful continuation keeps app-owned metadata on the
prior prefix (`continued-turn-messages`). Retry is a new turn, not reuse of an
old ID. `turn_control_test`, `turn_test`, and `e2e_test` cover stale callbacks,
repeated interrupts, failures, partial history and event order.

## 3. Input queue

Owners: `queue-insert`, `enqueue-input!`, `take-queued-input!`,
`run-agent-turn!`, `resume-input-queue!` in `src/tui.sema`.
States: empty, ready, paused; entries are follow-up or steer(target turn ID).
Steers are FIFO ahead of FIFO ordinary follow-ups. Maximum 100 entries.

| From | Event / guard | To / action |
| --- | --- | --- |
| Running | Tab with nonblank prompt, palette closed | Enqueue durable ordinary input; clear composer |
| Running | Enter with nonblank prompt, palette closed | Save targeted steer before requesting cancellation |
| Any queue | insert at capacity | Reject visibly; retain composer |
| Ready/paused | edit/drop/clear | Preserve IDs/order when editing; persist removal; removing last follow-up clears pause |
| Turn completed/failed | queue unpaused | Dequeue first entry; execute it |
| Turn interrupted | ordinary follow-ups exist | Pause ordinary work; run only steers targeting that turn |
| Interrupted | several accepted steers for same ID | Join in FIFO order into one replacement turn |
| Paused | explicit `/queue resume` | Unpause, save, and run oldest input while idle |
| Idle | restored queue | Keep saved entries; execution needs resume or subsequent turn drain |

Invariants: no rejected prompt is silently removed; steer input is persisted
before cancel; ordinary work stays paused after an interrupted turn, including
a successful replacement. Every executed input needs one visible user block.
Queue removal must be reflected on disk even with zero committed messages
(issue #6). A dequeued item is active work, not a durable future entry: process
crash after dequeue and before terminal save can lose that active turn. There
is no crash replay or exactly-once side-effect contract.

## 4. Session identity, storage, and restore

Owners: `new-session!`, `persist-session!`, `restore-session!`,
`tui-state`/`apply-tui-state!`, `session-restore-fields`, `src/session.sema`.
States: fresh unsaved; persisted messages and/or queue; empty persisted update;
restored; renamed; deleted; failed save (warning latched).

| From | Event / guard | To / action |
| --- | --- | --- |
| Boot/clear | new session | New identity, created time, empty queue/events/title; session-start hook |
| Fresh | no messages/queue | Do not create a new empty file |
| Fresh/persisted | turn terminal or queue mutation | Serialize metadata/messages to temporary file then rename |
| Persisted | clear last queue entry, zero messages | Persist empty update; never leave previous queue on disk |
| Idle | resume ID | Build agent/fields; restore exact messages, model, effort, queue/pause/title/events; rebuild transcript |
| Persisted | rename valid nonempty title | Rewrite with normalized durable title |
| Persisted | delete nonactive ID | Delete file; active session is protected in command/modal |
| Save | I/O failure | Preserve old file; warn once per session; later saves still retry |
| Save beyond cap | prune | Keep newest 200 by creation timestamp |

Invariants: filename is authoritative ID; IDs cannot be paths; a fresh identity
must be unique within a process as well as across processes; clear resets queue
and metadata even when message count is already zero. Restore is not clear.
JSON event keywords are normalized on restore. Rename preserves history.
Atomic replacement protects readers against a partially written destination;
it does not provide multi-process transaction isolation for two instances
editing the same restored session. Saved files are trusted local application
data, not schema-validated imports. Session/restore/audit regressions cover the
normal persisted shape; issue #6 adds queue-only lifecycle coverage.

## 5. MCP connection attempts

Owner: `src/mcp.sema`; callers: boot/apply-config and MCP overlay.
States: absent, idle, connecting, connected, needs-auth, error.
Record fields: endpoint opts, transport, handle, tools, error, autostart.

| From | Event / guard | To / action |
| --- | --- | --- |
| Absent | declared | Idle record |
| Idle/error/needs-auth | explicit connect | Connecting; clear old handle/tools/error; bounded handshake |
| Connected with handle | connect again | No-op; preserve handle |
| Connecting | connect again | Return connecting without starting a competing owner |
| Connecting | handshake + tool conversion succeeds, still current | Connected with handle/tools |
| Connecting | timeout/handshake/tool conversion error | Error or needs-auth; close acquired handle; empty tools |
| Any existing | disconnect | Close handle; idle; invalidate pending completion |
| Any | reconcile identical endpoint | Preserve live state; update autostart |
| Any | endpoint changed / removed | Close old handle; new idle record / absent; invalidate pending completion |
| Idle + autostart | autostart pass | Connect once; failures await explicit retry |
| Superseded attempt | returns later | Close returned handle; never publish stale tools |

Invariants: connected implies a live handle; nonconnected records expose no
tools; one owner may publish per record generation. A timeout cancels the
handshake and closes a late-returned handle. `auth-error?` is a display/retry
heuristic, not authentication enforcement. Connection calls park at async
boundaries even though callers use a synchronous interface. The modal alone
serializes operations; extensions must be safe against overlapping runtime API
calls. `mcp_test` covers real connections/timeouts; `mcp_races_test` proves the
missing ownership fencing with real handles.

## 6. Foreground and background processes

Owner: `src/tools.sema`; notices: `handle-background-task-change!`.
Foreground states: spawned/registered, polling, exited/draining, timed out or
interrupted, closed/forgotten. Background states: running, settling, stopping,
completed/failed/stopped, evicted. Monitor: stopped/running.

| From | Event / guard | To / action |
| --- | --- | --- |
| Absent | foreground bash | Spawn, register handle, bounded poll/drain |
| Foreground running | exit | Wait for readers, collect tail, forget and close |
| Foreground running | deadline | Terminate process group, forget and close; timeout result |
| Foreground running | turn interrupt | Stop registered processes before task cancellation |
| Absent | background bash, room available | Spawn, close stdin, register stable task ID |
| Registry full | settled records exist / all active | Evict oldest settled / reject |
| Background running | poll sees leader exit | Settling with exit code; bounded reader-EOF wait |
| Settling | reader EOF / descendant holds pipe past deadline | Drain then close / cancel wait and kill group; terminal with cleanup warning |
| Running | stop | Stopping; drain, terminate, close; stopped |
| Settling | concurrent poll/finalizer sees busy native handle | Leave settling for owner/later poll |
| Terminal | output/list/stop again | Retain immutable outcome; no restart |
| Terminal | TUI notice callback | Announce once per ID; bounded notice bookkeeping |
| App shutdown/reset | active tasks | Stop monitor and all active processes; retain final records until reset |

Invariants: background tasks survive turn cancellation; foreground processes
do not. Active tasks cannot be evicted; streams retain bounded head/tail and
count omitted characters; native handle closed at terminal settlement. Unix
termination includes process group; Windows direct-child fallback is explicit.
Task IDs/output are process-local, never restored from sessions. Tests in
`tools_test` use real children, deadlines, output bounds and descendant cleanup.
Concurrent native waits use the host's busy error; terminal classification may
include a finalization error or forced-cleanup warning, so completed does not
promise all descendants exited naturally.

## 7. Config, registries, and agent/provider selection

Owners: `load-config` (`src/config.sema`), `apply-config!`/reconcile functions,
`reload-config!`/`poll-config!`, `create-agent`/`sync-provider!`.
States: active last-good configuration; pending load; validation failure;
reconciled; reload debounce armed; persistent error banner; new agent ready.

| From | Event / guard | To / action |
| --- | --- | --- |
| Active | file-watch touch | Arm/reset 150ms debounce deadline |
| Armed | deadline while main loop idle | Load scratch `*pending-config*` |
| Load | evaluation/validation fails or no configure! | Keep last-good config/runtime; error result/banner |
| Load | valid data | Replace config-owned commands/hooks/keys; reconcile MCP; reload tools; autostart |
| Reconciled | caller builds agent | Resolve explicit model over config default; select provider; merge unique tools |
| Active | model/effort command | Rebuild agent on model change; effort override affects next turn |
| Failed load | later valid reload | Retry; clear banner and surface warnings |

Invariants: removed config declarations do not accumulate; runtime/plugin
registration layers survive reconciliation; agent tool names are deduplicated
and collisions recorded. Effort precedence is session override > model entry >
config > provider default. Watcher reloads only between turns (pump does not
poll config). Loader's scratch cell protects declarative config, not arbitrary
side effects of executable init/plugin code; tool-load failures are warnings
and can leave that file's earlier registrations. Registry apply plus provider
construction is not a rollback transaction. `config_test`, `reconcile_test`,
`hotreload_headless_test`, and `tools_registry_test` cover supported cases.

## 8. Overlays and command palette

Owners: `src/overlay.sema`, palette helpers and key routing in `src/tui.sema`.
States: no overlay / stack top; MCP list/tools; resume list/detail/rename;
resume delete unarmed/armed(ID); palette closed/command/argument completion.

| From | Event / guard | To / action |
| --- | --- | --- |
| No overlay/top | open registered kind | Push fresh state; throwing open adds error and pushes nothing |
| Top | close | Pop to parent; last pop returns to composer |
| MCP list | Enter / tools action | Connect selected record / tools view |
| MCP tools | Esc | MCP list |
| Resume list | query/scope/navigation | Refilter; clamp selection; reset delete arm |
| Resume list | Enter / Ctrl-R / Ctrl-E | Detail / restore and close / rename |
| Resume list | Delete twice same selected ID | Arm confirmation / delete unless active |
| Resume detail | Esc / Enter or Ctrl-R | List / restore |
| Rename | Enter valid title / Esc | Save and refresh / list without save |
| Composer | leading slash | Palette command mode; whitespace/args choose completion mode |
| Palette | Tab / Enter while idle | Insert selection / dispatch chosen command |
| Busy | typed slash or modal shortcut | Keep composer; do not restore/reconnect mid-turn |

Invariants: only top overlay receives routed keys; list indices are clamped;
delete confirmation is bound to identity and cleared on navigation/filter;
Tab completion takes precedence over queuing; commands/overlays that replace
conversation or agent are gated during turns. Extension callbacks are trusted
code. Tests: `overlay_test`, `palette_test`, `keymap_test`.

## 9. Composer, gestures, input decoder, and rendering

Owners: prompt/history/selection/frame helpers in `src/tui.sema`,
`src/terminal_input.sema`, `src/transcript.sema`, `src/markdown.sema`.

| Machine / states | Event | Transition and invariant |
| --- | --- | --- |
| Composer editing / history browsing | insert/delete/move/history step | Codepoint cursor stays within input; history bounded to 100; blank input is not submitted |
| Clipboard notice absent/present | copy succeeds/fails, expiry | Show bounded status until deadline, then clear |
| Selection none/pressed/dragging | press/move/release | Capture origin and transcript version; drag after distance threshold; release copies and clears feedback |
| Keyboard press/repeat/release | decoded event type | Press/repeat may execute; release is ignored before command, overlay or copy routing |
| Click chain 1/2/3 | same cell within 300ms | Cycle single/word/line, then restart |
| Selection valid/stale | transcript mutation or resize | Invalidate gesture/highlight rather than copy different rendered text |
| Input reader stopped/running/EOF | start/read/stop | One task owns stdin; captured channel isolates old reader from replacement |
| Decoder empty/incomplete/ready | bytes arrive | Retain split UTF-8/CSI/SS3/Alt/paste; consume only complete events |
| Decoder lone ESC waiting | 50ms deadline | Emit Escape; otherwise combine subsequent sequence bytes |
| Bracketed paste incomplete/complete | ending delimiter | One paste event; content is inserted, not executed as commands |
| Frame clean/pending | input/stream/task change | Request paint; coalesce input/mouse motion; cap paints to 16ms except explicit renders |
| Transcript cache clean/dirty suffix/full invalidation | block mutation/width/preview change | Rerender dirty suffix or all, preserving unchanged prefix |
| Tool block running/done/failed/cancelled | tool callbacks or turn terminal | Settle indexed block, even if background notices were appended |
| Markdown prose/fenced code/table span | matching fence/table separator | Preserve fence type/minimum length; consume table rows; width-aware output |

Invariants: decoder events and byte counts stay aligned; buffer capped at 8MiB;
paste/control text is sanitized before insertion/rendering; selection uses
rendered positions, not provider offsets; dirty range starts at earliest edited
block; width/preview changes invalidate cache. Tests: `terminal_input_test`,
`input_test`, `selection_test`, `frame_test`, `transcript_test`, `markdown_test`.

## Verification and limits

Baseline: `./test.sema` passed 36 files / 918 checks before synchronization;
affected Sema 1.37 compatibility checks passed after synchronization. Each fix
below must update its issue status and record red→green evidence here. The
inventory covers repository-owned transitions, including retry and concurrency
boundaries; it is not a proof about arbitrary plugin code, OS failure, live
provider replay, or every possible malformed local JSON file. Potential concerns
without a reachable reproducer are not counted as confirmed bugs.
