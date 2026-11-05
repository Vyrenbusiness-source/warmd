# Commands and configuration

Back to the [README](../README.md). warmd decides and acts on its own, you rarely type these. This page is the reference for when you want to.

Examples show real output from a small throwaway Node project with one failing test (not part of the repo) and from `tests/fixtures`. Long paths are shortened to `<project>`. Exit code 0 means success, 1 a failed run, 2 a usage error, 3 a stalled agent.

## Everyday

### warmd status
Shows what was detected and what is warm. Use it first in a new project. When the installed copy is behind its origin it adds one line `UPDATE installed <sha> behind origin <sha> by <n> commits, run: warmd update`; `warmd doctor` shows the same line. A background `git fetch` of the warmd clone refreshes this at most every 6 hours, `WARMD_UPDATE_CHECK=0` turns it off.
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
Builds, then runs only the tests that reach what you changed through imports (JS and TS, Python, C# with asmdefs, GDScript). It keeps the time of the last full run and of the last selective check and takes the faster path: when the full suite was faster it runs that directly and says so. `WARMD_SELECT=1` forces the selection. In a bash project with `full=ci`, a change that needs the full self-test prints a `PUSH` line instead and leaves the full run to CI. Use it after every edit.
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
Outline with line numbers instead of the whole file. Syntax: `warmd map <file>`. With no file it prints a repo map: files ranked by how many files import them, each with the symbols its importers use, trimmed to `--budget N` tokens (default 1500).
```text
warmd map src/cart.js
== cart.js
2 function lineTotal(item) {
6 function discount(total, code) {
```

### warmd audit
Shows what your agents pay for on every turn, biggest cost first.
It also lists every MCP server from `~/.claude.json` and `.mcp.json`, says which ones load their tool lists upfront (`"alwaysLoad": true`, `ENABLE_TOOL_SEARCH=false` or `auto`, a denied `ToolSearch`) and names the setting that defers them.

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
Runs in the background and ends when an agent stalls or the batch is over. Syntax: `warmd watch [--once] [minutes]`, default 5. An agent counts as active while a file or commit changes, a warmd run holds its worktree or a process runs inside it. On a stall it prints one `WAKE <task>: idle N min in <path>. Send to the <task> agent: "..."` line per idle agent and exits 3; the session sends that message and starts the watch again. Queued escalations end it the same way. `warmd watch --pause <name>` skips a task you stopped by hand until its worktree moves again.
```text
warmd watch --once
OK no batch running
```

### warmd merge
Safe merge into the base branch, rolls back on red. Syntax: `warmd merge <branch>`. After a conflict, resolve it and run `warmd merge --continue`. The gate is `check`, or `gate=` from `warmd.conf`. Exit 1 on red.

### warmd batch-done
Ends the batch, so the shared checkout opens again.

### warmd batch-resume
Builds the batch marker again from the open tasks: every task worktree with uncommitted work, commits not yet in the base, or a task file newer than its last commit. Same path form as `warmd split` writes, so the marker is never written by hand. Use it when the marker was lost while agents still work.

### warmd perf
Compares load time and bundle size to a stored baseline and refuses a regression over 5%. Syntax: `warmd perf [--save]`. Exit 2 without a baseline.
```text
warmd perf
FAIL perf: no baseline, run warmd perf --save first
```

### warmd ship
Builds the integration branch `warmd-ship` from `origin/<base>`, merges the finished task branches one by one, pushes, opens or updates one PR, waits for CI and merges on green. A conflict is resolved only when every conflicting line in `bin/warmd` is a usage or dispatch line, both sides are kept. Any other conflict stops with the file names. On red it names the failing tests and does not merge. `--release vX.Y.Z` first sets the version in `bin/warmd` and moves the Unreleased part of `CHANGELOG.md` to it, then creates the release with notes from `git log` since the last tag, deletes the merged task branches on `origin` and updates the installed copy when it is a clean clone of the same repo. Syntax: `warmd ship [--base B] [--release vX.Y.Z] <branch>...`. Needs `gh`.
```text
warmd ship alpha beta
ok   merged alpha
ok   merged beta, usage/dispatch conflict resolved
ok   opened PR #7
ok   self-test (windows-latest)
ok   shellcheck
GREEN run 41
ok   merged PR #7 into main
SHIPPED PR #7
```

### warmd ci
Waits for the newest CI run of the current branch, prints one line per job and the failing test names on red. Syntax: `warmd ci [branch]`. Exit 1 on red.
It polls GitHub instead of blocking, so it notices trouble by itself:
- the first red job, or a failed step in a job that still runs, ends the wait at once;
- a job whose steps are all finished counts by its steps, even while GitHub still shows it in progress;
- `ETA` gives the minutes left from the median of recent green runs, `SLOW` names job and step once a run passes 1.5 times that median;
- the wait stops at twice the median (at least 5 min, 20 min without history). `WARMD_CI_MAX=<minutes>` sets the cap by hand.
While it waits, `warmd watch` counts the agent as busy, not idle.
```text
warmd ci
ETA run 41: about 3 min left, median 5 min of 6 runs
FAIL shellcheck
RED run 41
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
| `slots` | Heavy runs per machine | one per 4 cores and per 8 GB RAM, the smaller, at least 1 |
| `threads` | Build threads per heavy run | cores minus 2, shared by the slots |
| `agents` | Parallel agents of a batch | one per core and per 2 GB RAM, the smaller, at least 1 |
| `ram_free_min` | A Unity or Godot start waits while less than this percent of RAM is free, 0 turns it off | 15 |
| `ram_free_min_light` | Any other suite (web, Python, shell) waits only below this percent of free RAM, 0 turns it off | 3 |
| `ram_wait` | 0 turns the RAM wait off | 1 |
| `nice` | Priority of heavy runs, 0 turns it off | 10 |
| `full` | `ci`: a bash project's full self-test runs on CI only | none |
| `budget_cheap`, `budget_mid`, `budget_top` | Token budget per tier in thousands, the handoff starts past 70% of it | 40, 100, 160 |
| `top_words` | Goal words that route to the top tier (regex) | architecture, race condition, concurrency, physics, netcode, security, root cause, crash |
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

Environment: `WARMD_NOCACHE=1`, `WARMD_SELECT=1` (always select affected tests), `WARMD_RAM_WAIT=1800` (longest RAM wait in seconds), `WARMD_UPDATE_CHECK=0` (no update check in `status` and `doctor`), `WARMD_CI_MAX=<minutes>` (cap of the CI wait), `WARMD_TIMEOUT=900`, `WARMD_PROJECT=<path>`, `WARMD_UNITY`, `WARMD_GODOT`, `WARMD_BROWSER`, `WARMD_GFX=1`. Options: `-p <port>`, `--speed <N>`, `--play`, `--edit`. Unity also has `warmd call Namespace.Class.Method`.
