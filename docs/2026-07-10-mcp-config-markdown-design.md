# Design: Sema Coder — MCP management, Lisp config, markdown output, standalone repo

Status: **approved design, pre-implementation**. Author pass: 2026-07-10.
Supersedes ad-hoc slash commands with interactive, modal-driven MCP management;
turns config into an Emacs-style Lisp init file; renders assistant markdown; and
promotes the app from a language example to its own flagship repo.

## 1. Goals & non-goals

**Goals**
- Make MCP servers first-class: **declared as Lisp** in the config, **managed
  interactively** (connect / disconnect / re-auth / view tools) from a modal and
  the command palette — never via a `/eval <code>` prompt.
- Connected MCP tools become live agent tools with no restart.
- Config is a single annotated **Lisp init file** (`init.sema`), hot-reloaded on
  save (`fs/watch`), that can also extend the app (custom commands, tools).
- The agent gets Sema's own MCP tools (eval + docs) **by default via the config's
  topmost line**, not hardwired into the harness — one comment disables it.
- Render assistant **markdown** (headings, emphasis, code, lists, quotes) as
  styled terminal text.
- Promote the app to its own repo (`sema-coder`), runnable as `./main.sema`
  (shebang), depending only on Sema.

**Non-goals (deferred, noted where relevant)**
- No backwards/legacy compatibility, no JSON→Lisp migration code — the default
  `init.sema` is authored by hand.
- `/tool:create` (agent authors a new `deftool` and hot-reloads it) is a *future*
  slice; we only architect so it drops in.
- Self-modification semantics when compiled with `sema build` (no source beside
  the binary) — deferred; captured in §10.

## 2. Standalone repo relocation

**Target: a new workspace member `/Users/helge/code/sema/sema-coder/`** — its own
git repo on `main`, added to `repos.tsv` as `sema-coder\tsema-coder`, matching the
existing manifest+clone model (NOT a submodule). *(Confirm this path at review —
the request said `~/sema/sema-coder`, which does not exist; the workspace root is
`/Users/helge/code/sema/` and every flagship lives there as a sibling member.)*

- Move `examples/sema-coder/` → the new repo root. Its files already depend only
  on Sema builtins and relative `(load "…")`, which resolve **relative to the
  current file** (module system), so relocation does not touch any path.
- Remove `examples/sema-coder/` from the `sema` monorepo (a deletion committed in
  the `sema` repo) and drop the example from any examples index / smoke lists.
- **Shebang**: `main.sema` starts with `#!/usr/bin/env sema` and is `chmod +x`, so
  `./main.sema` runs interactively and `./main.sema -- -p "…"` passes args
  (verified: Sema's reader skips the shebang; `parse-args` already ignores the
  leading argv tokens). The reader-level shebang support is a documented Sema
  feature; nothing app-side is needed beyond the line + exec bit.
- Add the member's own `Jakefile` (`@rooted`) with `build`/`test`/`run` recipes
  and wire `@import … as coder` into the workspace `Jakefile` (per workspace
  CLAUDE.md) — only if it carries a `@rooted` Jakefile.

## 3. Config as Lisp — `init.sema`

The user config becomes one Lisp file at `<sys/config-dir>/sema/sema-code/init.sema`
(Emacs `init.el` analog). It is **evaluated** at startup after all app modules
load, so a small config DSL AND the full app API are in scope.

### 3.1 Config DSL (defined in the app, in scope for init.sema)
- `(set-model! name)` · `(set-max-turns! n)` · `(set-context-budget! n)`
- `(command! "name" "shell template with $ARGS")` — declarative slash command
- `(mcp-server! "name" cfg)` — declare an MCP server; `cfg` is the `mcp/connect`
  options map plus app keys: `:autostart` (bool), `:transport` label (optional,
  else inferred from `:command`/`:url`).
- Power users may also call `register-command!` (Lisp-handler commands),
  `deftool`, and theme fns directly — it is a real extension file.

