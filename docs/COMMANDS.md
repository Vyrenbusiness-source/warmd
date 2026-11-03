# Commands and configuration

Back to the [README](../README.md). warmd decides and acts on its own, you rarely type these. This page is the reference for when you want to.

Examples show real output from a small throwaway Node project with one failing test (not part of the repo) and from `tests/fixtures`. Long paths are shortened to `<project>`. Exit code 0 means success, 1 a failed run, 2 a usage error, 3 a stalled agent.

## Everyday

### warmd status
Shows what was detected and what is warm. Use it first in a new project.
```text
warmd status
warmd 0.3.0: web project at <project>
heavy runs: 0 of 2
dev server off
```

### warmd build
Fastest compile or typecheck for the detected stack. Exit 1 on errors.
```text
warmd build
OK nothing to compile
```

### warmd test
Runs the tests. A green result is cached by code hash, a red one never. Exit 1 on red, with only the error lines and the path of the full log.
Syntax: `warmd test [filter] [--play|--edit] [--speed N]`. `WARMD_NOCACHE=1` ignores the cache.
```text
warmd test
FAIL 15s test (full log: <project>/.warmd/run/last.log)
ℹ fail 1
✖ failing tests:
  AssertionError [ERR_ASSERTION]: Expected values to be strictly equal:
    code: 'ERR_ASSERTION',
    expected: 5,
```

### warmd check
Builds, then runs only the tests that mention what you changed. Use it after every edit.
```text
warmd check
OK nothing to compile
OK no code changed against main
```

### warmd bench
Prints cold, warm and cached timings on your own project. Syntax: `warmd bench [filter]`.

### warmd shot
Desktop and 390 px phone screenshot, sized to cost few tokens. Syntax: `warmd shot [url|path]`.

### warmd layout
Finds layout problems and prints them as text, no screenshot. Syntax: `warmd layout [url|path]`. Exit 1 when problems exist.
```text
warmd layout index.html
both div#clip 120x24 text clipped by overflow hidden
both p#a x p#b 108x9 shared text boxes overlap
FOUND 2 layout problems
```

### warmd map
Outline with line numbers instead of the whole file. Syntax: `warmd map <file>`.
```text
warmd map src/cart.js
== cart.js
2 function lineTotal(item) {
6 function discount(total, code) {
```

### warmd audit
Shows what your agents pay for on every turn, biggest cost first.

### warmd run
Runs any command and keeps its output short: up to 20 lines pass through unchanged, longer output becomes one OK or FAIL line with the error lines, and the full log stays on disk. After `warmd init` the hooks send noisy known commands (test runners, builds, linters) through it on their own.

```text
warmd run -- git log --oneline -40
OK exit 0, 40 lines, 3299 B, 0s, raw log <cache>/runs/20261103-190700-1193.log
aac9096 warmd checks itself on merge, watch test matches the batch start rule
e4aac13 WIP hook: SessionStart batch state, SubagentStop ledger+push, automerge, init installs hooks
2e81174 warmd layout: layout problems as text lines at desktop and phone width
```

### warmd stop
Ends the warm process for real. Only processes warmd started are touched.

## Agents

### warmd route
Names the cheapest model tier that fits a goal. Syntax: `warmd route <goal> [files]`.
```text
warmd route fix typo in cart.js
mid model=sonnet budget=100k agent=warmd-worker
```

### warmd split
Turns a task list into worktrees, model tiers and one-line prompts. Syntax: `warmd split <tasks.txt>`, one task per line: `name | goal | done check | files`.
```text
warmd split tasks.txt
AGENT fix-total: subagent_type=warmd-worker model=sonnet prompt="Read <project>/.warmd/tasks/fix-total.md and do it."
AGENT add-tests: subagent_type=warmd-worker model=sonnet prompt="Read <project>/.warmd/tasks/add-tests.md and do it."
OK 2 tasks split. Start now, in the background: warmd watch
```

### warmd note
Adds one finding to the brief all agents of a batch share. Syntax: `warmd note "<one line>"`. Exit 2 without a batch.

### warmd escalate
Same task, next model tier, with the earlier commits as context. Syntax: `warmd escalate <name>`.

### warmd handoff
Context is filling up: saves state and prints the line for a fresh agent. Syntax: `warmd handoff <name> "<what is done>" "<what is next>"`. Refuses uncommitted work.

