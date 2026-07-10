# Design: Sema Coder — MCP management, Lisp config, markdown output, standalone repo

Status: **v2 — revised after a 3-persona review (UX, Lisp purist, Sema expert).**
Phase 1 (standalone repo) is **done**. Author pass: 2026-07-10.

Adds interactive, modal-driven MCP management; turns config into an Emacs-style
Lisp file that is **data the app reconciles to** (not imperative mutation);
renders assistant markdown; and (done) promotes the app to its own repo.

## 0. Review-driven revisions (what changed from v1)

Three primed reviewers scrutinized v1 and researched prior art. Adopted:

- **Config is DATA + reconcile, not mutation + reset** (Lisp purist; Guix model).
  `init.sema` produces a config *value*; the app reconciles runtime to it. The
  v1 "reset accumulators before reload" step was a symptom of place-oriented
  mutation — it's gone. (Sema expert independently *verified* the re-`load`
  duplication bug that made the reset mandatory: `(:a :b :a :b)`.)
- **`mcp/connect` blocks the scheduler** — verified (issue **#96**): no
  `in_async_context` offload in `crates/sema-mcp`; measured 6166ms sequential vs
  `shell`'s 4133ms concurrent. So v1's "async connect keeps the spinner alive
  during OAuth" is **false**. Connect is now **synchronous** for stdio (~10ms) and
  **screen-aware** for OAuth (suspend the TUI so the browser + URL are visible).
- **Commands are one data form, argv by default** (Lisp purist) — killing the
  stringly-typed `(command! "n" "shell $ARGS")`, which was a shell-injection
  footgun contradicting the app's own "argv, never `sh -c`" tool discipline.
- **Modal flattened** to list-with-inline-verbs + a tools detail; **`:needs-auth`
  is a first-class state** with a boot-time notice (UX; opencode/Claude Code).
- **Streaming markdown caches finalized blocks**, debounces, and renders an open
  fence as an open code block (UX; McGugan/Textual). Per-frame parse is cheap
  (Sema expert: ~1.6ms/frame) so in-app-now stands.
- **Keep `agent/run` + `:messages` + `llm/session-usage`** — `conversation/*`
  lacks a tool loop and `conversation/usage`/`history` don't exist (verified).
- **`(agent {…})`, not `defagent`** for live rebuilds — verified cheap (1000
  rebuilds = 1ms) and the only path (no `agent/add-tool`).

State tension resolved: **the declarative config is an immutable value**
(Lisp-purist ideal), while **runtime state polled inside render/pump loops uses
in-place-mutated `mutable-array`s** (Sema-expert #82 mitigation — a direct global
read inside a recursive loop in a `load`ed unit never sees a cross-fn `set!`; an
in-place `mutable-array/set!` is seen). Immutability where read via accessors;
in-place mutation where read in a loop.

## 1. Goals & non-goals

**Goals**
- MCP servers **declared as Lisp data** and **managed interactively** (connect /
  disconnect / re-auth / view tools) from a modal + palette — never `/eval`.
- Connected MCP tools become live agent tools with no restart.
- Config is one annotated `init.sema` — a value the app reconciles to,
  hot-reloaded on save, that can also extend the app.
- The agent gets Sema's own MCP tools (eval + docs) by default via the config's
  topmost server line — a comment disables it.
- Render assistant **markdown** as styled terminal text.
- (Done) standalone repo, runnable as `./main.sema`.

**Non-goals (deferred)**
- No legacy/JSON migration — `init.sema` is hand-authored.
- `/tool:create` is a *future* slice; we only lay the autoload seam.
- Self-modification when compiled with `sema build` — §10.

## 2. Standalone repo relocation — DONE

`sema-coder/` is now a workspace member at `/Users/helge/code/sema/sema-coder/`,
its own git repo on `main`, pushed to **`sema-lisp/sema-coder`** (public), added
to `repos.tsv`, and un-ignored at the workspace root. `main.sema` has a
`#!/usr/bin/env sema` shebang (`chmod +x`), so `./main.sema` runs and
`./main.sema -- -p "…"` passes args (the reader skips the shebang; `parse-args`
skips the leading argv tokens). Relative `(load "…")` resolves relative to the
current file, so nothing broke. Remaining Phase-1 tail: an `@rooted` `Jakefile`
+ workspace `@import` (optional — members without recipes aren't imported).

## 3. Config as data — `init.sema`

`init.sema` lives at `<sys/config-dir>/sema/sema-code/init.sema`. It is
**evaluated** (handlers are real lambdas), but written as **value-returning
constructors** assembled into one config value — no per-item mutation, no
accumulators. The app captures that value and reconciles to it.

### 3.1 Constructors (in scope for init.sema; return values, never mutate)
- `(coder-config :model … :max-turns … :context-budget … :mcp-servers (list …) :commands (list …))`
  → the config map. Passed to `(configure! cfg)` (a single sink — replaces the
  whole value, so reload can't accumulate or leak).
- `(mcp-server "name" opts)` → a server record. `opts` is the `mcp/connect`
  map (`:command`/`:args`/`:env`/`:cwd` or `:url`/`:headers`/`:auth`) plus
  `:autostart` (bool). Transport inferred from `:command` vs `:url`.
- `(command "name" spec)` → a command record. `spec` is:
  - `{:desc … :run ["prog" "arg" :args]}` — **argv**; `:args` splices the typed
    args positionally (no shell, no injection — matches the tool discipline).
  - `{:desc … :do (fn (state args) …)}` — a Lisp handler (this subsumes
    `register-command!`).
  - `{:desc … :shell "tmpl with $ARGS"}` — explicit, eyes-open shell escape hatch.

Escape hatch for power users: raw `register-command!`, `deftool`, and theme fns
remain callable at top level, but the data forms are the documented path.

### 3.2 Load & reconcile (no reset step)
- Loader is a **pure function** `load-config : path → {:ok cfg} | {:error e}` — it
  reads/evaluates and returns a value, doing no I/O or `emit` itself, so the
  *caller* owns recovery policy (condition-system spirit without restarts).
- The app calls it, and on `{:ok cfg}` **reconciles** (model, budget, commands,
  MCP servers) against the previous value; on `{:error e}` keeps the last-good
  config and surfaces the error (see §4 feedback). A broken init never crashes.
- No `init.sema` → write the annotated default. No migration.
- Because `configure!` replaces the whole value, the config-owned command set and
  server set are derived, not accumulated — **no reset**. (The `tools/` autoload
  registry in §8 is separate and *does* reset before each pass.)

### 3.3 Annotated default `init.sema` (hand-authored)
```scheme
;; ~/.config/sema/sema-code/init.sema — Sema Coder config (Lisp data).
;; Edit in any editor; saved changes hot-reload live. This file is data the
;; app reconciles to — declarations are values, not commands that mutate state.

(configure!
  (coder-config
    :model      ""                 ; "" = auto-detect from API keys; or "claude-sonnet-5"
    :max-turns  50

    ;; ── MCP servers — manage in the /mcp modal (press ⌃O). Each is a value. ──
    :mcp-servers
    (list
      ;; Sema's own MCP server: gives the agent `eval` + docs into Sema itself.
      ;; On by default — comment out this line to disable it.
      (mcp-server "sema" {:command "sema" :args ["mcp" "--include" "eval,docs,docs_search"]
                          :autostart #t})
      ;; (mcp-server "fs"    {:command "npx" :args ["-y" "@modelcontextprotocol/server-filesystem" "."]})
      ;; (mcp-server "asana" {:url "https://mcp.asana.com/mcp"})   ; OAuth when you connect
      )   ; add servers you trust — they run real commands / reach real services

    ;; ── Slash commands — argv (no shell), or a Lisp handler. ──────────────────
    :commands
    (list
      (command "test" {:desc "run tests" :run ["make" "test"]})
      ;; (command "log"    {:desc "git log" :run ["git" "log" "--oneline" "-n" :args]})
      ;; (command "review" {:desc "review staged diff"
      ;;                    :do (fn (state args)
      ;;                          (ask-agent state (str "Review:\n"
      ;;                            (:stdout (shell "git" "diff" "--cached")))))})
      )))
```

## 4. Editing & hot-reload

No inherited-stdio subprocess exists (issue **#95**), so a terminal `$EDITOR`
can't take over the TUI. Edit model = watch-and-reload, hardened per the review:

- **Watch the config *directory*, filter to `init.sema` by basename**, not the
  file — atomic-rename saves (vim/VSCode write `.tmp` + rename) drop an
  inode-level file watch on Linux (verified). Drain `fs/watch-events` in the idle
  loop and turn pump.
- **Debounce** the event burst — one save fires 1 `:create` + 3 `:modify`
  (verified); coalesce to a single reload, and **retry the read** if the file is
  mid-write (truncated) before declaring it broken.
- On a settled change: `load-config` → reconcile (§3.2, §5.4) → **feedback**: a
  transient toast on success (`✔ config reloaded · model → sonnet`), and a
  **persistent header indicator on error** (`⚠ config error — using last good`)
  that stays until the next clean reload (a single scrolling line is too weak,
  and an external-editor user isn't watching the transcript).
- **`/config`** shows the path (and copies it); **`/config edit`** best-effort
  `open`s it and, on failure, prints the path + "edit in any pane — changes
  hot-reload live" (make the reload contract explicit; don't trust `open` on a
  `.sema` file silently). `/reload` stays as a manual trigger.

## 5. MCP runtime & live tool-merge

### 5.1 State (in-place mutable — #82 mitigation)
MCP records live in a **`mutable-array`**, each a map, mutated in place
(`mutable-array/set!`) so the pump loop sees fresh status without the #82 stale
read:
```
{:name "…" :config {…} :autostart bool
 :status :idle|:connecting|:needs-auth|:connected|:error|:disabled
 :handle "…"|#f :tools (…tool values…) :error "…"|#f}
```
`:needs-auth` is first-class (amber, actionable) — not folded into `:error`.
Lifecycle:
```
:idle ──connect (stdio, sync)──▶ :connected
:idle ──connect (remote/OAuth)──▶ [suspend TUI] ──ok──▶ :connected
                                                  └err─▶ :needs-auth | :error
:connected ──disconnect──▶ :idle        (mcp/close)
config removes it on reload ──▶ :closed + dropped
```

### 5.2 Connect (synchronous; screen-aware for OAuth) — corrected per #96
`mcp/connect` blocks the scheduler (#96), so **do not** wrap it in `async` with a
polled spinner (that freezes the UI for the whole connect, up to 300s for OAuth):
- **stdio** connects are ~10ms → call **synchronously** inline; set `:connecting`
  → `mcp/connect` → `:connected` + `(mcp/tools->sema handle)`. No perceptible
  freeze.
- **remote/OAuth** connects → **suspend the TUI** (leave `io/with-raw-mode` +
  alt-screen), print the auth URL, run the (blocking) `mcp/connect` on the normal
  screen so the browser flow and any printed URL are visible, then restore the
  alt-screen and reconcile. Auth is **user-initiated** (the `a` action on a
  `:needs-auth`/remote row), never an implicit browser-launch behind the
  alt-screen.
- **Autostart** servers connect **before `tui-run`** (on the normal screen during
  boot), where blocking is fine and any first-time OAuth is visible — not
  "asynchronously on boot."
- Note `mcp/call` also blocks (#96): a remote MCP tool call mid-turn starves the
  pump for its duration (fine for local stdio; laggy for remote — acceptable,
  improves when #96 lands).

### 5.3 Tool-merge (verified cheap; `(agent {…})`)
On any connect/disconnect, rebuild the agent with
`(agent {… :tools (append (base-tools) (connected-mcp-tools))})`. Verified: 1000
rebuilds = 1ms, and it's the only path (no `agent/add-tool`). Switch
`create-agent` off `defagent` (which rebinds a global each call) to anonymous
`(agent {…})`. History is preserved because `:messages` lives outside the agent.

### 5.4 Reconcile on reload
Diff the config's `:mcp-servers` list against the runtime `mutable-array`: add
new (in place), `mcp/close` + drop removed, connect newly-`:autostart`, leave
already-`:connected` intact. Idempotent by construction (re-applying the same
config = no change).

### 5.5 History / usage / cost
Keep `agent/run` + `:messages` (tool loop, streaming, correlation) and
`llm/session-usage` for the cumulative token/cost HUD. Call `llm/reset-usage` on
`/clear` so the HUD resets with the conversation.

## 6. MCP management modal (flattened per review)

A single-slot `*overlay*` (main-loop state, read via `(overlay-active?)` — **not**
a nested read-key sub-loop, which would hang under #82). While set, `handle-key`
routes to the overlay handler and `render!` draws an **opaque** centered box
(no background dim — dimming re-emits every row and defeats the frame-diff). Two
views (not three — drill-down for a single verb is the wrong shape; lazygit/
Cursor/Zed put status + actions inline):

- **List** — one row per server: `glyph name transport status #tools`, with a
  fixed glyph/color vocabulary: `●` connected (green), `◐` connecting (accent,
  animated by the pump), `▲` needs-auth (amber, "press a to sign in"), `○` error
  (red, reason inline), `◌` disabled (dim, "commented in init.sema"). Inline
  single-key verbs on the selected row: `c` connect · `d` disconnect · `a` auth ·
  `r` reconnect · `t` tools · `a`dd server · `e` edit config · `?` help · `Esc`
  close. Empty state: "No MCP servers yet — press `a` to add one" (append a
  commented `mcp-server` template to `init.sema` and open it).
- **Tools** — read-only scroll of the connected server's tool names
  (`(map tool/name (:tools rec))`); `Esc` back to List.

Boot-time notice: if any server is `:needs-auth` after autostart, post
"N server(s) need authentication — ⌃O to sign in" to the transcript, so discovery
doesn't require opening the modal (Claude Code pattern).

The slash palette stays as the inline launcher; the modal is the workspace
overlay. **Rebind the palette key** off `⌃K` (readline kill-to-EOL) to avoid the
terminal hijack; use `⌃O` (or `/`) for the MCP modal.

## 7. Markdown rendering (in-app, streaming-safe)

New `markdown.sema`: a tolerant CommonMark-subset → styled-lines renderer for
`:assistant` blocks. Per-frame parse is cheap (verified ~1.6ms/frame), but to
avoid flicker + O(n²) over a turn:

- **Cache rendered lines per block** keyed by `(text, width)`. Finalized blocks
  never change; **only the streaming tail block re-renders**.
- **Debounce** the streaming re-render (~50–100ms or flush on newline/paragraph),
  not every 16ms delta.
- **Open code fence** (unterminated ` ``` ` mid-stream) renders **as an open code
  block**, not as flashing raw text (no backtracking).

Elements: headings (accent/bold), `**bold**` (bright), `*italic*` (`term/italic`),
`` `inline code` `` (inverse/muted), fenced code (verbatim, no reflow, gutter),
bullet/ordered lists (glyph + hanging indent), `> quote` (`▏` gutter), links
(text bright, url faint). Width-aware (`string/word-wrap` for prose,
`fit-line`/`clip-width` for preformatted). Replaced by `markdown/to-ansi` (issue
**#93**) later *only if* it returns a width-aware line list.

## 8. Tools: derive names, data-constructor, autoload seam

- Drop the hand-synced `tool-names` list; derive from `(map tool/name (all-tools))`
  (and `tool-arg` too — extract the first scalar param generically so MCP tools
  show an arg). Render an MCP tool call as `server/tool` for provenance.
- **Add a `(tool {:name … :description … :parameters {…} :handler (fn …)})`
  data-constructor** mirroring `(agent {…})`, so a tool is constructible from data
  at runtime (only the handler is code) — `deftool` needs a literal symbol, which
  blocks the programmatic construction `/tool:create` needs.
- **Autoload seam** (`tools/` folder): `load` every `tools/*.sema` at startup and
  on hot-reload into a tool registry that `all-tools` reads; **reset the registry
  before each autoload pass** (re-`load` duplicates — verified). A future
  `/tool:create` uses the agent to author a tool and writes it as a **quasiquoted
  form pretty-printed with `format/form`** (code that writes canonical code, not
  string templating) to `tools/<name>.sema`; hot-reload picks it up.

## 9. Slash-command surface

`/mcp` (⌃O, modal), `/config` (show path) + `/config edit`, `/reload`, `/model`,
`/clear` (also `llm/reset-usage`), `/help`, `/tools` (folds into the modal's tools
inventory, filterable by server — not a print-only dead-end), `/cwd`, `/quit`.
Config-declared commands (§3.1) and Lisp handlers register into the same registry.

Header adds a **context-window fullness gauge** (`ctx 42% ██░░`, green→amber→red
off `:context-budget`) — the number users steer by — alongside model and `$cost`.

## 10. Deferred: self-modification when compiled

`sema build main.sema` bundles modules with no source beside them: `tools/`
hot-reload and opening project source won't apply; `init.sema` still works (it's
in the external config dir); an external `tools/` dir could still autoload from a
filesystem path. Out of scope now; captured so the built path is deliberate.

## 11. Repo file layout

```
sema-coder/
├── main.sema        #!/usr/bin/env sema — CLI, boot (autostart pre-TUI), dispatch
├── banner.sema      wordmark + welcome
├── theme.sema       palette + markdown/status styles
├── config.sema      constructors (coder-config/mcp-server/command) + pure load-config + reconcile + fs/watch
├── commands.sema    slash registry + built-ins (/mcp, /config, …)
├── mcp.sema         MCP runtime: mutable-array records, sync/screen-aware connect, reconcile, tool-merge
├── markdown.sema    markdown → styled lines (block cache, streaming-safe)
├── tools.sema       app tools + (tool {…}) constructor + registry + tools/ autoload
├── agent.sema       system prompt + (agent {…}) construction
├── display.sema     emit sink + tool-call rendering (server/tool provenance)
├── util.sema        path safety + string/shell helpers
├── tui.sema         frame render, overlay routing, hot-reload polling, header gauge, keys
├── tools/           autoloaded tools (future /tool:create)
├── docs/            this spec + notes
├── Jakefile         @rooted build/test/run
├── README.md · LICENSE · .gitignore · screenshot.png (updated last)
```

## 12. Testing

- **Headless:** `load-config` returns `{:ok}`/`{:error}` values; reconcile
  (add/remove/keep servers; command set replaced not accumulated); markdown golden
  per element + mid-stream partial (open `**`/fence) + block cache; modal frame
  fits width; status/glyph lifecycle incl. `:needs-auth`; tool-name + arg
  derivation; `tools/` autoload reset (no dup on re-load).
- **PTY end-to-end:** `/mcp` opens, inline verbs act, Tools view, `Esc` closes;
  hot-reload applies an edited `init.sema` (debounced, dir-watch) with toast /
  persistent-error; **connect a keyless stdio server** (`sema mcp`) synchronously
  → `:connected`, tools appear and drive a turn; markdown renders within the
  frame and doesn't flicker on stream; quit paths still exit.
- **Live (cheap model):** one turn that calls an MCP-provided tool.

## 13. Plan phases (for writing-plans)

1. **Relocate — DONE.** (repo, shebang, README, repos.tsv; `Jakefile` tail).
2. **Config as data + hot-reload** — constructors, `configure!`/pure `load-config`,
   annotated default, reconcile (model/budget/commands), dir-watch + debounce,
   `/config` show/edit + feedback, `(agent {…})` switch, derived tool names.
   Green: editing `init.sema` live-updates model + commands.
3. **MCP runtime + modal** — mutable-array records, sync stdio connect,
   screen-aware OAuth, autostart pre-TUI, reconcile, tool-merge; flattened
   overlay (List + Tools, inline verbs, `:needs-auth`, opaque box, boot notice).
   Green: PTY sync-connect a stdio server, tools live; OAuth suspends/restores.
4. **Markdown** — `markdown.sema` + block cache + streaming debounce +
   `block-lines` integration. Green: golden + PTY no-flicker render.
5. **Tools autoload + `(tool {…})` constructor** — registry + reset-on-reload;
   `/tool:create` deferred. Green: dropping `tools/x.sema` adds a tool on reload.
6. **Header gauge, provenance, screenshot + docs** — context gauge, `server/tool`
   lines, capture a substantial session (conversation + `/` palette), finalize.

## 14. Confirmed

- Target path `/Users/helge/code/sema/sema-coder/` — done.
- Self-MCP default line enabled (comment-to-disable) — done in the default above.
- Config-as-data posture, synchronous/screen-aware connect, flattened modal — all
  adopted from the review.

## 15. Filed language issues this touches

#82 (load-unit stale global — drives the in-place-mutable state rule), #88
(read-key/event block the scheduler — the pump busy-polls), #93 (no
`markdown/to-ansi` — in-app renderer), #95 (no inherited-stdio — hence
watch-and-reload), **#96 (mcp/connect/mcp/call block the scheduler — hence
synchronous + screen-aware connect)**. Also #85/#86/#91 inform smaller choices.
