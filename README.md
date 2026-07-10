<div align="center">

<img src="https://sema-lang.com/logo.svg" alt="Sema" height="64">

# Sema Coder

**A terminal coding agent written almost entirely in [Sema](https://sema-lang.com)** — a Lisp with first-class LLM primitives.

[![License](https://img.shields.io/github/license/sema-lisp/sema-coder?color=c8a855)](LICENSE)
[![Website](https://img.shields.io/badge/website-sema--lang.com-c8a855)](https://sema-lang.com)
[![Built with Sema](https://img.shields.io/badge/built%20with-Sema-c8a855)](https://sema-lang.com)

</div>

Sema Coder is the reference application for **Sema as an application runtime**: the
agent loop, tools, slash commands, the full-screen TUI, theming, and config all
live in Sema. Only a thin layer of host primitives (terminal screen control, path
safety) is Rust. It depends on nothing but the `sema` binary.

![Sema Coder — a sample session](screenshot.png)

## Run

```bash
# Interactive (full-screen TUI on a TTY)
./main.sema                     # or: sema main.sema

# One-shot (prose to stdout, pipeable)
./main.sema -- -p "explain this codebase"

# Override the model
./main.sema -- -m claude-haiku-4-5-20251001
```

`./main.sema` works because the file is `chmod +x` with a `#!/usr/bin/env sema`
shebang. Set `ANTHROPIC_API_KEY` or `OPENAI_API_KEY` first.

## Architecture

```
sema-coder/
├── main.sema       Entry point — CLI parsing, boot, REPL/TUI dispatch
├── banner.sema     Wordmark + welcome (on-brand gold)
├── theme.sema      Brand palette (sema gold #c8a855)
├── config.sema     Config loading
├── commands.sema   Slash-command registry + built-ins
├── tools.sema      7 LLM-callable tools
├── agent.sema      System prompt + agent construction
├── display.sema    Output sink (emit) + tool-call rendering
├── tui.sema        Full-screen TUI — frame-diffed, async agent turns
└── util.sema       Path safety + string helpers
```

It is built on Sema's own primitives: `defagent` / `deftool` / `agent/run` (the
LLM agent loop), `async` / `async/cancel` (concurrent turns), `make-parameter` /
`parameterize` (the command registry), `mutable-array/*` (the streaming
transcript), `file/*` and `shell` (tools), `json/*` (config), `term/*` (theming +
screen control), `path/within?` (sandboxing), `llm/session-usage` (token/cost HUD).

In the TUI, an agent turn runs as an async task while a sibling task keeps pumping
input, so scrolling, resize, and type-ahead all work while tokens stream in, and
**Ctrl-C interrupts the turn** without killing the app.

## Slash commands

Built-ins: `/help`, `/model [name]`, `/clear`, `/tools`, `/cwd`, `/config`,
`/reload`, `/quit`, `/exit`. In the TUI, type `/` to open a fuzzy command palette.

### Adding commands — two ways

**1. Declaratively, in config (no code).** Add an entry to the `commands` map; the
key becomes `/name` and the value is a shell template run in the workspace, with
`$ARGS` replaced by whatever you type after the command.

**2. In Sema, one call.** Anywhere after loading `commands.sema`:

```scheme
(register-command! "diff" "Show the working-tree diff"
  (lambda (state args)
    (run-user-command "git diff $ARGS" args)
    state))
```

A handler receives the live REPL `state` map and the argument string, and returns
the next state (or the symbol `quit` to exit).

## Tools

`read-file`, `write-file`, `edit-file`, `bash`, `grep`, `find-files`, `list-dir`.
Every path — including the search tools' — resolves through `path/within?`, which
keeps reads, writes, and searches inside the workspace root (catching both `../`
and symlink escapes). The search tools invoke `rg`/`grep`/`find`/`ls` argv-style,
so patterns are never shell-interpreted.

## License

MIT
