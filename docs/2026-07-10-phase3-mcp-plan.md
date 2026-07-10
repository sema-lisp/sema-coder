# Phase 3 — MCP runtime + management modal — Implementation Plan

> TDD, commit per task. Steps use `- [ ]`.

**Goal:** Connect the MCP servers declared in `init.sema`, merge their tools into
the live agent, and manage them from a modal (⌃O) + `/mcp`.

**Architecture:** `mcp.sema` holds runtime records in an in-place-mutated
`mutable-array` (read via accessors → #82-safe). Connect is **synchronous**
(stdio ~10ms; remote suspends the TUI for OAuth — issue #96). Connected tools
merge via `agent-tools` = `(append (all-tools) (all-mcp-tools))`; the agent is
rebuilt (`(agent {…})`) on connect/disconnect. A single-slot `*overlay*` renders
an opaque modal; input routes to it while open.

**Tech Stack:** Sema. Keyless integration test: connect to `sema mcp` itself.

## Global Constraints
- Runtime state in `mutable-array`, mutated in place; reads via `mcp-records`/
  `mcp-get` accessors (never a direct global read in a loop — #82).
- Connect is **synchronous**, never `(async (mcp/connect …))` (#96 — it blocks).
- `:needs-auth` is a first-class status; modal uses inline single-key verbs.
- Agent rebuilt via `(agent {…})` on any connect/disconnect.

---

### Task 1: Runtime records + reconcile-servers!
**Files:** Create `mcp.sema`; Test `tests/mcp_test.sema`.
**Produces:** `*mcp*` (mutable-array), `mcp-reset!`, `mcp-records`, `mcp-get name`,
`mcp-set! name f`, `reconcile-servers! servers` (add new idle / keep existing /
drop+close removed).

- [ ] Test: reconcile two servers → 2 idle records with right transports;
  reconcile one → the other is dropped, the kept one preserved.
- [ ] Run → FAIL (unbound). Implement `mcp.sema` records + reconcile. Run → PASS.
- [ ] Commit `feat(mcp): runtime records + reconcile`.

### Task 2: Connect / disconnect + tool-merge
**Files:** Modify `mcp.sema`, `agent.sema`; Test extends `mcp_test.sema`.
**Produces:** `mcp-connect! name` (sync; `:connecting`→`:connected`+tools, or
`:error`/`:needs-auth`), `mcp-disconnect! name` (`mcp/close`+clear),
`all-mcp-tools` (connected servers' tools), `agent-tools` = base+mcp.

- [ ] Test (keyless, connects to `sema mcp --include eval,docs`): `mcp-connect!`
  → `:connected`, record has 2 tools, `all-mcp-tools` = eval+docs; `mcp-disconnect!`
  → `:idle`, `all-mcp-tools` empty.
- [ ] Run → FAIL. Implement connect/disconnect/all-mcp-tools; `agent.sema` loads
  `mcp.sema`, `create-agent` uses `(agent-tools)`. Run → PASS.
- [ ] Commit `feat(mcp): sync connect/disconnect + live tool-merge`.

### Task 3: Autostart at boot + boot notice
**Files:** Modify `commands.sema` (boot-config! reconciles servers + autostarts),
`main.sema` (autostart pre-TUI). 
**Produces:** `mcp-autostart!` (connect all `:autostart` servers, return
needs-auth count); boot-config! calls `reconcile-servers!`.

- [ ] Test: reconcile with an autostart `sema` server, `mcp-autostart!` connects
  it (`:connected`), a non-autostart stays `:idle`.
- [ ] Implement; wire autostart before `tui-run`/REPL. Rebuild agent after.
- [ ] Commit `feat(mcp): autostart declared servers at boot`.

### Task 4: Overlay infrastructure (TUI)
**Files:** Modify `tui.sema`.
**Produces:** `*overlay*` (`#f` | state map), `overlay-active?`, key routing in
`handle-key` (overlay first), `overlay-box` opaque centered render composed into
`build-frame`.

- [ ] Test (headless): with `*overlay*` set, `build-frame` includes the box rows,
  fits width; `overlay-active?` gates routing.
- [ ] Implement. PTY: open a stub overlay, Esc closes.
- [ ] Commit `feat(tui): single-slot overlay infrastructure`.

### Task 5: MCP modal views + actions
**Files:** Modify `tui.sema` (or new `mcp_modal.sema`).
**Produces:** List view (glyph/name/transport/status/#tools rows; inline verbs
`c`/`d`/`a`/`r`/`t`), Tools view; actions call `mcp-connect!`/`mcp-disconnect!`
then rebuild the agent; `:needs-auth` amber; empty state.

- [ ] Test (headless): modal render for a record set fits width; glyph/status per
  state; selection + verb dispatch updates records.
- [ ] Implement. PTY: `/mcp`, connect the `sema` row → `:connected`, Tools view
  lists eval/docs, Esc unwinds.
- [ ] Commit `feat(mcp): management modal (list + tools, inline verbs)`.

### Task 6: /mcp command + ⌃O + boot needs-auth notice
**Files:** Modify `commands.sema`, `tui.sema`.
- [ ] `/mcp` opens the modal (TUI) / prints server table (REPL); ⌃O keybind;
  boot posts "N need auth" when any autostart server is `:needs-auth`.
- [ ] PTY end-to-end. Commit `feat(mcp): /mcp + ⌃O + boot auth notice`.

## Phase 3 done-when
Declared servers autostart at boot; `/mcp`/⌃O opens the modal; connecting a stdio
server makes its tools drive the next turn; disconnect removes them; a remote
OAuth connect suspends/restores the TUI. Verified via `sema mcp` keyless.

## Verify-at-impl
`mcp/connect` blocks (sync only, #96); OAuth path suspends raw-mode/alt-screen;
`mutable-array/set!` in-place for status; reads via accessors (#82).
