# sema-coder — Architecture Review & Roadmap

Status: living document. **Tier 1 is complete** (all implemented + tested): provider-descriptor table, config key
validation, single `apply-config!`, tool registry + `tools/` autoload, hooks system, the **overlay registry** (Style-B
`list-modal` + stack, `:mcp`/`:resume` ported), and **plugin loading** (`plugins/*.sema`, global + project). The
extension surface an author needs now exists end to end — commands, tools, overlays, hooks, keybindings, a plugin home
(`plugins/*.sema`), and a documented prompt-input API (`prompt-insert!` / `prompt-set!` / `prompt-clear!` /
`prompt-text` / `prompt-cursor`); all three gaps from the `todo-finder` walkthrough
(`docs/overlay-and-plugin-walkthrough.md`) are closed. Forge (Tier 2) is parked. Name decision: keep **sema-coder** for
now.

This document records the architecture review of sema-coder, the feature mining of the `opencode-sema` and `pi-sema`
plugins, and the resulting roadmap of first-party features.

## Architecture summary

~3,300 lines of Sema across 17 `src/*.sema` files plus the `coder.sema`
entry. No build step; every file is `(load …)`ed into one shared global namespace. The agent loop is the host runtime's
`agent/run`; the agent is an anonymous `(agent {…})` value rebuilt cheaply on every model switch / config reload / MCP
change. The TUI is hand-rendered and frame-diffed, with async turn tasks and typewriter streaming. Config is a
live-evaluated `init.sema`
with value constructors (`coder-config`, `command`, `provider`, `model`,
`mcp-server`) and hot-reload via `fs/watch`. Sessions are JSONL with atomic tmp+rename writes.

## Refactoring opportunities (identified in review)

1. **No tool registry.** Adding a tool requires editing `src/tools.sema`, writing a `deftool`, hand-adding the symbol to
   the hard-coded
   `all-tools` list (`tools.sema:218`), and optionally extending `tool-arg`
   in `display.sema:67`. The Phase-5 design (`tools/` autoload dir +
   `(tool {…})` data constructor) was never implemented.
2. **Provider/model catalog duplicated 4×** — `provider-env-key`
   (`commands.sema:210`), `default-models` (`config.sema:34`), the
   `default-init-source` template string, and the boot error message in
   `coder.sema:32`. Collapse into one provider-descriptor table.
3. **Reload logic implemented 3×** — `boot-config!`, the `/reload` handler, and TUI `reload-config!` each re-do load →
   reconcile → autostart → rebuild-agent with slightly different error policy. Unify into a single
   `apply-config!`.
4. **Dual state representations** — REPL `state` map vs ~25 mutable TUI globals with hand-synced translation both ways
   (e.g. `/resume` has two separate restore paths). **→ addressed:** the two-front-end split (functional handler map +
   TUI working globals) is kept — it's a sound separation — but the duplicated logic is gone: `session-restore-fields`
   is the one builder both `/resume` paths + `restore-session!` use (test-verified they agree), `tui-state` /
   `apply-tui-state!` are documented as the sole bridge, and the six-field shape is called out as the one place to keep
   in sync. A full single-container consolidation was judged high-risk / low-marginal-value and deferred.
5. **Hidden cross-module coupling** — `keymap.sema` reads `*config*` from
   `tui.sema`; `overlay.sema` reads/mutates TUI globals; `session.sema`
   loads `display.sema` for a UI helper. One shared namespace means any new file can silently clobber any symbol.
6. **No hooks of any kind** — no pre/post-turn, pre-tool-call, on-error, or lifecycle events. Extending behavior around
   turns means editing
   `run-agent-turn!` in `tui.sema`.
7. **Overlays hard-coded** — two kinds (`:mcp`, `:resume`) with a hand-written dispatch (`overlay.sema:283-290`);
   nothing else can add a modal.
8. Minor drifts: `/clear` doesn't reset token usage; `coder-config`
   silently accepts typo'd keys; `sync-provider!` guesses provider ownership by lowercasing a display name (silent 404
   trap); the `--` CLI separator; one-shot `-p` has no streaming or slash commands; sessions are global with no cwd
   association or pruning.

## Feature roadmap

Mined from `opencode-sema`, `pi-sema` (including its ranked 16-idea backlog and test-report findings), mapped onto
sema-coder's extension seams.

### Tier 1 — foundational extensibility

1. **Tool registry + `tools/` autoload directory** — `(tool {…})` data constructor, registry reset on reload,
   `all-tools` reads the registry. (Deferred Phase 5 of the existing design doc.)
2. **Hooks system** — `pre-turn` / `post-turn` / `pre-tool-call` /
   `on-error` / `session-start` events subscribable from `init.sema` and plugins.
3. **Single `apply-config!`** + provider-descriptor table + config key validation.
4. **Plugin loading convention** — `~/.config/sema-coder/plugins/*.sema`
   and project-local `.sema-coder/plugins/`, loaded after init, documented as the supported extension path.

### Tier 2 — the crown jewels (from pi-sema)

