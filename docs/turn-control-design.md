# Turn control, queueing, and interruption recovery

Status: implemented baseline, 2026-08-31.

## Objective

Sema Coder must accept input while an agent is running without losing work or
making cancellation ambiguous. The controller therefore treats a future
follow-up, an active-turn steer, and a hard interruption as different actions.
It also exposes ordered events and a state snapshot so tests and plugins do not
need to infer state from terminal output.

## Product research

### Codex

Codex separates a durable thread queue from same-turn steering. Queue items
have stable client/server IDs and can be listed, edited, removed, reordered,
and started. Completed and failed turns can start the next queued item;
interrupted turns pause the queue. Steering targets an `expectedTurnId` and is
rejected if that turn is no longer active. A hard interruption retains durable
items and writes an internal marker which warns that command effects can be
partial.

The Codex TUI also keeps accepted-but-uncommitted steer input separate from the
durable queue. If the user interrupts before a steer is committed, the client
retains and resubmits it after the interrupted terminal event.

Primary sources:

- [Codex app-server lifecycle, queue, steer, and interrupt API](https://github.com/openai/codex/blob/13bc770eaf0ad8548776bde59c3d6e5316406279/codex-rs/app-server/README.md)
- [Turn protocol types](https://github.com/openai/codex/blob/13bc770eaf0ad8548776bde59c3d6e5316406279/codex-rs/app-server-protocol/src/protocol/v2/turn.rs)
- [Queue integration tests](https://github.com/openai/codex/blob/13bc770eaf0ad8548776bde59c3d6e5316406279/codex-rs/app-server/tests/suite/v2/thread_queue.rs)
- [Pending-input and steering tests](https://github.com/openai/codex/blob/13bc770eaf0ad8548776bde59c3d6e5316406279/codex-rs/core/tests/suite/pending_input.rs)
- [Durable interruption marker](https://github.com/openai/codex/blob/13bc770eaf0ad8548776bde59c3d6e5316406279/codex-rs/core/src/context/turn_aborted.rs)

### Amp

Amp defaults to FIFO queueing while the agent is busy. It exposes steering as
a preferred queued message delivered at a safe boundary, and a separate force
stop action. Its plugin API reports `done`, `error`, or `cancelled` at
`agent.end`, including messages produced during the run. Tool results can also
have a cancelled status. The CLI and SDK expose structured streams and
cancellation through `cancel()` or `AbortSignal`.

Primary sources:

- [Amp Neo: queueing and steering](https://ampcode.com/news/neo)
- [Amp prompting and queue behavior](https://ampcode.com/docs/prompting)
- [Amp plugin thread state, messages, steering, and cancellation](https://ampcode.com/docs/plugin-api)
- [Amp streaming JSON protocol](https://ampcode.com/docs/cli/streaming-json)
- [Amp TypeScript SDK](https://ampcode.com/docs/sdk/typescript)

## Sema Coder contract

### Queue

- Enter while a turn runs creates a `follow-up` queue entry.
- Entries have stable `queue-PID-CLOCK-N` IDs and FIFO order.
- Steers remain FIFO but are ordered before ordinary follow-ups.
- The queue is bounded at 100 entries.
- Queue entries are model-invisible until they start.
- Session metadata stores queue contents and the paused flag.
- `/queue` lists entries. `/queue edit ID TEXT`, `/queue drop ID`, `/queue
  clear`, and `/queue resume` manage them.
- Completed and failed turns start the next item automatically.
- Interrupted turns pause ordinary queued work until explicit resume.

### Interrupt and send

Ctrl-Enter is an explicit cancel-and-send operation:

1. Save the replacement as a steer with the current turn ID.
2. Request cancellation with that expected turn ID.
3. Ignore stale requests which target a different active turn.
4. Treat duplicate cancel requests as idempotent.
5. Wait for the current task to reach its interrupted terminal state.
6. Persist partial history and the interruption marker.
7. Start all steers accepted for that turn as one replacement user input.
8. Leave ordinary follow-ups paused.

This is not same-turn steering. The current Sema `agent/run` interface cannot
inject new user input into an active tool loop at a safe boundary. Adding that
requires a runtime handle such as `agent/steer(handle, expected-turn-id, input)`
or a boundary callback which can return pending user input. Until then,
cancel-and-send is precise and testable; calling it same-turn steering would be
incorrect.

### Interrupted history

Sema 1.35 adds `agent/run :on-partial`. Its callback returns the completed,
correlated message history before an error or cancellation propagates. The
currently streaming provider round still arrives only through `:on-text`.
Sema Coder combines both sources as follows:

1. Start from `:on-partial :messages`, or prior history plus the active user
   input if no partial map exists.
2. Keep completed assistant tool calls and tool results unchanged.
3. Add correlated error results for tool calls which cancellation left without
   a result. The result states that partial side effects are possible.
4. Append current-round streamed assistant text if it is not already present.
5. Append a typed `agent-control` user-context item which records
   `turn-interrupted` and tells the next model to inspect current state before
   continuing.

Session rendering shows the control item as a warning rather than a user
message. `agent/run` ignores its extra metadata and sends the role/content to
the provider, so the next model sees the interruption fact.

### State and events

`turn-controller-state` returns:

```text
{:status
 :phase
 :active-turn-id
 :active-input
 :active-tool
 :interrupt-mode
 :streamed-chars
 :partial-message-count
 :queue
 :queue-paused
 :message-count
 :session-id
 :events}
```

`/debug status` prints this snapshot as indented JSON. `/debug session` prints
the exact message history and queued input that the next turn will use.
`/debug transcript` prints the TUI blocks and render-cache state so a test can
distinguish conversation-state defects from rendering defects. The ordered
in-memory event log has a monotonic `:seq`, retains the newest 1,024 entries,
stores lengths rather than duplicating full prompt text, and records:

- `turn-started`
- `message-queued`, `message-updated`, `message-removed`, `message-dequeued`
- `cancel-requested`
- `turn-completed`, `turn-interrupted`, `turn-failed`
- `queue-cleared`, `queue-resumed`

Callbacks passed to the provider are guarded by turn ID. A late delta, tool
event, or partial callback cannot mutate a terminal or newer turn.

## Test layers

### Deterministic unit/controller tests

`tests/turn_control_test.sema` replaces the provider runner, input pump, and
renderer with scripted functions. It asserts queue ordering, stable IDs,
editing/removal, automatic drain, pause/resume, stale-ID rejection,
idempotent cancellation, terminal event order, partial history, replacement
start order, inspectable state, and rejection of late callbacks.

`tests/turn_test.sema` tests history repair directly, including incomplete tool
call correlation. `tests/session_test.sema` proves queue persistence.

### Process test harness

Every `*_test.sema` runs in a child interpreter with a 30-second default
timeout. Exit zero is necessary but not sufficient: the child must print the
`(done)` summary and report zero failures. Both stdout and stderr are retained
for failed-child diagnostics.

### Live provider smoke tests

Live calls are opt-in and should assert state invariants, not exact prose. A
useful run starts a harmless long tool, queues a follow-up, interrupts during
the tool, and checks the persisted session for:

- one interrupted terminal event;
- retained user input and completed protocol messages;
- a correlated cancelled tool result when required;
- the typed interruption marker;
- a paused ordinary queue;
- no callback mutations after terminal completion.

Long-running shell tools can outlive cooperative cancellation on some
platforms. Tests must use a temporary workspace and treat tool side effects as
unknown until inspected.

## Next runtime work

True same-turn steering needs runtime support. The preferred interface must:

- target an expected active turn ID;
- accept input only at documented model/tool boundaries;
- expose accepted, committed, rejected, and recovered states;
- interrupt intentional wait tools with a correlated result;
- make pending input recoverable across cancellation;
- reject late input for a newer turn;
- provide deterministic fake-provider gates for each boundary.
