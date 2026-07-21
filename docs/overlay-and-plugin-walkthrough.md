# Overlay system + a worked plugin (extension-dev walkthrough)

Status: **design walkthrough / gap analysis**. The overlay registry is spec'd (`docs/overlay-registry-design.md`) but
**not built**; plugin loading (roadmap Tier-1 item 7) is **not built**. This doc (a) explains how the overlay system
works — states, components, glossary, API — and (b) implements a real sample extension end-to-end to find gaps and
unergonomic API choices **before** we lock the implementation. Every symbol is tagged **[exists]** or **[proposed]** so
the gaps are honest.

The sample: a `todo-finder` plugin that scans `*.sema` in the workspace for any
`TODO:` comment, lists them in a modal, and on **Enter** injects
`#TODO-REFERENCE[FILE:LINE]("the todo text")` into the prompt at the caret.

---

## Part 1 — How the overlay system works

### 1.1 What it is (and isn't)

An **overlay** is a full modal surface drawn over the transcript that **captures all input** while open. It's for
*involved flows that need their own view and actions* — MCP server CRUD, session resume, and (later) Forge approval and
the Workflows dashboard.

It is **not** the completion **palette**. The palette is the lightweight inline list under the prompt for quick picks
(slash-command args, `/model`, `/effort`); it doesn't capture all input and has no sub-views. Rule of thumb: *a quick
pick of one value → palette; a stateful flow with actions and sub-views → overlay.*

### 1.2 Components & glossary

| Term                           | What it is                                                                                                                                                                                |
|--------------------------------|-------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------|
| **overlay stack** `[proposed]` | `*overlay-stack*` — a stack of overlay **state maps**; the **top** is active. Replaces today's 1-slot `*overlay-box*` `[exists]`. Enables a modal pushing a child (Forge approve→rename). |
| **overlay state**              | A plain map `{:kind … :view … :sel … …}` — the live, mutated-in-place state of one open modal. `:kind` selects the descriptor; the rest is the overlay's own business.                    |
| **descriptor** `[proposed]`    | The registered behavior for a `:kind`: `{:kind :open :render :on-key :placement}`. Analogous to a `(command …)` / `(tool …)` / `(hook …)` record.                                         |
| **kind**                       | Keyword id of an overlay type (`:mcp`, `:resume`, `:todo-finder`). Also the state map's `:kind`.                                                                                          |
| **view**                       | An overlay's internal sub-screen (`:list` vs `:tools`/`:detail`). The descriptor's `:render`/`:on-key` switch on it. Overlay-private — the registry doesn't know views exist.             |
| **list-modal** `[proposed]`    | The reusable *scrollable selectable list* component (Style B chrome). Owns the rounded box, the `▌` selection gutter, the scroll **window**, and the action **footer**.                   |
| **render-item** `[proposed]`   | `(fn item selected? inner → row-string)` a feature gives `list-modal` to draw one row's **content**. The modal adds the gutter + box. This is the reuse seam.                             |
| **actions** `[proposed]`       | `(list {:key "c" :label "connect"} …)` — drives the footer hints and (optionally) `on-key` dispatch.                                                                                      |
| **layout** `[proposed]`        | `{:cols :rows :max-width}` passed to `:render` so it never reads TUI globals (makes render headless-testable).                                                                            |
| **chrome**                     | The non-content frame: border (`╭╮╰╯` in Style B), title, separators, footer.                                                                                                             |
| **gutter**                     | The 2-col left margin; the selected row shows an accent `▌`, others blank. Style B's selection cue.                                                                                       |
| **compositor** `[exists]`      | `overlay-center` — places the modal's rows onto the base frame (`tui.sema:321`).                                                                                                          |

### 1.3 States & lifecycle

```
              open-overlay! :k              push-overlay! (child)
   (no overlay) ───────────► [top: :k, view :list] ───────────► [child on top]
        ▲                          │  │  ▲                            │
        │  close-overlay! (pop)    │  │  └──── close-overlay! ────────┘
        └──────────────────────────┘  │  (pops child → parent resumes)
                                       │ overlay-merge! {:view :detail}
                                       ▼
                              [top: :k, view :detail]
```

