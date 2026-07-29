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

## Upstream status (re-checked 2026-07-29)

The global and latest released binary is **v1.33.0**. The first release with
the audited fixes was **v1.31.0** (2026-07-26). Sema Coder now requires
`sema >= 1.31`; CI tests both 1.31.0 (the floor) and the latest release.

Folded onto released APIs and verified live on 1.33.0:

- **#82 / #104 global and captured-local visibility** — direct reads in loaded
  recursive loops now observe `set!`. The TUI quit loop reads `*should-quit*`
  directly.
- **#88 cooperative terminal waits** — `io/read-key-timeout` parks without
  blocking sibling tasks. The turn input pump uses a 16 ms wait instead of a
  zero-timeout poll plus `async/sleep`.
- **#89 shell quoting and working directories** — shell commands use
  `{:cwd workspace-root}`, argv commands execute directly, and the remaining
  POSIX interpolation uses `shell/quote`. The local `sh-quote` and `cd &&`
  workarounds are gone.
- **#90 indexed iteration** — call sites use `map-indexed` and `enumerate`.
- **#91 mutable-array sequence HOFs** — MCP and transcript render paths pass
  mutable arrays directly instead of copying them to vectors every frame.
- **#92 width-aware truncation** — `clip-width` and `clip-plain` delegate to
  `string/truncate-width`, including its grapheme-safe ellipsis form.
  `clip-styled` stays custom because the builtin is not ANSI-aware.
- **#94 prelude-macro names in binding positions** — the issue is still open,
  but the fix shipped in 1.31.0 and `(define (when-let x) x)` works on 1.33.0.

Still open upstream, re-verified on 1.33.0:

- **#83** `string/index-of` is strictly 2-arity ("expects 2 args, got 3"), so
  the `count-occurrences`-via-`string/split` workaround stays.
- **#84** `take`/`drop` remain count-first; list-first raises
  `expected int, got list`.
- **#85** `deftool :default` is stored in `tool/parameters` but is not injected
  into an omitted argument (`tool/invoke` binds `nil`), so nil-guards stay.
- **#86** `agent/run` results still have no per-turn cumulative `:usage`.
- **#87** is partially addressed by 1.32.0: `agent/run {:memory handle}` saves
  text turns produced before cancellation. A cancelled run still does not
  return its partial full-protocol `:messages`, which Sema Coder needs for its
  exact resumable session format.
- **#93** `markdown/to-ansi` remains unbound, so `src/markdown.sema` stays.

## Blocker (filed separately)

0. **Stale global reads in recursive functions from `load`ed units** — [#82].
   The TUI's quit flag (`set!` from a command handler, read by the key loop) is
   never observed, so the TUI can't exit; 9-line repro and characterization on
   the issue (sema-lisp/sema#82). Fixed in 1.31.0; the accessor workaround has
   been removed.

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
   scheduler.** ✅ FIXED in 1.31.0 — [#88], PR #99: both now yield
   `AwaitIo` in async context. Unlike `file/*`, `http/*`, `shell`, and the LLM path, they have
   no `in_async_context()` offload — before the fix, a "wait for key OR agent
   progress" loop had to busy-pump (`read-key-timeout 0` + `async/sleep 16`),
   costing latency and wakeups.

## Shell

9. **No shell-quoting helper.** ✅ FIXED in 1.31.0 — [#89], PR #100
    adds `shell/quote`. `shell`'s single-string form goes through
    `sh -c`, and the `cd <dir> && …` workspace-pinning idiom breaks on paths
    with spaces/quotes unless you hand-roll POSIX quoting (sema-coder now
    uses the released builtin). Suggest: `shell/quote` builtin.
10. **`shell` has no options map (`:cwd`, `:env`).** ✅ FIXED in 1.31.0 —
    [#89], PR #100 adds a trailing `{:cwd :env}` options map to
    `shell`. `proc/spawn` already had them but is a different (streaming,
    handle-based) API; before the fix, a one-shot command needed the `cd &&`
    idiom from (9).

## Smaller ergonomics

11. **No `map-indexed`/`enumerate` builtin.** ✅ FIXED in 1.31.0 —
    [#90]. The hand-written copies have been removed.
12. **Sequence functions don't accept mutable arrays.** ✅ FIXED in 1.31.0 —
    [#91]. `map`/`for-each`/`filter` previously needed
    `(mutable-array/->vector a)`, an O(n) copy per frame. Those copies are gone.
13. **No width-aware truncation.** ✅ FIXED in 1.31.0 — [#92] adds
    `string/truncate-width`, with a 3-arity ellipsis form. `string/width`/
    `string/word-wrap`/`string/pad-*` were already display-width-aware; the
    missing truncation counterpart made TUI cells misalign on CJK/emoji.
    `clip-width` and `clip-plain` now delegate to the builtin. The builtin is
    not ANSI-aware, so it does not replace `clip-styled`.
14. **No markdown → terminal renderer.** `markdown/to-html` and the structured
    `markdown/headings`/`markdown/frontmatter` exist, but there is no
    `markdown/to-ansi` / `term/markdown` that renders CommonMark to styled
    terminal text (headings, bold/italic, inline code, fenced code blocks,
    bullet/numbered lists). Every terminal LLM app needs this — agent replies
    ARE markdown — so each one re-implements a parser. Suggest a
    `markdown/to-ansi` builtin (width-aware, theme-able) reusing the
    `pulldown-cmark` parser already vendored for `markdown/to-html`.