Each DSL form mutates a config accumulator; after load the app holds
`{:model :max-turns :context-budget :commands :mcp-servers}`.

### 3.2 Loading, safety, reset
- Before (re)loading, **reset the config-owned accumulators** (declared commands,
  declared MCP servers) so a removed declaration disappears on reload.
- `load` `init.sema` inside `try`; on error, `emit :error` the message and keep
  the last-good config (or defaults on first load). A broken init never crashes
  the app.
- No `init.sema` present → write the **annotated default** (below). No migration
  from any prior `config.json`.

### 3.3 Annotated default `init.sema` (authored by hand)
Every common declaration shown live-or-commented so humans and agents can copy
correct syntax:
```scheme
;; ~/.config/sema/sema-code/init.sema — Sema Coder config.
;; Plain Sema (Lisp). Edit in any editor; saved changes hot-reload live.

;; ── Sema's own MCP server ────────────────────────────────────────────────
;; Gives the agent `eval` + docs lookup into Sema itself. On by default.
;; Comment out this line if you don't want the agent to have that.
(mcp-server! "sema"
  {:command "sema" :args ["mcp" "--include" "eval,docs,docs_search"]
   :autostart true})

;; ── Model & budget ───────────────────────────────────────────────────────
(set-model! "")            ; "" = auto-detect from API keys; or "claude-sonnet-5"
(set-max-turns! 50)

;; ── Slash commands (/name runs a shell template; $ARGS = text after name) ──
(command! "test" "make test")
;; (command! "log"  "git log --oneline -n $ARGS")

;; ── More MCP servers (manage in the /mcp modal) ──────────────────────────
;; stdio:  (mcp-server! "fs"    {:command "npx" :args ["-y" "@modelcontextprotocol/server-filesystem" "."]})
;; remote: (mcp-server! "asana" {:url "https://mcp.asana.com/mcp"})   ; OAuth on connect
;; add :autostart true to connect a server on launch
```

## 4. Editing & hot-reload

Sema has **no inherited-stdio subprocess** (issue #95; `shell` captures,
`proc/spawn` streams, `pty/spawn` makes a *new* pty), so an in-terminal `$EDITOR`
cannot take over the TUI. The edit model is therefore watch-and-reload:

- The app `fs/watch`es `init.sema`; the idle loop and the turn pump drain
  `fs/watch-events` and, on `:modify`, **hot-reload**: re-eval init → reconcile
  MCP servers → rebuild the agent → `emit`/transcript "config reloaded" (or the
  error). Edit in any editor/pane, save, see it apply.
- `/config` shows the path and **best-effort opens it** via the OS default
  handler (`open` / `xdg-open` / `start …`), which detaches (works for GUI
  editors); terminal-editor users edit in another pane and rely on hot-reload.
- `/reload` remains as a manual trigger (same reconcile path).

## 5. MCP runtime & live tool-merge

### 5.1 State
A runtime list of server records, keyed by name:
```
{:name "…" :config {…} :autostart bool
 :status :idle|:connecting|:connected|:error|:disabled
 :handle "…"|#f :tools (…deftool values…) :error "…"|#f}
```
Declared servers come from §3 (`mcp-server!`). Status lifecycle:
```
declared(:idle) ──connect──▶ :connecting ──ok──▶ :connected
                                    └────────err─▶ :error
:connected ──disconnect──▶ :idle        (mcp/close)
:idle ──(config removes it on reload)──▶ closed + dropped
```

### 5.2 Async connect (reuses the turn/pump pattern)
- Connect = `(async (mcp/connect (:config rec)))`; set row `:connecting`; the
  idle/pump loop polls `async/pending?`; on resolve store `:handle` +
  `(mcp/tools->sema handle)` and set `:connected`; on reject set `:error` +
  message. OAuth is automatic in `mcp/connect` (browser on first 401).