- **Open**: `open-overlay!` pushes `((:open desc) args)` — a fresh state map.
- **Navigate**: `:on-key` mutates the top state in place (`overlay-merge!`), including switching `:view`.
- **Push child**: `push-overlay!` stacks a new modal over the current one.
- **Close**: `close-overlay!` pops one frame; empty stack ⇒ no overlay.
- **Render**: every frame, `overlay-rows` calls the top descriptor's `:render`
  → the compositor draws it. Because it re-renders each frame, an overlay whose
  `:render` reads live data updates live for free.
- **Input**: while `overlay-active?`, every key goes to `handle-overlay-key` → the top descriptor's `:on-key`.

### 1.4 API reference (tagged exists / proposed)

**Registry & lifecycle**

```sema
(register-overlay! desc)            [proposed]  ; add/replace a descriptor by :kind
(overlay-spec {…})                  [proposed]  ; descriptor constructor
(open-overlay! kind . args)         [proposed]  ; push a fresh overlay of KIND
(push-overlay! state)               [proposed]  ; push a child modal
(close-overlay!)                    [exists*]   ; pop the top (today: clears the 1 slot)
(close-all-overlays!)               [proposed]  ; clear the stack
(overlay-active?)                   [exists]    ; is a modal open?
```

**State (operate on the top frame)**

```sema
(overlay)                           [exists]    ; the top overlay's state map (#f if none)
(overlay-merge! m)                  [exists]    ; merge M into the top state (mutate in place)
(set-overlay! m)                    [exists*]   ; replace the top state
```

**Rendering**

```sema
(overlay-layout)                    [proposed]  ; {:cols :rows :max-width}
(list-modal {:title :items :sel :layout :render-item :actions})   [proposed]
(modal-cell label meta inner)       [proposed]  ; row helper: label + right-aligned meta
;; box primitives box-top/round/row/sep/bot, window-list, center-h  [exists]
```

**Input** (`:on-key` receives `(state k)`)

```sema
(key-name= k :enter) (key-char= k "c") (key-ctrl= k "o")          [exists]
```

**Adjacent APIs a modal-driven feature needs**

```sema
(register-command! name desc handler)   [exists]  ; a /command to open the modal
(bind-key! "ctrl-t" "todos")             [exists]  ; bind a key → run the /command
(emit :info text)                        [exists]  ; front-end-agnostic output
(prompt-insert! s)                       [exists]  ; insert S at the prompt caret (also prompt-set!/prompt-clear!)
(prompt-text) (prompt-cursor)            [exists]  ; read the prompt string + caret index
*tui-active*                             [exists]  ; overlays are a TUI-only surface
```

`* close-overlay!` / `set-overlay!` exist for the 1-slot model; the port makes them operate on the stack top under the
same names.

---

## Part 2 — The `todo-finder` plugin, end to end

### 2.1 Behavior

1. `⌃T` (or `/todos`) opens a modal listing every `TODO:` comment in the workspace's `.sema` files, as
   `path:line — text`.
2. `↑↓` cycles; `Enter` injects `#TODO-REFERENCE[path:line]("text")` at the prompt caret and closes; `Esc` closes.

Target look (Style B):

```
╭ TODOs · 3 ─────────────────────────────────────────────╮
│ ▌ src/tui.sema:418      drain the buffer at typewriter… │
│   src/mcp.sema:61       treat #f as truthy — guard it   │
│   src/agent.sema:70     sync-provider! lowercases name  │
├─────────────────────────────────────────────────────────┤
│ ↑↓ move · ⏎ insert ref · esc close                      │
╰─────────────────────────────────────────────────────────╯
```

### 2.2 The plugin (one file, `todo-finder.sema`)

