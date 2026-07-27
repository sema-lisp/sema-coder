# Language friction found while hardening sema-coder (2026-07-09)

Raw notes from a correctness/async/elegance pass over `examples/sema-coder/`,
for triage into issues. Each item is something the language/stdlib made harder
than it should be — including two gaps that let real bugs ship silently in the
flagship example.

## Status

All items below were verified against 1.30.0 and filed as GitHub issues on
`sema-lisp/sema` (2026-07-10): **#82–#94**. Two originally-noted items were
disproven on verification and NOT filed (item 3 tool accessors, item 6 agent
constructor — both already supported); item 4 was narrowed to PARTIAL. One
incidental gap surfaced during verification and was filed as **#94** (prelude
macro names can't be `(define (name …) …)` heads).

## Upstream status (checked 2026-07-10; re-checked 2026-07-21, 2026-07-26)

Seven items are fixed on `main`, each **verified by running the feature against
a `main`-built binary** on 2026-07-26 (not just read off the changelog). But
they are in the Unreleased changelog and **not yet in any release** — the latest
release is **still v1.30.0** (2026-07-09), which has none of them.

**The fold is release-gated, not fix-gated.** CI runs `sema-lisp/setup-sema@v1`
with no version input, which resolves to the latest *release* (1.30.0), and the
README pins `sema ≥ 1.30`. Deleting a workaround makes sema-coder fail for
everyone on the released binary and turns CI red the same day. So: keep the
workarounds until a sema release ships these, then fold them all at once and
bump the README/CI floor to that version in the same commit.

Fixed on `main`, verified live (probe result in parentheses):

- **#82 stale global reads from `load`ed units** — CLOSED. A `set!` from the
  caller is now seen by a recursive function defined in the `load`ed unit
  (`(:saw #t :n 5)`). `should-quit?` accessor workaround stays in
  `src/tui.sema:71`.
- **#104 async/spawn snapshots captured locals** — CLOSED 2026-07-12 (PR #106).
  A `set!` after `async/spawn` is observed by the task (reads `99`, not the
  spawn-time `1`) — the root-cause class behind the #82 workaround.
