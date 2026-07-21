# Overlay registry — design spec

Status: **implemented** (per §7) in `src/overlay.sema`; tests in `tests/overlay_test.sema`. This doc is now the design
record — §1 ("what exists today") describes the *pre-port* single-slot system it replaced. Roadmap Tier-3 item 9 was
pulled forward because the config refactors (provider table, `apply-config!`, tool registry, hooks) are done. Author
pass: 2026-07-21.

The mandate (from the maintainer): make the **abstraction clean** and the **rendering flexible enough for what we'll
need it for in the future** before writing any code — and decide the look from **rendered prototypes**, not on paper.
Those prototypes live in `prototypes/overlay/gallery.sema`
(`sema prototypes/overlay/gallery.sema`).

**Locked decisions** (from the prototype review):

- **Chrome: Style B** — a rounded box (`╭╮╰╯`) whose selected row is marked by an accent **gutter bar** (`▌`);
  unselected labels `muted`, selected `bright`. Reads as a distinct modal surface and the selection cue survives without
  color.
- **Overlay stack**, not a single slot — a modal can push a child (Forge approve→rename, a confirm over the Workflows
  dashboard). `overlay` = top of stack.
- **Mutate-in-place** state — `:on-key` mutates the top overlay via
  `overlay-merge!` / `close-overlay!` (consistent with the no-`set!`-rebind rule).
- **Reusable `render-item`-driven list modal** — one modal component owns selection, scroll window, and the action
  footer; each feature supplies a
  `render-item` (and key actions). Proven in the gallery by driving the same chrome with MCP-server data *and* session
  data.
- **Distinct from the completion palette** — the palette stays for quick inline picks; this overlay is for involved
  flows that need their own view + actions.

§6 records these as resolved; §4/§7 are written to them.

---

## 1. What exists today (`src/overlay.sema`)

A single-slot modal system, two kinds hard-coded:

- **State.** `*overlay-box*` — a 1-slot `mutable-array` holding `#f` or a state map
  `{:kind :mcp|:resume :view … :sel N …}`. Mutated in place (never `set!`- rebound) so readers in other load units never
  see a stale binding. Accessors:
  `overlay`, `set-overlay!`, `overlay-merge!`, `close-overlay!`,
  `overlay-active?`.
- **Two overlays**, each with internal `:view` sub-states:
    - `:mcp` — views `:list` / `:tools`. `open-mcp-modal!`, `mcp-modal-rows`
      (render), `mcp-list-key` / `mcp-tools-key` (input).
    - `:resume` — views `:list` / `:detail`. `open-resume-modal!`,
      `resume-modal-rows` (render), `resume-list-key` / `resume-detail-key`.
- **Render model.** Each overlay produces a **list of pre-styled string rows**
  (ANSI-aware) via `*-modal-rows`, self-centered horizontally with `center-h`. Shared box primitives:
  `box-top/row/sep/bot`, `window-list` (scroll window),
  `overlay-center` (vertical placement onto the base frame).
- **Input model.** Per-view key handler `(fn k → side effects)` that mutates overlay state via `overlay-merge!` /
  `close-overlay!`. Key predicates
  `key-name=` / `key-char=` / `key-ctrl=`.
- **The hard-coded dispatch (the thing to remove), overlay.sema:283-290:**
  ```sema
  (defun overlay-rows ()
    (if (equal? (:kind (overlay)) :resume) (resume-modal-rows) (mcp-modal-rows)))
  (defun handle-overlay-key (k)
    (cond ((equal? (:kind (overlay)) :resume) (handle-resume-key k))
          ((equal? (:view (overlay)) :tools)  (mcp-tools-key k))
          (else                               (mcp-list-key k))))
  ```

### TUI integration surface (small — this is the whole contract)