### warmd finish
Records cost, pushes, prints a one-line report. Syntax: `warmd finish [--tokens N --calls N --outcome ok|escalated|failed]`.
```text
warmd finish
DONE main 3e64022, 0 ahead, 0 uncommitted, local
```

### warmd report
Cost per tier and what escalation wasted.
```text
warmd report
no ledger yet, warmd finish writes it
```

### warmd gain
Reads Claude Code transcripts and prints tokens and dollars per session. Offline. Syntax: `warmd gain [transcript.jsonl]`. Exit 1 when no transcript exists.
```text
warmd gain tests/fixtures/gain/session1.jsonl
session    calls      input  cache-new  cache-read    output   hit%       usd
session1       2         20       1000        1000       150  49.5%      0.00
total          2         20       1000        1000       150  49.5%      0.00
cache saved 0.00 usd versus paying the input price for every cache-read token
```

### warmd board
All worktrees at a glance.
```text
warmd board
worktree                   branch                    age  dirty  ahead
p                          main                       0m      0      0
add-tests                  warmd/add-tests            0m      0      0
fix-total                  warmd/fix-total            0m      0      0
```

### warmd watch
Runs in the background and ends when an agent stalls or the batch is over. Syntax: `warmd watch [--once] [minutes]`, default 15. Exit 3 and a `STALLED` line when a worktree did not change.
```text
warmd watch --once
OK no batch running
```

### warmd merge
Safe merge into the base branch, rolls back on red. Syntax: `warmd merge <branch>`. After a conflict, resolve it and run `warmd merge --continue`. The gate is `check`, or `gate=` from `warmd.conf`. Exit 1 on red.

### warmd batch-done
Ends the batch, so the shared checkout opens again.

### warmd perf
Compares load time and bundle size to a stored baseline and refuses a regression over 5%. Syntax: `warmd perf [--save]`. Exit 2 without a baseline.
```text
warmd perf
FAIL perf: no baseline, run warmd perf --save first
```

## Setup

### warmd init
Installs the engine side, agent definitions and a short block in `CLAUDE.md` or `AGENTS.md`. With `--slim` it also gives project agents without a `tools` line the cheapest useful set. Syntax: `warmd init [--slim]`.

### warmd doctor
Checks what is missing.
```text
warmd doctor
detected: web at <project>
ok git
ok git repo
machine: 8 cores, 31 GB RAM
```

### warmd feedback
Prints a prefilled GitHub issue with your bench numbers. Nothing is sent.

### warmd update
Fetches the newest version, only when you run it.

### warmd package
Builds a player with your own method (Unity), see `package_method` below.

## Configuration

Everything is optional. Put a `warmd.conf` in the project root.

| Key | Meaning | Default |
|---|---|---|
| `build`, `test`, `lint`, `dev` | Override a command | detected |
| `url` | Dev server URL | read from its output |
| `base` | Base branch | from `origin/HEAD` |
| `slots` | Heavy runs per machine | 2 for Unity, half the cores otherwise |
| `idle_min` | Minutes until an idle daemon ends itself | 30 |
| `warm` | Keep a Godot process running | 0 |
| `cheap`, `mid`, `top` | Model per tier | haiku, sonnet, opus |
| `floor` | Lowest tier this project accepts: `mid` or `top` | none |
| `top_paths` | Paths that need the top tier (regex) | none |
| `shot_method` | Unity capture method | none |
| `package_method`, `package_args` | Unity player build for `warmd package` | none |
| `gate` | Shell command `warmd merge` runs instead of `check` | none |
| `perf`, `perf_cmd`, `perf_tolerance`, `perf_dir` | What `warmd perf` measures and the allowed slowdown in percent | detected, 5 |
| `port_env` | Env variable that gets a stable port per worktree | none |
| `seed_links` | Untracked folders linked into new worktrees | none |

Environment: `WARMD_NOCACHE=1`, `WARMD_TIMEOUT=900`, `WARMD_PROJECT=<path>`, `WARMD_UNITY`, `WARMD_GODOT`, `WARMD_BROWSER`, `WARMD_GFX=1`. Options: `-p <port>`, `--speed <N>`, `--play`, `--edit`. Unity also has `warmd call Namespace.Class.Method`.