- **Risk to verify in impl:** whether `mcp/connect` yields to the scheduler in
  async context. If it blocks, the UI freezes briefly during first-time OAuth —
  acceptable fallback (row shows `:connecting`, unanimated).

### 5.3 Tool-merge
- The agent is rebuilt with `(agent {… :tools (append (base-tools)
  (all-connected-mcp-tools))})` on any connect/disconnect. `(agent {…})` is the
  first-class non-defining constructor (verified), replacing the current
  `defagent`-in-a-function in `create-agent`.
- `base-tools` = the app's own `deftool`s; `all-connected-mcp-tools` = the
  concatenated `:tools` of `:connected` records.

### 5.4 Reconcile on reload
On hot-reload/`/reload`, diff declared servers vs runtime records: add new,
drop+`mcp/close` removed, connect newly-`:autostart`, leave already-connected
ones intact. Autostart servers connect asynchronously on boot (non-blocking).

## 6. MCP management modal

A general single-slot overlay in the TUI: `*overlay*` is `#f` or a state map
`{:kind :mcp :view … :sel … :action-sel … :scroll …}`. While set, keys route to
the overlay handler first (captured), and `render!` draws a centered dimmed box
over the frame reusing the existing frame-diff renderer. Opened by `/mcp` (and a
key binding). Three views, cloned from f-terminal's model with real wiring:

- **List** — rows `name · transport · status · #tools`, selected row highlighted;
  status colored (`:connected` ok, `:connecting` accent, `:error` bad,
  `:idle`/`:disabled` muted). Footer: `↑↓ select · Enter manage · e open config ·
  r reload · Esc close`.
- **Actions** (per server) — status line + state-gated actions: **Connect** (or
  **Reconnect**), **Disconnect**, **View tools**; Esc back to List.
- **Tools** — read-only scroll list of the connected server's tool names
  (`(map tool/name (:tools rec))`); Esc back to Actions.

Async actions update the row live via the same poll as turns. The slash palette
stays as-is (inline bottom overlay); the modal is the new centered-overlay
primitive.

## 7. Markdown rendering (in-app)

New `markdown.sema`: a tolerant CommonMark-subset → styled-lines renderer used by
`block-lines` for `:assistant` blocks (raw markdown stays in the block; rendered
per-frame so streaming just appends and half-finished markup degrades). Elements:

| Element | Rendering |
| --- | --- |
| `# / ## / ###` headings | accent, bold; level sets prefix/intensity |
| `**bold** __bold__` | bright |
| `*italic* _italic_` | `term/italic` |
| `` `inline code` `` | muted on subtle bg / inverse |
| ` ```fenced``` ` | preserved verbatim (no reflow), muted, left gutter |
| `- * +` bullets | `•` glyph + wrap with hanging indent |
| `1.` ordered | number + hanging indent |
| `> quote` | `▏` gutter, muted |
| links `[t](u)` | text bright, url faint |

Width-aware (reuses `string/word-wrap` for prose, `fit-line`/`clip-width` for
preformatted). The `markdown/to-ansi` builtin (issue #93) would replace this
later; the app renderer ships now.

## 8. Tools: derive names, architect for `/tool:create`

- Drop the hardcoded `tool-names`; derive from `(map tool/name (all-tools))`
  (accessors verified: `tool?`/`tool/name`/`tool/description`/`tool/parameters`).
- **Architect for a future `/tool:create`** (not built now): support an
  autoloaded `tools/` folder — the app `load`s every `tools/*.sema` at startup and
  on hot-reload (same `fs/watch`), each file registering `deftool`s into a tool
  registry that `all-tools` reads. A later slice adds `/tool:create "use X to do
  Y, call it blah-tool"`, which uses the agent to author a `deftool`, writes
  `tools/blah-tool.sema`, and lets hot-reload pick it up. This slice only lays the
  registry + autoload seam; a `tools.sema` simplification pass happens then.

## 9. Slash-command surface (the "worthless commands" point)

The value is that actions are now interactive: `/mcp` (modal), `/config`
(open + path), `/reload`, `/model`, `/clear`, `/help`, `/tools` (derived),
`/cwd`, `/quit`. No command is a dead-end that only prints; MCP is fully driveable.

## 10. Deferred: self-modification when compiled

`sema build main.sema` bundles modules into a standalone binary with no source
beside it. Implications to design later: hot-reload of `tools/` and opening the
project source won't apply (there is no source dir); `init.sema` still works (it
lives in the external config dir, read at runtime), and an external `tools/` dir
could still autoload if we read from a filesystem path rather than the bundle.
Out of scope now; captured so the built-binary path is designed deliberately.