```sema
;; todo-finder.sema — sample sema-coder plugin.
;; Registers: an overlay (:todo-finder), a /todos command, and a ⌃T binding.

;; ── 1. Scan the workspace for the marker → (list {:file :line :text} …) ──
(defun todo-scan ()
  (let* ((res   (run-in-workspace                     ;; [exists] cwd-pinned shell
                  "rg --line-number --no-heading -g '*.sema' 'TODO:' ."))   ;; any TODO: comment
         (lines (filter #(not (= (string/trim %) "")) (string/split (:stdout res) "\n"))))
    (map (lambda (ln)                                  ;; rg emits  path:line:text
           (let* ((p1  (string/index-of ln ":"))
                  (rst (string/slice ln (+ p1 1) (string/length ln)))
                  (p2  (string/index-of rst ":"))
                  (raw (string/slice rst (+ p2 1) (string/length rst)))
                  (mi  (string/index-of raw "TODO:")))          ;; keep the text after the marker
             {:file (string/slice ln 0 p1)
              :line (string/slice rst 0 p2)
              :text (string/trim (if mi (string/slice raw (+ mi 5) (string/length raw)) raw))}))
         lines)))

;; ── 2. The reference token we inject ──
(defun todo-ref (it)
  (string/append "#TODO-REFERENCE[" (:file it) ":" (:line it) "](\"" (:text it) "\")"))

;; ── 3. The overlay descriptor ──
(register-overlay!
  (overlay-spec
    {:kind :todo-finder
     :open (lambda (args) {:kind :todo-finder :sel 0 :items (todo-scan)})
     :render
       (lambda (state layout)
         (list-modal
           {:title  "TODOs"
            :items  (:items state)
            :sel    (:sel state)
            :layout layout
            :render-item
              (lambda (it selected? inner)
                (modal-cell (if selected? (bright (string/append (:file it) ":" (:line it)))
                                          (accent (string/append (:file it) ":" (:line it))))
                            (muted (:text it))
                            inner))
            :actions (list {:key "⏎" :label "insert ref"}
                           {:key "esc" :label "close"})}))
     :on-key
       (lambda (state k)
         (let ((items (:items state)) (i (:sel state)))
           (cond
             ((key-name= k :up)    (overlay-merge! {:sel (max 0 (- i 1))}))
             ((key-name= k :down)  (overlay-merge! {:sel (min (max 0 (- (length items) 1)) (+ i 1))}))
             ((key-name= k :enter) (when (> (length items) 0)
                                     (prompt-insert! (todo-ref (nth items i)))   ;; splice at the caret
                                     (close-overlay!)))
             ((key-name= k :esc)   (close-overlay!))
             (else nil))))}))

;; ── 4. The command + key that open it ──
(register-command! "todos" "Insert a reference to a workspace TODO"
  (lambda (state args)
    (if *tui-active*
      (open-overlay! :todo-finder)
      (emit :info "todos: available in the TUI only"))
    state))

(bind-key! "ctrl-t" "todos")   ;; ⌃T while composing → open the picker
```

### 2.3 How it gets loaded — **now solved (was the first gap)**

Drop the file in a plugins dir and it loads at boot: `<config-dir>/plugins/*.sema`
(global) or `<cwd>/.sema-coder/plugins/*.sema` (project). `load-plugins!`
(`src/plugins.sema`) runs each file's `register-*` / `bind-key!` calls after the
config is applied; a broken plugin is reported, not fatal.

The alternatives it replaced: `tools/` autoload is the wrong kind (that dir is
for `deftool` + `register-tool!`), and `(load …)` from `init.sema` fights the
"init.sema is pure **data**" design. Note plugins load **once at boot** (a
re-load would duplicate `add-hook!`), so edits need a restart — and persistent
tools still belong in `tools/`.

### 2.4 Flow trace

`⌃T` → `keymap-action "ctrl-t"` → `:todos` → `run-key-command!` fires `/todos` → handler
`(open-overlay! :todo-finder)` → `:open` scans + pushes state → each frame `:render` → `list-modal` → compositor. `↓` →
`:on-key` → `overlay-merge!
{:sel …}`. `Enter` → `prompt-insert!` writes the token at the caret,
`close-overlay!` pops → the prompt now reads your text with the reference spliced in at the caret.

