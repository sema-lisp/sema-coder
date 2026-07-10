# Phase 2 — Config-as-data + hot-reload — Implementation Plan

> **For agentic workers:** implement task-by-task, TDD, commit per task. Steps use `- [ ]`.

**Goal:** Replace the JSON config with an evaluated Lisp `init.sema` that produces
a config *value* the app reconciles to; live-reload it on save.

**Architecture:** `init.sema` calls value-returning constructors (`coder-config`,
`mcp-server`, `command`) and hands the result to `(configure! cfg)`. A **pure**
`load-config` returns `{:ok cfg}` / `{:error e}`; the caller applies model / turns
/ budget and reconciles the command registry, and (Phase 3) the MCP server set.
`fs/watch` on the config *directory* (debounced, basename-filtered) drives reload.

**Tech Stack:** Sema (Lisp). Tests are `.sema` scripts run with `sema` that
`exit 1` on failure.

## Global Constraints (verbatim from spec)
- Config is **data + reconcile**, never per-item mutation + reset.
- Commands are **argv by default** (`:run [...]`), never `sh -c` string
  substitution; `:shell` is an explicit opt-in escape hatch. (Matches the tool
  discipline; closes the injection footgun.)
- Runtime state read in loops uses **in-place `mutable-array`** (#82); config is an
  **immutable value**.
- `(agent {…})`, not `defagent`. Derive tool names via `(map tool/name (all-tools))`.
- Keep `agent/run` + `:messages` + `llm/session-usage`.
- Config file: `<sys/config-dir>/sema/sema-code/init.sema`. No JSON, no migration.

---

### Task 0: Test harness

**Files:** Create `tests/harness.sema`, `tests/run.sh`.

**Produces:** `(check label actual expected)`, `(check-true label v)`, `(done)`.

- [ ] **Step 1 — harness** (`tests/harness.sema`):
```scheme
(define *checks* 0)
(define *fails* 0)
(defun check (label actual expected)
  (set! *checks* (+ *checks* 1))
  (if (equal? actual expected)
    (io/println-error (str "  ok   " label))
    (begin (set! *fails* (+ *fails* 1))
           (io/println-error (format "  FAIL ~a — expected ~a, got ~a" label expected actual)))))
(defun check-true (label v) (check label (if v #t #f) #t))
(defun done ()
  (io/println-error (format "~a checks, ~a failed" *checks* *fails*))
  (exit (if (> *fails* 0) 1 0)))
```
- [ ] **Step 2 — runner** (`tests/run.sh`): `#!/bin/sh` + `for f in tests/*_test.sema; do sema "$f" || exit 1; done`
- [ ] **Step 3 — smoke test** `tests/harness_test.sema`: `(load "harness.sema") (check "eq" 1 1) (done)` → `sema tests/harness_test.sema` exits 0.
- [ ] **Step 4 — commit** `test: sema test harness`.

---

### Task 1: Config constructors + pure loader

**Files:** Rewrite `config.sema`; Test `tests/config_test.sema`.

**Interfaces — Produces:**
- `(mcp-server name opts)` → `{:name :opts :autostart :transport}` (opts = the
  `mcp/connect` map minus `:autostart`).
- `(command name spec)` → `spec` + `{:name name}`; spec has `:desc` and one of
  `:run`(argv vector, `:args` marks arg splice) / `:do`(fn) / `:shell`(string).
- `(coder-config kvmap)` → the config map (identity/validation; fills defaults).
- `(configure! cfg)` → stores cfg in `*config*` (single sink; replaces wholesale).
- `(load-config path)` → `{:ok cfg}` | `{:error e}` — **pure**: reads+evals the
  file, returns a value; no `emit`, no I/O side effects beyond reading.

- [ ] **Step 1 — failing test** (`tests/config_test.sema`):
```scheme
(load "harness.sema")
(load "../config.sema")
;; constructors return values
(check "mcp-server record" (mcp-server "sema" {:command "sema" :args ["mcp"] :autostart #t})
       {:name "sema" :opts {:command "sema" :args ["mcp"]} :autostart #t :transport "stdio"})
(check "mcp-server http transport" (:transport (mcp-server "a" {:url "http://x"})) "http")
(check "command argv" (command "test" {:desc "t" :run ["make" "test"]})
       {:name "test" :desc "t" :run ["make" "test"]})
;; load-config on a good file returns {:ok cfg}
(file/write "/tmp/sc-init-ok.sema"
  "(configure! (coder-config {:model \"m\" :max-turns 9 :commands (list (command \"t\" {:run [\"echo\"]}))}))")
(let ((r (load-config "/tmp/sc-init-ok.sema")))
  (check-true "ok result" (:ok r))
  (check "model applied" (:model (:ok r)) "m")
  (check "one command" (length (:commands (:ok r))) 1))
;; load-config on a broken file returns {:error e}, does NOT throw
(file/write "/tmp/sc-init-bad.sema" "(this is (not balanced")
(check-true "error result" (:error (load-config "/tmp/sc-init-bad.sema")))
(done)
```
- [ ] **Step 2 — run, expect FAIL** (`sema tests/config_test.sema` → unbound `mcp-server`).
- [ ] **Step 3 — implement** `config.sema`:
```scheme
;; config.sema — config as data (constructors + pure loader + reconcile).
(load "util.sema")

(defun config-dir ()  (path/join (sys/config-dir) "sema" "sema-code"))
(defun config-path () (path/join (config-dir) "init.sema"))

(define default-config {:model "" :max-turns 50 :context-budget 80000
                        :mcp-servers '() :commands '()})

;; ── Constructors: return values, never mutate ──
(defun mcp-server (name opts)
  {:name name
   :opts (without opts :autostart)          ; the mcp/connect map
   :autostart (get opts :autostart #f)
   :transport (if (get opts :url #f) "http" "stdio")})

(defun command (name spec) (assoc spec :name name))

(defun coder-config (m) (merge default-config m))

;; ── Single sink + pure loader ──
(define *config* default-config)
(defun configure! (cfg) (set! *config* cfg) cfg)

(defun load-config (path)
  "Pure: read+eval PATH, capture the configured value. {:ok cfg} | {:error e}."
  (try
    (begin (load path) {:ok *config*})
    (catch e {:error e})))
```
`without` (strip a key) — if absent in stdlib, add to `util.sema`:
`(defun without (m k) (apply hash-map (apply append (filter (fn (p) (not (equal? (car p) k))) (->pairs m)))))`
*(verify `merge`, `without`/`dissoc`, `->pairs`/`entries` against the stdlib while
implementing; use whatever the stdlib provides — the record shapes above are the
contract.)*
- [ ] **Step 4 — run, expect PASS.** Adjust helper impls until green.
- [ ] **Step 5 — commit** `feat(config): data constructors + pure loader`.

---

### Task 2: config path + annotated default writer

**Files:** Modify `config.sema`; Test `tests/config_default_test.sema`.

**Produces:** `(ensure-config!)` → writes the annotated default `init.sema` if
absent, returns the path; `default-init-source` (the string from spec §3.3).

- [ ] **Step 1 — failing test:** point `config-dir` at a temp dir (rebind or pass
  a dir), call `ensure-config!`, assert the file now exists and re-`load`ing it
  yields `{:ok}` with the `sema` autostart server present:
```scheme
(load "harness.sema")
(load "../config.sema")
(define d "/tmp/sc-cfg-test")
(shell "rm" "-rf" d)
(with-config-dir d (lambda ()
  (ensure-config!)
  (check-true "file created" (file/exists? (config-path)))
  (let ((r (load-config (config-path))))
    (check-true "default loads ok" (:ok r))
    (check "sema server autostart" (:autostart (car (:mcp-servers (:ok r)))) #t))))
(done)
```
- [ ] **Step 2 — run, expect FAIL.**
- [ ] **Step 3 — implement** `default-init-source` (verbatim spec §3.3 string),
  `ensure-config!` (`file/mkdir` the dir, `file/write` the default if missing),
  and a `with-config-dir` test seam (parameterize the dir). Use
  `make-parameter` for the dir so tests rebind it.
- [ ] **Step 4 — run, expect PASS.**
- [ ] **Step 5 — commit** `feat(config): annotated default init.sema`.

---

### Task 3: apply + command registry reconcile

**Files:** Modify `config.sema`, `commands.sema`; Test `tests/reconcile_test.sema`.

**Interfaces — Produces:** `(apply-config! cfg state)` → next state with
`:model`/`:max-turns` applied and the **config-owned command set replaced** (not
accumulated) in the registry; argv/`:do`/`:shell` command dispatch.

- [ ] **Step 1 — failing test:** apply a cfg with commands `[a b]`, assert both
  registered; apply a cfg with `[a]`, assert `b` is **gone** (replaced, no
  accumulation — the whole point vs v1):
```scheme
(check "two commands" (sort (config-command-names (apply-config! cfg-ab s))) (list "a" "b"))
(check "reload drops b"  (config-command-names (apply-config! cfg-a  s)) (list "a"))
;; argv command runs argv, not sh -c (injection closed)
(check "argv not shell" (run-command-argv (command "x" {:run ["echo" :args]}) "hi; rm")
       "hi; rm\n")   ; the literal string is one echo arg, not two shell tokens
```
- [ ] **Step 2 — run, expect FAIL.**
- [ ] **Step 3 — implement:** a `*config-commands*` set the registry overlays;
  `apply-config!` clears it and re-registers from `(:commands cfg)`; a
  `run-command-argv` that builds argv by splicing `:args` (the typed string as a
  **single** element, or split — decide: single arg is safest) and runs via
  `(apply shell argv)` (argv form, no `sh -c`). `:do` calls the handler; `:shell`
  uses the old `run-user-command` path (explicit opt-in).
- [ ] **Step 4 — run, expect PASS.**
- [ ] **Step 5 — commit** `feat(config): apply + command reconcile (argv, no shell)`.

---

### Task 4: `(agent {…})` switch + derived tool names

**Files:** Modify `agent.sema`, `tools.sema`, `commands.sema`, `tui.sema`; Test
`tests/agent_test.sema`.

- [ ] **Step 1 — failing test:** `create-agent` returns an agent value;
  `(tool-names)` equals `(map tool/name (all-tools))`; rebuilding twice doesn't
  error.
- [ ] **Step 2 — run, expect FAIL.**
- [ ] **Step 3 — implement:** `create-agent` uses `(agent {:system … :tools … :max-turns … :model …})`
  (drop `defagent sema-coder-agent`); replace the hardcoded `tool-names` list with
  `(defun tool-names () (map tool/name (all-tools)))` and update `/tools` +
  palette callers.
- [ ] **Step 4 — run, expect PASS + `sema/check-file` all files `:ok`.**
- [ ] **Step 5 — commit** `refactor: (agent {}) + derived tool names`.

---

### Task 5: hot-reload wiring + `/config` + feedback

**Files:** Modify `tui.sema`, `commands.sema`, `main.sema`; Test
`tests/hotreload_test.sema` (headless reconcile) + PTY manual check.

**Produces:** `(start-config-watch!)` (fs/watch the *dir*), `(poll-config!)`
(drain events, debounce, basename-filter `init.sema`, on settled change
`load-config` → `apply-config!` → feedback), `/config` (show path) + `/config edit`
(OS open) + `/reload`.

- [ ] **Step 1 — failing test (headless):** simulate two loads of different files
  and assert `apply-config!` reflects the second (model/commands changed), and a
  broken reload keeps the last-good `*config*` and surfaces an error value.
- [ ] **Step 2 — run, expect FAIL.**
- [ ] **Step 3 — implement:** `poll-config!` reads `fs/watch-events`, keeps a
  `*reload-pending-since*` timestamp (`time-ms`), and only reloads once no event
  has arrived for ~150ms (debounce); filters events to basename `init.sema`; on
  reload calls `load-config`; `{:ok}` → `apply-config!` + toast; `{:error}` →
  set a `*config-error*` flag rendered persistently in the header until the next
  clean load. Wire `poll-config!` into the TUI idle loop and the turn pump (like
  `check-resize!`). Read the pending/error flags via **accessor fns** (#82).
- [ ] **Step 4 — run headless PASS; PTY manual:** boot, edit `init.sema`
  (`set model`), save, see "config reloaded" + header model change; write broken
  syntax, save, see persistent "config error — using last good"; `/quit` exits.
- [ ] **Step 5 — commit** `feat(config): fs/watch hot-reload + /config + feedback`.

---

## Phase 2 done-when
Editing `init.sema` and saving live-updates the model and the slash-command set
(argv commands run without a shell); a broken edit is caught and the last-good
config keeps running with a visible error; `create-agent` uses `(agent {…})`;
tool names are derived. MCP `:mcp-servers` are parsed and stored but not yet
connected (Phase 3).

## Self-review notes
- Spec coverage: §3 (constructors, pure loader, default) = Tasks 1–2; §3.2
  reconcile-no-reset = Task 3; §5.3 `(agent {})` = Task 4; §4 hot-reload
  (dir-watch, debounce, feedback, `/config`) = Task 5. MCP connect/modal/markdown
  = later phases (own plans).
- Verify-at-impl (stdlib shapes, not contracts): `merge`, key-strip
  (`without`/`dissoc`), map→pairs, `&` rest / kwargs, `sort`, `(apply shell argv)`
  arg semantics, `load` return value (the loader relies on `configure!`'s side
  effect into `*config*`, not `load`'s return — robust regardless).
