# Extension API

The sanctioned surface for extending sema-coder — commands, tools, overlays,
hooks, keybindings, prompt editing, and output. If you're writing a plugin, this
is the whole vocabulary; you shouldn't need to grep `src/`. For a worked
end-to-end example see `docs/overlay-and-plugin-walkthrough.md`; for the overlay
internals, `docs/overlay-registry-design.md`.

Every symbol below is stable and callable from a plugin. Signatures use
`→` for the return; `[TUI]` marks a symbol that only works in the full-screen
TUI (there is no prompt/overlay in the piped REPL or one-shot `-p`).

---

## Where a plugin lives

A plugin is a `*.sema` file in either dir (global loads first, project shadows):

```
<config-dir>/plugins/*.sema        # global — every project
<cwd>/.sema-coder/plugins/*.sema    # project-local
```

It's `load`ed **once at boot**, after your `init.sema` config is applied. Unlike
`init.sema` and `tools/` (which hot-reload), plugin edits need a restart — a
plugin may `add-hook!` (which appends), so re-loading would duplicate. A plugin
runs registration side-effects directly; it does **not** call `configure!`.

Minimal plugin:

```sema
;; <config-dir>/plugins/hello.sema
(register-command! "hello" "say hello"
  (lambda (state args) (emit :info "hi from a plugin") state))
(bind-key! "ctrl-y" "hello")
```

---

## Commands

```sema
(register-command! name desc handler [opts])   ; name/desc strings; opts a flag map
;   handler : (state args) → next-state | 'quit     args = text after the command
;   opts    : {:keep-input #t}  — don't auto-clear the prompt on palette run [TUI]
(register-completions! name (fn state → ({:value v :label l [:active #t]} …)))
```

- Handlers write output through `emit` (below), never directly, so the same
  command works in the REPL and the TUI.
- `state` is a map with `:messages :model :effort :cwd :agent :config`; return it
  (optionally modified), or `'quit` to exit.
- `:keep-input` leaves `*input*` intact when the command runs from the palette,
  so the handler can read/rewrite the prompt itself. Key-bound invocations never
  clear regardless — **to act on the user's in-progress prompt, bind a key.**
- `register-completions!` feeds the palette once the input reads `/cmd <partial>`.

## Keybindings

```sema
(bind-key! key action)     ; key "ctrl-t"; action = a built-in keyword OR a command name
(unbind-key! action)       ; drop a runtime bind
```

Runtime binds are the strongest layer and survive config reloads. Binding a key
to a command name just runs that `/command`.

## Tools (agent-callable)

```sema
(deftool name "description" {:param {:type :string :description "…"}} (lambda (param) …))
(register-tool! name)      ; register the deftool'd value into the agent's tool set
```

For **persistent** tools prefer a file in the `tools/` dir (it hot-reloads and
survives config reloads); a plugin's `register-tool!` lives in the resettable
layer and is dropped on the next config reload. The handler returns the string
the agent sees. Paths should go through `resolve-path` / `run-in-workspace`.

## Overlays (modals) `[TUI]`

Register a modal as a descriptor, then open it by kind. See the overlay design
doc for the full model; the everyday surface:

```sema
(register-overlay! (overlay-spec {:kind :render :open :on-key}))
;   :open   (fn args → state-map)          initial state; must include :kind
;   :render (fn state layout → rows)        list of styled rows (use list-modal)
;   :on-key (fn state k → nil)              mutate via overlay-merge! / close-overlay!
(open-overlay! kind . args)   ; push a fresh modal   (aliases: open-mcp-modal! …)
(push-overlay! state)         ; push a child modal over the current one
(close-overlay!)              ; pop the top (a child returns to its parent)
(close-all-overlays!)
(overlay)                     ; the active (top) state map, or #f
(overlay-active?)             ; is a modal open?
(overlay-merge! m)            ; merge m into the top state (mutate in place)
(overlay-layout)              ; {:cols :rows :max-width} — pass to list-modal
```

The reusable list widget (Style B: rounded box + `▌` gutter):

```sema
(list-modal {:title s :items (…) :sel n :layout m :render-item fn :actions (…)})
;   :render-item (fn item selected? inner-width → row-string)   ; per-row content
;   :actions     (list {:key "c" :label "connect"} …)           ; footer hints
(modal-cell label meta inner)     ; helper: label left, meta right-aligned
```

Key predicates for `:on-key` (a key event is `{:kind :key|:char|:ctrl …}`):

```sema
(key-name= k :enter)   (key-char= k "c")   (key-ctrl= k "o")
```

A throwing `:open` becomes an error block, not a crash. To edit the prompt from
`:on-key`, use the prompt API below; to write to the transcript, use `add-block!`
(`emit` is not rerouted off the command dispatch).

## Hooks (turn lifecycle)

```sema
(add-hook! event handler)     ; handler (ctx) → ignored; a throw is caught + swallowed
```

| event | ctx |
| --- | --- |
| `:session-start` | `{:cwd}` |
| `:pre-turn` | `{:input :messages}` |
| `:pre-tool-call` | `{:tool :args}` |
| `:post-turn` | `{:input :result}` |
| `:on-error` | `{:input :error}` (the error then re-raises) |

`init.sema` can also declare hooks as data: `:hooks (list (hook :pre-turn fn))`.

## Prompt input `[TUI]`

The composing prompt and caret, read + edited only through these:

```sema
(prompt-text)      → the current prompt string
(prompt-cursor)    → caret index (codepoints)
(prompt-insert! s)   ; splice s at the caret, advance past it
(prompt-set! s)      ; replace the whole prompt, caret to end
(prompt-clear!)      ; empty it
```

## Output

```sema
(emit kind text)     ; :info | :ok | :error | :line (pre-styled) | :raw (stdout)
```

`emit` is front-end-agnostic (REPL + TUI) and is the right sink for **command
handlers**. It is only rerouted to the TUI *during command dispatch*; from an
overlay `:on-key` or a hook (which run off-dispatch) use:

```sema
(add-block! {:kind :info :text "…"})   ; [TUI] a transcript block (:info/:ok/:error/:warn/…)
```

## Workspace + config helpers

```sema
workspace-root                 ; var: the workspace root path (set per session)
(run-in-workspace cmd)         ; run a shell string with cwd pinned → {:stdout :stderr :exit-code}
(resolve-path workspace-root p) ; a workspace-confined absolute path (for tools)
(config-dir) (config-path) (tools-dir)
*tui-active*                   ; #t inside the full-screen TUI (overlays/prompt are TUI-only)
*config*                       ; [TUI] the live config map
```

---

## Gotchas

- **Load-once:** plugin edits need a restart (hooks would duplicate on re-load).
- **TUI-only surfaces:** overlays and the prompt API only exist in the TUI; guard
  with `*tui-active*` and provide an `emit` fallback for the REPL if it matters.
- **`emit` vs `add-block!`:** `emit` for command handlers; `add-block!` for
  overlay `:on-key` / hooks (where `emit` isn't rerouted and would corrupt the
  frame).
- **Act on the current prompt → bind a key**, don't rely on a slash command
  (typing `/cmd` replaces the composition; the key path preserves it).
- **Persistent tools → `tools/` dir**, not a plugin's `register-tool!`.
