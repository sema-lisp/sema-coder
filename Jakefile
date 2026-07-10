# Jakefile — Sema Coder, the terminal coding agent written in Sema (jakefile.dev).
#
# `@rooted` resolves every relative path here against THIS repo's dir, so the
# workspace meta-repo can `@import "sema-coder/Jakefile" as coder` and run
# `coder.run` / `coder.test` from the workspace root.
@rooted

@group coder
@desc "Run the coder (interactive TUI on a TTY): jake coder.run [args='-- -p \"hi\"']"
task run args="":
    @needs sema
    ./coder.sema {{args}}

# jake only fills params as key=value, so the prompt MUST be passed as q='...'
# (a bare `jake coder.ask what is your name` leaves q empty — hence the guard).
@group coder
@desc "Run the coder one-shot with a prompt: jake coder.ask q='explain this codebase'"
task ask q="":
    @needs sema
    @[ -n "{{q}}" ] || { echo "usage: jake coder.ask q='your question here'" >&2; exit 2; }
    ./coder.sema -- -p "{{q}}"

@group coder
@desc "Run the whole tests/*_test.sema suite (the runner is itself Sema)"
task test:
    @needs sema
    sema tests/run.sema
