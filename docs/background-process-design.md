# Background process design

## Problem

The foreground `bash` tool waits for a command to exit. That is correct for
builds and tests whose result is needed before the next agent step. It is wrong
for servers, file watchers, and other long-running commands: the tool call never
finishes, so the agent cannot inspect the server, continue the task, or react to
new user input without cancelling the command.

## Reference behavior

Codex and Claude Code both separate a long-running process from the agent turn
which launched it.

- Codex `exec_command` yields a process session ID when a command remains live.
  `write_stdin` polls or interacts with that session. Turn interruption does not
  terminate retained background terminals; explicit process cleanup does.
- Claude Code accepts `run_in_background` on Bash and returns a task ID.
  Output and stop operations address that task separately. Background Bash is
  scoped to the live session and is not restored by normal session resume.
- Both systems keep process state bounded and expose explicit lifecycle state.
  Neither treats a successful launch as proof that the command later succeeded.

Primary sources:

- [Codex unified exec tool schema](https://github.com/openai/codex/blob/0344625ccf4ae0ab6472c6c1e7b4ace6af14661e/codex-rs/core/src/tools/handlers/shell_spec.rs)
- [Codex unified exec process manager](https://github.com/openai/codex/blob/0344625ccf4ae0ab6472c6c1e7b4ace6af14661e/codex-rs/core/src/unified_exec/process_manager.rs)
- [Codex unified exec integration tests](https://github.com/openai/codex/blob/0344625ccf4ae0ab6472c6c1e7b4ace6af14661e/codex-rs/core/tests/suite/unified_exec.rs)
- [Claude Code background Bash commands](https://code.claude.com/docs/en/interactive-mode#background-bash-commands)
- [Claude Code tool reference](https://code.claude.com/docs/en/tools-reference#background-commands)

## Sema Coder contract

`bash` has two modes:

| Mode | Ownership | Result |
| --- | --- | --- |
| Foreground | Current agent turn | Wait for exit; return bounded output and exit status; kill on timeout or turn cancellation |
| Background | Current Sema Coder process | Return a task ID immediately; continue across turns and turn interruption; stop on explicit request or app exit |

Background mode is non-interactive. Sema Coder closes the child process's stdin
immediately. Commands which require a prompt, confirmation, or terminal must
stay in the foreground or use a future PTY-specific feature.

The model-facing operations are:

| Tool | Operation |
| --- | --- |
| `task-output` | Poll one task, or wait up to a deadline, and return retained stdout/stderr plus state |
| `task-list` | List current task IDs and summary state |
| `task-stop` | Terminate one task and its descendant processes |

The user-facing diagnostic is `/debug tasks`. `/debug status` also includes
task summaries. There is no top-level `/tasks` command because task state is
diagnostic and the command namespace should remain available for user work.

## Lifecycle

A task moves through these states:

```text
running -> settling -> completed
                    -> failed
running -> stopping -> stopped
```

`settling` means the child has exited and Sema Coder is waiting for the native
stdout/stderr readers to flush before it closes the handle. `stopping` prevents
the monitor and an explicit stop operation from acting on the same live process
at once.

The task registry is updated before `bash` returns. It issues a short monotonic
process-local ID (`task-1`, `task-2`, and so on) and stores the native process
handle, command, timestamps, state, exit code, and two bounded output captures.
The registry does not enter the conversation history and is not saved in
session JSONL files.

The TUI starts one monitor task outside every agent turn. This ownership is
important because Sema task cancellation propagates to spawned descendants. A
monitor spawned inside the `bash` tool call would be cancelled with that agent
turn even though the native process handle remained live. The TUI-owned monitor
survives turn cancellation, drains output every 25 ms, and finalizes exited
processes. `task-output` also polls directly, which supports the plain REPL and
deterministic tests without a running TUI monitor.

## Bounds and cleanup

- At most 32 task records are retained. A new launch removes the oldest settled
  record when needed. It never evicts a live process.
- Stdout and stderr each retain their first 25,000 and newest 25,000
  characters. The result reports total characters and whether content was
  omitted.
- Background stdin is closed at launch.
- `task-stop` uses the same Unix process-group cancellation path as foreground
  timeout, so descendant processes are terminated with the shell leader.
- After the shell leader exits, finalization allows 250 ms for output-reader
  EOF. If self-backgrounded descendants keep the pipes open, Sema Coder stops
  the remaining process group and records a cleanup warning instead of leaving
  the task in `settling` indefinitely.
- Normal TUI exit stops every active task. Sema's interpreter teardown is the
  fallback for fatal exits and other frontends.
- Background tasks are not restored after app restart.

The native `proc/*` reader threads temporarily hold output produced between
monitor polls. Sema Coder bounds the retained application copy, but the current
`proc/spawn` API does not impose a native buffer limit. A future Sema runtime
change should add a bounded head/tail mode to `proc/spawn` if untrusted commands
can produce output faster than a 25 ms monitor pass can drain it.

## Verification

The deterministic tests cover:

- immediate return with a stable task ID;
- successful and failed exit status;
- retained stdout and stderr;
- closed stdin;
- bounded head/tail capture and truncation reporting;
- survival after cancellation of the task which launched the process;
- survival of the TUI-owned monitor after that cancellation;
- descendant-process termination through `task-stop`;
- registry cleanup without process leaks;
- pretty-printed `/debug tasks` output.

The opt-in live-provider check is:

```bash
SEMA_CODER_LIVE=1 sema tests/live_interrupt_smoke.sema -- background
```

It verifies that the configured model follows the prompt contract: launch in
background mode, wait with `task-output`, inspect terminal state and output,
then report the result.