- **#88 `event/select`/`io/read-key-timeout` block the scheduler** — CLOSED
  2026-07-12 (PR #99). They now arm the same `AwaitIo` yield the file/http/shell
  offloads use. Verified: during one `(io/read-key-timeout 200)` a sibling task
  on 5 ms sleeps ticked **32 times** (it ticked 0 before). The busy-pump
  workaround (`read-key-timeout 0` + `async/sleep 16`, `src/tui.sema:405-421`)
  stays until a release ships.
- **#89 `shell/quote` + `shell` `:cwd`/`:env` options map** — CLOSED (PR #100).
  Both verified (`(shell "pwd" {:cwd "/tmp"})` → `/private/tmp`). The
  hand-rolled `sh-quote` (`src/util.sema:30`) and the `cd <dir> && …` pinning
  idiom (`src/tools.sema:94,100`; `src/commands.sema:120-123,222`) stay.
- **#90 `enumerate`/`map-indexed`** — CLOSED, both present. Local copies stay in
  `src/text.sema:152-161`.
- **#91 sequence HOFs over `mutable-array`** — CLOSED. `map`/`filter`/
  `for-each`/`length` all take a `mutable-array` directly. The
  `mutable-array/->vector` copies stay in `src/mcp.sema:14` /
  `src/transcript.sema:35`.
- **#92 `string/truncate-width`** — CLOSED, and it has a 3-arity ellipsis form,
  so `clip-width s w` ≡ `(string/truncate-width s w "…")` and `clip-plain s w`
  ≡ the 2-arity call. **Caveat: the builtin is not ANSI-aware** —
  `(string/truncate-width "\e[31mredtext\e[0m" 3)` → `"[3"` — so `clip-styled`
  in `src/text.sema:37` is NOT subsumed and stays regardless of the release.
- **#94 prelude-macro names as define heads** — issue still OPEN, but the fix is
  live on `main` (`(define (when-let x) x)` compiles and calls).

Still open upstream, all re-verified missing on 2026-07-26:

- **#83** `string/index-of` is strictly 2-arity ("expects 2 args, got 3"), so
  the `count-occurrences`-via-`string/split` workaround stays.
- **#84** `take`/`drop` still count-first only; list-first raises
  `expected int, got list` at runtime.
- **#85** `deftool :default` — the value IS stored and readable via
  `tool/parameters` (`{:x {:default 42 :optional #t …}}`) but is still never
  injected into an omitted arg, so the nil-guards stay.
- **#86** `agent/run` result map has no `:usage`.
- **#87** a cancelled streaming turn still loses its partial transcript.
- **#93** no `markdown/to-ansi` (unbound), so `src/markdown.sema` stays.

## Blocker (filed separately)

0. **Stale global reads in recursive functions from `load`ed units** — [#82].
   The TUI's quit flag (`set!` from a command handler, read by the key loop) is
   never observed, so the TUI can't exit; 9-line repro and characterization on
   the issue (sema-lisp/sema#82). sema-coder reads the flag through an accessor
   as a workaround (fixed upstream, unreleased — see "Upstream status" above).

## Stdlib gaps that caused shipped bugs

1. **`string/index-of` has no start-offset arg.** Strict 2-arity. sema-coder's
   `count-occurrences` called `(string/index-of s needle pos)` from day one, so
   the **edit-file tool always failed** with an arity error — swallowed by the
   tool-level `try` and returned to the model as an "Error editing…" string it
   silently routed around. Suggest: optional third `start` arg (nearly every
   string API has one), and/or a `string/count-occurrences` builtin. (Workaround
   used: `(- (length (string/split s needle)) 1)`.)
2. **`take`/`drop` argument order is a silent trap.** Count-first
   (`(take 2 xs)`), but two call sites in tools.sema used list-first — the
   read-file (>2000 lines) and bash (>500 lines) truncation paths raised type
   errors instead of truncating. Nothing flags this before runtime. Suggest:
   accept both orders (dispatch on types, Clojure-style), or a checker/LSP lint
   for `(take <list-literal|known-list> <int>)`.

## Agent/tooling surface

3. **~~Tool values are opaque.~~ RESOLVED — not a gap.** Accessors DO exist:
   `tool?`, `tool/name`, `tool/description`, `tool/parameters` (verified live).
   sema-coder's parallel `tool-names` list can be dropped in favor of
   `(map tool/name (all-tools))`. Do NOT file. (`tool/schema` as an alias of
   `tool/parameters` would be a minor nicety, not worth an issue.)
4. **`deftool` ignores `:default` (requiredness works).** PARTIAL, filed as
   [#85]. Verified: `:optional #t` already works and drives the provider's
   JSON-Schema `required`; what's missing is `:default` (stored but never
   injected) and any documentation of `:optional`. Omitted args still bind to
   `nil` (so nil-guards are still needed until `:default` lands).
5. **`agent/run`'s result map has no `:usage`.** A multi-round turn makes N
   provider calls; `llm/last-usage` reports only the final round — sema-coder's
   token HUD silently undercounted until switched to `llm/session-usage`.
   Suggest: fold the turn's cumulative usage into the result map
   (`{:response :messages :usage}`).
6. **~~No non-defining agent constructor.~~ RESOLVED — not a gap.** `(agent
   {...})` IS a first-class constructor (documented: "the plain constructor;
   the named form is `defagent`"). Verified live. sema-coder's `create-agent`
   can drop the `defagent`-in-a-function pattern for `(agent {...})`. Not filed.
7. **A cancelled streaming turn loses the transcript delta.** After
   `async/cancel` on an `agent/run` task there is no way to recover the
   partial `:messages` (streamed text + completed tool rounds), so an
   interrupted turn vanishes from history on the next turn.

## Async / TUI

8. **`io/read-key-timeout` and `event/select` block the cooperative
   scheduler.** ✅ FIXED upstream (unreleased) — [#88], PR #99: both now yield
   `AwaitIo` in async context. Unlike `file/*`, `http/*`, `shell`, and the LLM path, they have
   no `in_async_context()` offload — so a "wait for key OR agent progress" loop
   must busy-pump (`read-key-timeout 0` + `async/sleep 16`), costing latency
   and wakeups. Suggest: make `event/select` (at least the `:key` source)
   offload/yield in async context — it's billed as "the unified wait for a TUI
   loop" and would make the pump pattern unnecessary.

## Shell

9. **No shell-quoting helper.** ✅ FIXED upstream (unreleased) — [#89], PR #100
   adds `shell/quote`. `shell`'s single-string form goes through
   `sh -c`, and the `cd <dir> && …` workspace-pinning idiom breaks on paths
   with spaces/quotes unless you hand-roll POSIX quoting (sema-coder now
   carries its own `sh-quote`). Suggest: `shell/quote` builtin.
10. **`shell` has no options map (`:cwd`, `:env`).** ✅ FIXED upstream
    (unreleased) — [#89], PR #100 adds a trailing `{:cwd :env}` options map to
    `shell`. `proc/spawn` has them but
    is a different (streaming, handle-based) API; for a one-shot command in a
    directory you're forced into the `cd &&` idiom from (9).

## Smaller ergonomics

11. **No `map-indexed`/`enumerate` builtin.** ✅ FIXED upstream (unreleased) —
    [#90]. Hand-rolled twice in tui.sema (`enumerate`, `enumerate-map`).
12. **Sequence functions don't accept mutable arrays.** ✅ FIXED upstream
    (unreleased) — [#91]. `map`/`for-each`/
    `filter` need `(mutable-array/->vector a)` first — an O(n) copy per frame
    in a render loop, exactly where mutable arrays are pitched.
13. **No width-aware truncation.** ✅ FIXED upstream (unreleased) — [#92] adds
    `string/truncate-width`, with a 3-arity ellipsis form. `string/width`/
    `string/word-wrap`/`string/pad-*` are display-width-aware, but there's no
    `string/truncate-width`, so TUI cells that clamp long text (palette
    descriptions, tool args) still count codepoints and misalign on CJK/emoji.
    (sema-coder hand-rolls `clip-width` in tui.sema.) The builtin is not
    ANSI-aware, so it replaces `clip-width`/`clip-plain` but not `clip-styled`.
14. **No markdown → terminal renderer.** `markdown/to-html` and the structured
    `markdown/headings`/`markdown/frontmatter` exist, but there is no
    `markdown/to-ansi` / `term/markdown` that renders CommonMark to styled
    terminal text (headings, bold/italic, inline code, fenced code blocks,
    bullet/numbered lists). Every terminal LLM app needs this — agent replies
    ARE markdown — so each one re-implements a parser. Suggest a
    `markdown/to-ansi` builtin (width-aware, theme-able) reusing the
    `pulldown-cmark` parser already vendored for `markdown/to-html`.
