# Workflow integration — design spec

Status: **proposed** (2026-07-22, revised after scrutiny of the Tier-2 roadmap
bullet). Companion to `overlay-registry-design.md` (whose reserved seams —
`:placement :full`, turn-safety, live rendering — this doc now claims). The
review that produced this plan covered `src/overlay.sema`, the roadmap bullet,
pi-sema's complete workflow implementation, the host runtime's `sema-workflow`
crate, and the in-flight `codex/unified-async-runtime` branch.

**The position in one line:** sema-coder does not build a workflow engine — it
becomes the second thin client of the engine the host runtime already ships,
with the journal as the only source of truth for everything it displays.

---

## 1. What the host runtime already ships (do not rebuild)

The roadmap bullet ("fold `events.jsonl` into state instead of parsing stdout —
resume, live HUD, crash-tolerance fall out of one mechanism") describes the
`sema-workflow` crate, which is already in the runtime sema-coder runs on:

| Surface | What it is |
| --- | --- |
| `defworkflow` / `phase` / `step` / `checkpoint` / `parallel` / `pipeline` | The authoring DSL — ordinary sequential Sema code; `phase` is a 1-arg marker, `step` is the only LLM leaf, `checkpoint` is the durable cross-phase state bag, fan-out is bounded (default cap 8). |
| `.sema/runs/<run-id>/` | The **frozen** run directory: `events.jsonl` (append-only, flushed per event — a crash leaves a valid prefix), `events.resume-<n>.jsonl` per resume, `memo/<content-key>.json` (resume source of truth), `args.json`, `metadata.json`, `result.json`. Runs root overridable via `SEMA_WORKFLOW_RUN_DIR`; a cross-run SQLite `index.db` sits at the root. |
| The event vocabulary | Frozen, append-only. Discriminator field **`event`** (not `type`), monotonic `seq`, RFC3339 `ts`. Variants: `run.started` (carries `workflow`, `run_id`, `args_json`, the declared `phases[]` plan), `phase.started/ended`, `agent.started/result/tool_call`, `checkpoint`, `budget`, `run.ended` (`success` / `failed` / `needs-auth`), `memory`, `auth.required/granted/failed`. |
| `sema workflow run <file> --args <json> --run-dir <root> [--resume <id>] [--no-auth-prompt]` | The child-process runner. Env seam `SEMA_WORKFLOW_RUN_ID` sets the run id. Exit codes: 0 success, 1 failed, 2 needs-auth. |
| Resume | `--resume <id>` short-circuits every leaf whose content-key (code-version + args + phase + name + prompt + schema + ordinal) exists in `memo/` — replay is free (zero tokens); editing source or args invalidates the affected keys. Each resume appends a new journal segment. |
| `sema workflow check <file> --strict --json` | Static validation without eval or LLM: parse errors, shape/arity traps, undeclared phases, missing `:budget`, missing final `{:status …}` (W-NO-STATUS), MCP spec errors — each diagnostic with severity/code/message/line/hint. Also available in-language as `workflow/check`. |
| `sema workflow view` / `sema workflow index` | A web viewer over run dirs, and the SQLite backfill. Forensics live here — the TUI does not need to replicate them. |
| Budget | `{:budget {:usd n}}` is a sticky latch checked at step entry; tripping forces `{:status :failed}`. `budget` events carry token/cost deltas. |

**pi-sema is the first client** of this contract (TypeScript: spawn + tail +
pure fold reducer + authoring gate + HUD + dashboard). Its test reports are the
best available field data and directly shaped §4–§5 here. sema-coder is better
placed than pi-sema was: same language, `workflow/check` as a builtin, `read`
over its own source for honest previews, and a markdown transcript renderer for
results.

## 2. Execution model — decided by the journal boundary

The roadmap bullet is silent on where workflow code executes. The answer is
version-dependent, so the design makes it a swappable strategy behind one rule:

> **All display consumes the journal (tail + fold). Nothing displays from the
> runner's return value.**

- **Today (stable main):** in-process runs are wrong — the live run scope is a
  process thread-local (one run per process; interleaved tasks cross-write
  journals), generated run ids are `wf_<unix_secs>_<pid>` (same-second
  collision), and journal I/O runs on the VM thread. **Strategy: spawn
  `sema workflow run` as a child** (pi-sema's model). Crash-tolerant by
  construction — a TUI crash doesn't kill runs, and a killed run folds to a
  coherent partial.
- **After `codex/unified-async-runtime` lands:** the branch's Phase A fixes
  exactly this cluster — A1 (landed 2026-07-21, `3396d4a0`) makes the live run
  scope a traced task-local, A2 adds collision-safe run identity + atomic
  segment claims, A3 moves journal writes to a bounded writer thread. An
  in-process `(async (workflow/run …))` strategy then becomes sound and cheaper
  for small runs. Because of the journal boundary, adopting it touches only the
  runner module.
- **Until A2 lands:** the TUI generates its own collision-safe run id
  (`wf<time-ms>-<pid>-<counter>`) and passes it via `SEMA_WORKFLOW_RUN_ID` —
  sidestepping the engine's weak default id.

A workflow run is **not a turn**: it must not set `*busy*`, and the user keeps
chatting while runs stream. Cancellation is owned here (the engine defers it
upstream): SIGTERM the child (then kill), fold the journal for the final state,
and always surface the `resume <run-id>` affordance — memoized leaves replay
free.

## 3. TUI/overlay findings that gate this work

From the 2026-07-22 architecture review of `src/overlay.sema` + `src/tui.sema`.
The registry/stack/`list-modal` bones are sound; these findings become blockers
only when the dashboard lands — which is why fixing them is phase W0.

| # | Severity | Where | Finding |
| --- | --- | --- | --- |
| 1 | STRUCTURAL (for this plan) | `tui.sema` main loop | The idle loop renders **only on keypress**; the overlay design doc's "live re-render is already free" holds only mid-turn (the pump). An idle live HUD/dashboard would freeze. |
| 2 | CONTRACT | `handle-key` overlay routing | An open overlay captures **all** input; ctrl-c is dead inside today's modals (a live bug). A dashboard must still interrupt/cancel. |
| 3 | CONTRACT | `:mcp`/`:resume` open sites | Overlays are gated `(unless *busy*)`. Correct for restore-flows; wrong for a dashboard whose purpose is watching live work. Needs per-descriptor `:busy-ok`. |
| 4 | CONTRACT | `list-modal` | Doesn't own selection movement (the design doc §4.6 says it does, and advertises a never-implemented `:on-action`); four hand-rolled up/down/clamp copies exist across the two built-ins. |
| 5 | FRICTION | `center-h` | Reads `*cols*` directly, breaking the "pure render over (state, layout)" contract headless tests rely on. |
| 6 | FRICTION | `mcp-connect-selected!` | Synchronous `:on-key` side effects block the frame; dashboard actions (cancel/resume) must spawn async work instead. |

## 4. The plan

### W0 — TUI groundwork (each piece independently useful now)

- **Idle repaint**: render on a tick (the frame diff makes a no-change frame a
  zero-write no-op) or a dirty flag set by watchers. Fixes finding 1; also the
  precondition for any live block/HUD.
- **Global-chord passthrough**: route a small allowlist (interrupt, quit,
  repaint) before overlay capture. Fixes the ctrl-c-in-modal bug today.
- **`:busy-ok` descriptor flag** (finding 3) and **`:placement :full`** (the
  seam reserved in the overlay design doc).
- **`list-modal` owns selection**: move up/down/clamp (and an `:on-action`
  dispatch) into the component; port the four hand-rolled copies onto it.
- **`center-h` takes layout** (finding 5).

### W1 — the journal client (`src/workflow.sema`; pure, no UI)

- A **fold reducer**: `(fold-run-events state ev) → state` over the frozen
  vocabulary, with pi-sema's proven semantics: unknown events skipped
  (forward-compat), lazy phase discovery when `phases[]` is absent, `budget`
  events accumulate (`cost` stays nil until a priced event arrives), a resume
  segment's `run.started` **reopens** the run, `agent.started` snapshots the
  currently open phase.
- An **incremental tailer**: reads `events.jsonl` then `events.resume-<n>`
  segments in numeric order, tracking per-file consumed length and keeping a
  partial-line buffer.
- **Tested against a golden journal** — a real run dir committed as a fixture —
  plus a synthetic journal containing an unknown event type (pins the
  forward-compat rule).

W1 has no dependency on W0 and is the load-bearing artifact: both surfaces and
both runner strategies consume it.

### W2 — run + observe in the transcript (the primary surface)

- `/workflow run <name|path> [args-json]` command and an agent-callable
  `workflow-run` tool, both through one runner module: spawn the child
  (`--run-dir`, TUI-generated `SEMA_WORKFLOW_RUN_ID`, `--no-auth-prompt`),
  register the run id, return immediately.
- A live **`:workflow` transcript block** holding the run id; `block-lines`
  folds the tailed state into a compact tree (summary line
  `▶ name · Phase (2/3) · 3/8 agents · $0.02/2.00`, last few agents with
  `→ tool`), re-rendered by W0's idle tick; `mark-tdirty!` on journal growth.
  The conversation stays fully usable — this is deliberately *not* a modal.
- **Cancellation**: ctrl-c with a live run targeted → SIGTERM → kill; journal
  state is truth; the block shows the resumable hint. `/workflow resume <id>`
  re-runs with `--resume`.
- **Result rendering** (pi-sema's #1 dashboard finding — "no obvious way to
  view results in TUI"): on `run.ended`, render the result through the markdown
  pipeline; extract long report strings (e.g. a `.result.report` field) instead
  of dumping truncated JSON. `needs-auth` (exit 2) renders the auth-required
  servers with the `/mcp` hint.

### W3 — the `/workflows` dashboard (the secondary surface)

- List ⇄ detail overlay on `list-modal`: newest-first folded summaries (cached
  by a `name:size:mtime` signature over each run's journal segments), detail =
  full phase/agent tree + checkpoints + result, live-tailing only an open
  detail of a live run.
- Uses `:full` placement + `:busy-ok` + list-modal selection from W0.
- `o` → open `sema workflow view` in the browser. The web viewer owns
  forensics; the TUI dashboard stays compact on purpose.

### W4 — authoring + approval (one component, shared with Forge)

- **Verify**: `sema workflow check --strict --json`, gating on the **parsed
  error count, never the exit code** (`--strict` flips the exit code on a
  warning alone — pi-sema learned this the hard way).
- **Preview**: an *honest* shape summary by reading the form (sema can `read`
  its own source; no regex): phases, step count, fan-out caps, `(load …)`s, and
  budget — a missing `:budget` renders as a loud "unbounded LLM spend" warning.
- **Approve**: a modal gated on **provenance** — agent-authored workflows
  require it, human-authored files don't. Two decisions: store? run now?
- **Store**: project `.sema-coder/workflows/` (default) or global
  `<config-dir>/workflows/`, mirroring the tools/plugins convention.
- **Bounded fix-retry** for agent authoring: feed diagnostics back
  (`status: check_failed (round N/3)`), then give up and report. Forge reuses
  this whole verify-preview-approve component for tools.

Sequencing: **W1 ∥ W0 → W2 → W3 → W4.** W2 is the point of first real utility.

## 5. Deliberately not built + upstream watch list

Not built here: the engine (scheduling, retries, HITL gates — upstream-deferred
as WF-1), a bespoke event vocabulary, per-token journal streaming, in-TUI
forensics, the web viewer's cross-run analytics.

Watch upstream (`codex/unified-async-runtime`):

- **A2 (safe run identity)** → drop the TUI-side run-id workaround.
- **A3 (bounded journal writer)** → removes VM-thread journal I/O concerns.
- **Branch merge** → an in-process runner strategy becomes available; adopting
  it touches only the runner module (§2's boundary).

## 6. Risks

- **Version skew**: the installed `sema` may predate the `workflow` subcommand.
  Probe at first feature use (not boot) and degrade with a clear message.
- **Frozen-contract discipline**: the fold must skip unknown events and never
  require fields marked optional — pinned by the golden + synthetic journal
  tests (W1).
- **Shared runs root**: `.sema/runs/` is project-local and shared with any
  other workflow use in the project (CLI runs, other clients). That's a feature
  (the dashboard sees everything) but the TUI must treat run dirs as
  read-only artifacts it didn't necessarily create.
- **Journal growth**: rendered values are capped by the engine (~4k per line),
  but a long run's journal still grows; the tailer's incremental reads and the
  dashboard's fold cache keep display cost proportional to *new* events, not
  run length.