## 11. New repo file layout

```
sema-coder/
├── main.sema        #!/usr/bin/env sema — entry: CLI, boot, REPL/TUI dispatch
├── banner.sema      wordmark + welcome
├── theme.sema       palette + markdown/status styles
├── config.sema      config DSL + accumulators + load/reset/default + fs/watch
├── commands.sema    slash registry + built-ins (/mcp, /config, …)
├── mcp.sema         MCP runtime: records, async connect/disconnect, reconcile, tool-merge
├── markdown.sema    markdown → styled lines
├── tools.sema       app deftools + registry + tools/ autoload seam
├── agent.sema       system prompt + (agent {…}) construction
├── display.sema     emit sink + tool-call rendering
├── util.sema        path safety + string/shell helpers
├── tui.sema         frame render, overlay routing, hot-reload polling, key handling
├── tools/           (autoloaded user/agent tools — future /tool:create)
├── docs/            this spec + notes
├── Jakefile         @rooted build/test/run
├── README.md        org-template header + usage
└── screenshot.png   updated last (conversation + / palette)
```

## 12. Testing

- **Headless (eval/`sema/check-file`):** config DSL populates accumulators;
  reload reconciliation (add/remove/keep server records, close on remove);
  markdown golden cases per element + mid-stream partial (unterminated `**` /
  fence); modal frame fits width at narrow/normal sizes; status-lifecycle
  transitions; tool-name derivation; `tools/` autoload picks up a dropped file.
- **PTY end-to-end:** `/mcp` opens, navigates List→Actions→Tools, Esc unwinds and
  closes; hot-reload applies an edited `init.sema`; **connect a real keyless stdio
  MCP server** (e.g. `sema mcp` itself, or filesystem server) → row goes
  connecting→connected and its tools appear in `/tools` and drive a turn; markdown
  output renders (headings/code/lists) and stays within the frame; quit paths
  still exit.
- **Live (cheap model):** one turn that calls an MCP-provided tool end-to-end.

## 13. Plan phases (for writing-plans)

1. **Relocate + shebang + README + Jakefile** — move to `sema-coder/` member,
   `repos.tsv`, shebang, org-template README, workspace `@import`. Green: app runs
   as `./main.sema` and via Jake from both dirs.
2. **Config as Lisp + hot-reload** — DSL, annotated default `init.sema`,
   load/reset/fallback, `fs/watch` reload, `/config` open, `(agent {…})` switch,
   derived tool names. Green: editing init.sema live-updates model/commands.
3. **MCP runtime + modal** — records, async connect/disconnect, reconcile,
   tool-merge, overlay infra + three views. Green: PTY connect of a stdio server,
   tools become live.
4. **Markdown rendering** — `markdown.sema` + `block-lines` integration. Green:
   golden + PTY render.
5. **Tools autoload seam** — `tools/` registry + autoload (no `/tool:create`
   yet). Green: dropping a `tools/x.sema` adds a tool on reload.
6. **Screenshot + docs polish** — capture a substantial session (conversation +
   `/` palette), finalize README.

## 14. To confirm at review

- **Target path** `/Users/helge/code/sema/sema-coder/` (workspace member) vs a
  literal `~/sema/sema-coder/`.
- Self-MCP default line **enabled** (commented-to-disable) — confirmed.
- Phase ordering (relocate first vs config/MCP first).