| Concern                | Site               | Today                                                                                      |
|------------------------|--------------------|--------------------------------------------------------------------------------------------|
| Composite onto frame   | `tui.sema:321`     | `(if (overlay-active?) (overlay-center rows (overlay-rows)) rows)`                         |
| Hide cursor while open | `tui.sema:349`     | gated on `overlay-active?`                                                                 |
| Open                   | `tui.sema:593-594` | `⌃O → open-mcp-modal!`, `⌃R → open-resume-modal!` (both `(unless *busy* …)`)               |
| Route keys             | `tui.sema:646-647` | `(if (overlay-active?) (handle-overlay-key k) …)` — an open overlay captures **all** input |

Coupling to know about: overlay code reads TUI globals (`*cols*`, `*agent*`,
`*cwd*`, `*model*`, `*config*`) and calls `add-block!`, `create-agent`,
`restore-session!`. One shared global env makes this work but hides the dependency (roadmap refactor item 5).

## 2. Goals

1. **Registrable modals.** A plugin or first-party feature adds a modal without editing the dispatch —
   `register-overlay!` + open by kind. Removes overlay.sema:283-290.
2. **No behavior change on port.** `:mcp` and `:resume` move onto the registry byte-for-byte (golden: their render
   rows + key handling are identical).
3. **Rendering flexible for the known-hard future modals** (see §3): live- updating content, full-height layouts, and
   eventually in-overlay text entry.