---

## Part 3 — Gaps & ergonomics findings

Ranked by how much they hurt an extension author.

1. ~~No plugin-loading convention.~~ **RESOLVED** — `src/plugins.sema`
   `load-plugins!` loads `plugins/*.sema` (global + project) at boot, reusing the
   `autoload-tools!` shape. The "modal + command + key" extension class is now
   supported; the `todo-finder` installs by dropping it in a plugins dir.

2. ~~The overlay API is unbuilt.~~ **RESOLVED** — `register-overlay!`,
   `overlay-spec`, `open-overlay!`, `list-modal`, `modal-cell`, and the stack ship
   in `src/overlay.sema`. The example held up as the acceptance test: it uses only
   `list-modal` + `render-item` + `on-key` + `overlay-merge!` / `close-overlay!`,
   which are exactly the API that got built.

3. ~~Prompt injection is an undocumented, misnamed internal.~~ **RESOLVED** — the
   `prompt-*` family in `tui.sema` is now the documented surface: `prompt-insert!`
   (splice at the caret), `prompt-set!` / `prompt-clear!`, and read-only
   `prompt-text` / `prompt-cursor`. The misnamed `insert-char!` was renamed to
   `prompt-insert!`. "Act on the user's prompt" (snippets, refs, templates) is now
   first-class.

4. ~~Slash-command dispatch clears the prompt.~~ **RESOLVED** (both fixes shipped):
   a command may declare `:keep-input #t` to skip the palette's prompt auto-clear
   (the handler manages `*input*`), and — the primary path — **key-bound commands
   never clear**, so to act on the in-progress composition you bind a key (the `⌃T`
   pattern), which `run-key-command!` already preserves. Documented in
   `docs/extension-api.md`.

5. **The REPL-state vs TUI-globals split leaks into plugin code — by design.**
   A handler receives `state` (the map) and, for a TUI-only action like opening a
   modal, does `(if *tui-active* …)` and reaches TUI globals. Refactor item 4
   (dual state) is now **addressed**: the duplicated `/resume` restore paths were
   unified (`session-restore-fields`) and the map↔globals bridge is documented as
   the single translation. The residual `*tui-active*` guard is **intrinsic** —
   some actions (modals, prompt edits) only exist in the TUI — and is the
   documented idiom, not a defect.

6. ~~No extension "context" object — plugins call bare globals.~~ **RESOLVED** —
   `docs/extension-api.md` is the curated reference listing every sanctioned
   symbol by capability, so authors don't grep `src/`.

7. ~~`:open` doing I/O has no error path.~~ **RESOLVED** — `open-overlay!` wraps
   `:open` in `try`; a throw (e.g. a failed scan) surfaces as an error block and
   nothing is pushed, instead of crashing the keypress.

### What already works well (keep)

- **`bind-key!`** `[exists]` is a clean runtime keybinding API (layered, survives reloads) — plugins bind keys with one
  call.
- **`register-command!`** `[exists]` — one call, drives both REPL + TUI via
  `emit`.
- **`render-item` reuse seam** — the plugin renders TODOs with `modal-cell` and never touches chrome/scroll; the modal
  is genuinely generic.
- **Live re-render** — scan-on-open + per-frame render means no manual refresh plumbing.

### Net

The overlay abstraction (Part 1) is sound and the sample exercised it without fighting it. Every concrete gap it
surfaced is now closed: the overlay registry (`src/overlay.sema`), plugin loading (`src/plugins.sema`), the prompt-input
API (`prompt-insert!` / `prompt-set!` / `prompt-clear!` / `prompt-text` / `prompt-cursor`), `:keep-input` on commands
(#4), `:open` error-wrapping (#7), and a curated `docs/extension-api.md` (#6). "A modal that edits the prompt" — a common
extension shape — is a supported, documented path end to end. The one non-blocking item left is #5, the REPL-state vs
TUI-globals split leaking into handler code — a symptom of roadmap refactor item 4 (dual state), a deeper cleanup rather
than an extension gap.