5. **Forge: agent-authored persistent tools** — agent writes a `deftool` → verify in strict `--no-llm` sandbox (with the
   eager free-variable probe trick) → one human approval dialog showing full source → tiered storage (project
   `.sema-coder/tools/` vs global) → live registration, callable next turn. Bounded self-repair: N rounds with real
   diagnostics fed back, then stop and ask. Depends on Tier-1 items 1+2.
6. **Workflows as a first-party feature** — authoring flow with static check + shape preview before approval;
   journal-tailing live run display (fold `events.jsonl` into state instead of parsing stdout — resume, live HUD,
   crash-tolerance fall out of one mechanism); `/workflows` dashboard overlay.

### Tier 3 — UX polish

9. **Overlay registry** — make overlays registrable so plugins can add modals (needed for forge approval and workflows
   dashboard anyway).
10. **Context gauge in the header** (`ctx 42% ██░░`) — the dropped Phase-6 item; restore `:context-budget`.
11. **From opencode-sema** — user-config-wins semantics everywhere; layered precedence (env > project > global >
    defaults); fail-early advisory diagnostics; auto-format-on-write via `sema fmt`.
12. **Load-bearing tool-result text convention** — tool results carry agent-directed, machine-parseable instructions (
    "callable next turn",
    `status: probe_failed (round 2/3)`).
    
## Naming

Decision: keep **sema-coder** for now. Candidates recorded for later reconsideration: Semagent, Semafor, Coda, Semacs,
Forge.

## Current work package

Tier 1 (items 1–4) + Tier 3 item 9 (overlay registry), with provider deduplication (refactor item 2) as the top
refactoring priority.

- [x] Provider-descriptor table (dedup provider/model catalog) — `provider-descriptors`
  in `config.sema` is now the single source of truth; `default-models`,
  `provider-env-key`, `provider-env-keys` + the boot "no key" message, the
  `cli.sema` usage footer, and the generated `init.sema` `:models` block all derive from it (5 duplication sites
  collapsed).
- [x] Config key validation in `coder-config` — `unknown-config-keys` recovers a typo'd top-level key (e.g. `:max-turn`)
  that `merge` would silently keep; surfaced as a warning through `apply-config!`.
- [x] Single `apply-config!` (unify boot / `/reload` / TUI reload) — one load+reconcile path in `commands.sema`; never
  prints (returns
  `{:ok cfg :warnings …}` | `{:error e :cfg fallback}`), so it's safe from the TUI file-watch. `boot-config!`, the
  `/reload` handler, and TUI
  `reload-config!` are now thin wrappers that own only how to surface the outcome + whether to rebuild the agent.
- [x] Tool registry + `tools/` autoload — `all-tools` reads a registry (`*builtin-tools*` + a resettable
  `*autoloaded-tools*` layer);
  `register-tool!` upserts by name; `autoload-tools!` (re-)loads
  `(tools-dir)`/*.sema with reconcile semantics (reload replaces, deleted file drops its tool) and returns load errors
  instead of printing. Wired into `apply-config!` so tools reload on the config lifecycle. The
  `(tool {…})` data-constructor stays deferred with Forge (no host primitive).
- [x] Hooks system — `src/hooks.sema`: `:session-start` / `:pre-turn` /
  `:pre-tool-call` / `:post-turn` / `:on-error`, fired from `run-turn` +
  `run-turn-streaming` (and `new-session!` / boot for session-start). Declared as `:hooks (list (hook :event fn))`
  config data (reconciled like commands, keeps `load-config` pure); `add-hook!` is the primitive for future plugins. A
  throwing handler is caught + swallowed (TUI-safe).
- [x] Overlay registry — `src/overlay.sema`: an `*overlays*` registry
  (`register-overlay!` / `overlay-spec`, dispatch by the top state's `:kind`) over
  an overlay **stack** (`push-overlay!` / `close-overlay!`, a list in a stable
  1-slot array), replacing the hard-coded dispatch. A reusable Style-B `list-modal`
  (rounded box + `▌` gutter, `render-item` seam, `:actions` footer, `overlay-layout`
  context) drives both built-ins; `:mcp` (list/tools) and `:resume` (list/detail)
  are now registered descriptors. `open-mcp-modal!` / `open-resume-modal!` kept as
  aliases; headless render + stack tests in `tests/overlay_test.sema` (387 checks
  green). `register-overlay!` is the plugin seam.
- [x] Plugin loading convention — `src/plugins.sema`: `load-plugins!` loads
  `*.sema` from `<config-dir>/plugins/` (global) then `<cwd>/.sema-coder/plugins/`
  (project shadows global), once at boot in `coder.sema` after the config is
  applied. Plugins run registration side-effects (`register-command!` /
  `register-overlay!` / `add-hook!` / `bind-key!`) that pure-data `init.sema`
  can't; a broken plugin is reported, not fatal (returns error strings like
  `autoload-tools!`). Load-once (a re-load would duplicate `add-hook!`), so plugin
  edits need a restart; persistent tools go in `tools/`. Tested
  (`tests/plugins_test.sema`) + verified end-to-end (a plugin's `/command` shows
  in `/help`).