4. **Testable.** Render is a pure `(state, layout) → rows`; a headless test can assert rows without a TTY (today
   `mcp-modal-rows` reaches for `*cols*`, so it can't).
5. **Cheap.** Render already runs every frame; keep it allocation-light.

Non-goals now: implementing Forge/Workflows modals; an overlay **stack** (§4); in-overlay text editing (§5) — but the
abstraction must not *preclude* them.

## 3. The future modals that drive "flexible enough"

These are the concrete future consumers; the abstraction is judged against them.

- **Forge approval** (Tier 2). Show a forged tool's full source as a **scrollable, syntax-styled diff**, with (later)
  **per-line annotations** and a **decision** (approve / edit / reject). Needs: tall scroll region; rich per-row
  styling; eventually a text-input affordance for annotations/renames.
- **Workflows dashboard** (Tier 2). A **live** tree of running agents with progress, folding `events.jsonl` into state.
  Needs: content that changes every frame (already free — render runs per frame); possibly **full-height**
  layout rather than a small centered box.
- **Plausible others:** a model/effort picker as a modal; a diff/confirm for risky tool calls; a help/keymap sheet.

Common requirements distilled: **(a)** self-managed sub-views & scroll (already supported), **(b)** live re-render
(already supported), **(c)** variable size — small centered *and* full-height, **(d)** rich per-row styling
(rows-of-styled- strings already gives this), **(e)** eventually text input.

## 4. Proposed design

### 4.1 Overlay descriptor

An overlay is registered as a data record (mirrors `(command …)` / `(tool …)`
/ `(hook …)`):

```sema
(overlay-spec
  {:kind    :mcp                       ; keyword id, also the state map's :kind
   :open    (fn args → state-map)      ; initial state; must include :kind
   :render  (fn state layout → rows)   ; list of styled string rows (ANSI-aware)
   :on-key  (fn state k → nil)         ; side-effects via overlay-merge!/close-overlay!
   :placement :center})               ; :center (small box) | :full (fill height) — see §4.4
```

- `:open` returns the initial state (like `open-mcp-modal!`'s
  `{:kind :mcp :view :list :sel 0 :tsel 0}`). Extra `args` support future parameterized opens (e.g.
  `(open-overlay! :forge tool-source)`).
- `:render` is **pure** over `(state, layout)` — no global reads — so it's testable and so `:placement`/sizing come from
  `layout`, not `*cols*`.
- `:on-key` keeps the **mutate-in-place** model (via `overlay-merge!` /
  `close-overlay!`) — consistent with today and with the deliberate
  "don't `set!`-rebind" note in overlay.sema. (Alternative in §6.)

### 4.2 Registry + stack

```sema
*overlays*  ; kind(keyword) → descriptor            (map)  — registered modals
*overlay-stack*                                      ; a stack of state maps; top is active
(register-overlay! spec)                             ; add/replace by :kind
(overlay-registered? kind)                           ; predicate
(overlay)          → top of *overlay-stack* | #f     ; the active overlay's state
(overlay-active?)  → non-empty stack
(open-overlay! kind . args)                          ; PUSH ((:open spec) args); (unless *busy*) stays at the call site
(push-overlay! state) / (close-overlay!)             ; push a child / pop the top (child modals)
(close-all-overlays!)                                ; clear the stack (esc-to-root, /clear)
(overlay-desc)     → descriptor of (:kind (overlay))
(overlay-rows)         → ((:render (overlay-desc)) (overlay) (overlay-layout))   ; replaces the hard-coded if
(handle-overlay-key k) → ((:on-key  (overlay-desc)) (overlay) k)                ; replaces the hard-coded cond
```

The **stack** replaces today's 1-slot `*overlay-box*`: `overlay` /
`set-overlay!` / `overlay-merge!` / `close-overlay!` keep their names but operate on the **top** frame (so ported code
is unchanged), and `push-overlay!` opens a child over the current one. `close-overlay!` pops one; the base case (empty
stack) means "no overlay". Render composites only the **top** frame for now (a future enhancement could dim-and-stack
visibly).

`overlay-rows` / `handle-overlay-key` keep their names and signatures, so **tui.sema barely changes**:
`open-mcp-modal!` / `open-resume-modal!` become thin `(open-overlay! :mcp)` / `(open-overlay! :resume)` (keymap bindings
at tui.sema:593-594 untouched), and the esc-at-root path pops to empty.

Built-ins register at load (like `register-builtin-tool!`); plugins call
`register-overlay!` after init. No reset needed — kinds are keyed, so re- registration replaces.

### 4.6 The reusable list modal (Style B)

Most overlays are "a scrollable, selectable list with actions." That's one shared component, parameterized so a feature
supplies only its data + behavior:

```sema
(list-modal
  {:title      "MCP servers"          ; shown in the rounded top border, with a count
   :items      (mcp-records)          ; the backing data (read fresh each render → live)
   :sel        (:sel (overlay))       ; selected index (lives in overlay state)
   :render-item (fn item selected? inner → styled-row)   ; per-row appearance (glyph/label/meta)
   :actions    (list {:key "c" :label "connect"} …)      ; drives the footer hints + on-key
   :on-action  (fn key-char item → nil)})                ; side-effects (mutate-in-place)
```

`list-modal` owns the Style-B chrome (rounded box, `▌` gutter on the selected row), the scroll **window**
(`window-list`, already exists), selection movement, and the footer built from `:actions`. `:render-item` is the
flexibility seam:
MCP renders glyph+name+status, resume renders title+meta, a future picker renders whatever — same modal. A **detail**
sub-view (server→tools, session→ messages) is just another overlay state `:view` the descriptor's `:render`
switches on, exactly as today.

### 4.3 Layout context (decouple from globals)

`overlay-layout` returns `{:cols *cols* :rows *rows* :max-width (min (max 40 (- *cols* 6)) 72)}`.
`:render` takes it as an arg instead of reading `*cols*`. This is the one change to the ported render fns (`bw` comes
from `layout`), and it's what makes them headless-testable (goal 4).

### 4.4 Placement

Compositing stays in the TUI (`overlay-center` = vertical centering; overlays self-center horizontally with `center-h`).
Add a `:placement` hint the compositor reads:

- `:center` (default) — today's behavior: center a short box vertically.
- `:full` — the overlay returns up-to-`:rows` rows; the compositor top-aligns / fills. This is what the Workflows
  dashboard wants.

`:full` is **specified now, implemented when first needed** — the descriptor field reserves the seam so no signature
churn later.

### 4.5 Rendering primitive: keep "rows of styled strings"

Do **not** invent a richer node/element tree. Rows-of-ANSI-strings is already maximally flexible (any per-row styling,
any content), matches the frame-diff renderer, and the box/scroll helpers already operate on it. Forge's annotated diff
builds its rows however it likes and returns strings. Revisit only if a concrete modal needs cell-level compositing the
row model can't express.

## 5. Text input in overlays (reserved seam, not built now)

Forge annotation / tool-renaming will need an editable field inside a modal. Today's line editor lives in tui globals
(`*input*`, `*cursor*`, word-motion helpers). Proposal, **deferred**: factor a reusable editor whose state lives in the
overlay's own state map (`:input`, `:cursor`) plus a shared
`overlay-edit-key` helper the overlay's `:on-key` can delegate to for char/backspace/cursor keys. Reserved here so
§4.1's `:on-key` contract is forward-compatible; not part of the `:mcp`/`:resume` port.

## 6. Decisions (resolved)

1. **Flexibility bar** — set by rendered prototypes, not scoped to specific future modals yet. The bar is "a
   cyclable/scrollable selectable list with action hooks, reusable by any feature that needs a modal" (§4.6). Forge /
   Workflows remain the eventual consumers but do **not** constrain v1.
2. **Stack** — ✅ **overlay stack** (nested modals). See §4.2.
3. **`:on-key` state model** — ✅ **mutate-in-place** via `overlay-merge!` /
   `close-overlay!`, `state` passed to handlers for symmetry with `:render`.
4. **Chrome** — ✅ **Style B** (rounded box + `▌` gutter), from the gallery.
5. **Decouple render from globals** — ✅ **yes**, pass a `layout` map (§4.3); unlocks headless render tests.
6. **`:placement :full`** — reserve the field; implement when Workflows lands.
7. **Text input in overlays (§5)** — defer to Forge; reserve the `:on-key` seam.
8. **Relationship to the palette** — the completion palette is unchanged and stays the ergonomic path for quick inline
   picks; overlays are for involved flows only.

## 7. Implementation plan

1. **`overlay.sema` foundation.** Replace `*overlay-box*` with `*overlay-stack*`; keep `overlay` / `set-overlay!` /
   `overlay-merge!` / `close-overlay!` operating on the top frame; add `push-overlay!` / `close-all-overlays!` /
   `overlay-active?`. Add `*overlays*` + `register-overlay!` + `overlay-desc` +
   `overlay-layout`. Replace `overlay-rows` / `handle-overlay-key` with registry lookups (delete the hard-coded dispatch
   at 283-290).
2. **`list-modal` component (Style B).** Rounded chrome, `▌` gutter selection,
   `window-list` scroll, `:render-item` seam, footer from `:actions`. This is the restyle — the ported modals adopt
   Style B (so rows *change* vs today; that's intended, not a regression).
3. **Port `:mcp` and `:resume`** onto `list-modal` as registered descriptors:
   `:open` = current `open-*-modal!` body; `:render` switches on `:view`
   (list/tools, list/detail) and calls `list-modal` for the list view; `:on-key`
   = current handlers (unchanged logic, top-frame state). Keep `open-mcp-modal!`
   / `open-resume-modal!` as `(open-overlay! …)` aliases.
4. **Tests.** Headless render tests now possible (render takes `layout`): assert
   `:mcp` / `:resume` list views render the expected Style-B rows for fixed state, selection movement updates `:sel`, a
   child `push-overlay!` makes
   `overlay` the child and `close-overlay!` returns to the parent. Extend
   `audit_regressions_test`'s existing overlay checks (which pin the
   `nil`-on-empty selection guards).
5. **Expose `register-overlay!`** as the documented plugin seam; update
   `docs/ROADMAP.md`.

Verification: the gallery already renders the target Style-B look; the port must match it for `:mcp` (list + tools) and
`:resume` (list + detail), plus empty states. `sema test.sema` stays green; `audit_regressions` overlay guards hold.

## 8. What this unblocks

Forge approval and the Workflows dashboard become **registered overlays**, not TUI surgery; plugins can add modals; and
the `:full` placement + text-input seams are reserved so neither needs a redesign.
