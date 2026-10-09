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

## Upstream status (re-checked 2026-10-09)

Sema 1.37.0-rc.1 includes the fixes below. Sema Coder requires Sema >= 1.37;
CI pins the RC until 1.37.0 is published, then should test 1.37.0 and latest.
The historical notes below describe the original findings, not current gaps.

- **#82 / #104** global and captured-local reads observe `set!`; direct reads
  remain in use.
- **#83** `string/index-of` accepts a character start offset (since 1.36).
  Keep the split-based occurrence counter: repeated offset searches rescan
  UTF-8 prefixes. On a 20,000-match ASCII fixture, split took 3 ms and an
  offset-search loop took 663 ms on the same installed RC. The API gap is
  fixed, but replacing this counter would reduce performance.
- **#84** `take`/`drop` remain count-first. Swapped arguments now receive a
  specific hint. Keep count-first calls; both argument orders are not supported.
- **#85** `deftool :default` injects omitted values and makes those arguments
  optional (since 1.36). Paging, replacement, search, and shell tools declare
  defaults; a search glob is explicitly optional. Explicit nil and invalid
  user values still need validation.
- **#86** `agent/run` with options returns per-turn `:usage` in both blocking
  and streaming paths. Successful one-shot JSON and post-turn hooks use it.
  The TUI HUD keeps `llm/session-usage` because it displays session totals.
  Failed one-shot JSON retains session usage because no completed result exists.
- **#87** cancellation history uses `:on-partial` (since 1.35).
- **#88–#92** cooperative key waits, shell options and quoting, indexed
  iteration, mutable-array HOFs, and width-aware clipping remain in use.
  ANSI clipping stays custom because `string/truncate-width` is not ANSI-aware.
- **#94** prelude macro names work in binding positions (since 1.31).
- **Cancelled process cleanup**: `proc/close` removes cancelled/tombstoned
  handles in 1.37. Tests now require `no such handle`; `no longer usable` is
  evidence of a retained slot and cannot count as successful cleanup.

Remaining gaps:

- **#93** `markdown/to-ansi` remains unbound. Keep `src/markdown.sema`.
- **Terminal editor handoff**: `proc/run` can run an editor on the terminal.
  The TUI also has an offloaded stdin reader, so handoff needs a tested way to
  stop and reap that reader before the child reads the same terminal. Keep the
  current GUI-editor/opener path until that ownership transition is verified.

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
7. **A cancelled streaming turn loses the transcript delta.** ✅ FIXED in
   1.35.0 — `:on-partial` returns the completed, correlated message history
   before cancellation propagates. Current-round streamed text still comes
   from `:on-text`, by design; the application combines both sources.

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
