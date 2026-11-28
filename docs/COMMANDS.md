# Commands and configuration

Back to the [README](../README.md). warmd decides and acts on its own, you rarely type these. This page is the reference for when you want to.

Examples show real output from a small throwaway Node project with one failing test (not part of the repo) and from `tests/fixtures`. Long paths are shortened to `<project>`. Exit code 0 means success, 1 a failed run, 2 a usage error, 3 a stalled agent.

## Everyday

### warmd status
Shows what was detected and what is warm. Use it first in a new project. When the installed copy is behind its origin it adds one line `UPDATE installed <sha> behind origin <sha> by <n> commits, run: warmd update`; `warmd doctor` shows the same line. A background `git fetch` of the warmd clone refreshes this at most every 6 hours, `WARMD_UPDATE_CHECK=0` turns it off.
It also shows free RAM, in a Unity project every running Unity editor with its project path (warmd daemon, batchmode or window), and while a batch runs one line per branch with its last commit and how old it is.
```text
warmd status
warmd 0.4.11: unity project at <project>
heavy runs: 1 of 2
parallel agents: up to 4 (warmd.conf)
RAM free: 9082 MB of 31913 MB (28%)
Unity pid 22734: <worktree>/Game (warmd daemon)
batch warmd/nav: 5b53120c 9 min ago, nav: compass at the helm
Unity 6000.0.0f1 warm, pid 22734
```

### warmd build
Fastest compile or typecheck for the detected stack. Exit 1 on errors. A green compile is cached like a test run (see Cache under `warmd test`). Godot: the cache key holds the code including `project.godot`, the engine fingerprint and the warmd version; a red compile names each error as `file:line message`. Strict GDScript warnings at level 2 (`debug/gdscript/warnings/untyped_declaration`, `unsafe_*`) count as red, proven in CI with Godot 4.4.1.
```text
warmd build
OK nothing to compile
```

### warmd test
Runs the tests. Exit 1 on red, with only the error lines and the path of the full log.
Syntax: `warmd test [filter] [--play|--edit] [--speed N] [--window] [--sound]`. In a Godot project `test=` from `warmd.conf` is the project's own runner, the filter appended as one quoted argument (`test=bash tools/run_one.sh` runs `bash tools/run_one.sh "<filter>"`); without it a filter that names no `tests/run_*.gd` fails with the runner names instead of running the whole set. A test that waits or works 30 seconds prints one line with the reason (`WAIT slot 2/2 busy: ...`, `WAIT RAM 9% free, the run needs 15%`, `RUN import, the class cache is stale: ...`, `RUN test: <log>`; `WARMD_PHASE_SAY=<seconds>`, 0 = never). A run killed from outside leaves no mark that keeps `warmd state` on `ACTIVE`: a mark whose process is gone or whose pid now runs another process is removed when read. Unity runs are muted (the daemon sets `EditorUtility.audioMasterMute` before every run and `AudioListener.volume = 0` in PlayMode), `--sound` lets one run be heard. `WARMD_NOCACHE=1` ignores the cache.

Cache: a green result is kept 7 days, a red one 2 hours, per code state and engine fingerprint (engine version and binary, warmd version, `export_presets.cfg`, `WARMD_GODOT`, `WARMD_UNITY`, `WARMD_GFX`, `WARMD_WINDOW`, `WARMD_FULL`). A red hit prints `RED cached, code unchanged: <line>. Change code first. Log: <path>`, keeps the exit code and answers at once, without waiting for a slot or RAM. Timeouts, kills (exit 124 and up, also one killed test in a sh suite, which prints `<test> killed (exit N)`), a missing engine, RAM waits and crashes are never kept. `WARMD_NOCACHE=1` bypasses both caches.

Godot: a test that stops on a script error or ran no assert is red, and so is a runner that prints `SCRIPT ERROR` and still exits 0. `godot_allow_errors=<regex>` in `warmd.conf`, matched against `file:line message`, is the only way to let such an error pass, addons included. Old copies of `addons/warmd/warmd_test.gd` count no asserts until `warmd init` runs again.

Godot runners (`tests/run_*.gd`) share one engine start: `godot/daemon.gd` runs them one after another, each with its own verdict line. The order is random from a printed seed (`(runner order from seed N, WARMD_SEED=N replays it)`); `WARMD_SEED=<n>` replays that order and is never answered from the cache. A runner with `# warmd: isolate` in its first 10 lines (it changes autoloads or static state), one that does not compile as a guest and one that quits through the real tree get an engine of their own. A crash or hang in the shared engine is red with the runner's name; the runners after it get a new engine. The summary reads `N runners passed (X in one engine, Y alone)`.

`warmd build` (and so `warmd check`) in a Godot project loads every changed `.tscn` and `.tres` (against HEAD and the base branch, like the test selection) with ResourceLoader and instantiates each scene headless, never saved. Every engine error while it does is red as `file: message`: a dead path, a missing script, an inherited scene with a broken base, a signal connected to a method its target lacks. `godot_allow_errors` applies. The changed files are part of the build's cache key.

Unity `--window` (or `WARMD_WINDOW=1`) runs the tests with graphics in batchmode, like `WARMD_GFX=1`, with the hang detector on: a visible editor hung in a real run without `HUNG` firing. `WARMD_WINDOW_REAL=1` with it runs the tests in an editor with a window, for tests that skip their work in batchmode, PlayMode screenshots for example. `-monitor` is a player argument that an editor ignores, so the daemon moves its own main window through Win32 to monitor `WARMD_MONITOR` (default 2, monitor 1 is the primary) and maximizes it there; with one monitor it stays where it opened and says so. Before the start warmd removes `Temp/__Backupscenes` (the dialog Recovering Scene Backups) and stops when the manifest names a local package that is missing (the dialog Packages with Errors). Any other modal dialog during the start ends the editor at once with its title, text and buttons, nothing is answered. A headless daemon on the project makes way, and the window closes after the run. The window run has its own cache key.
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
Builds, then runs only the tests that reach what you changed through imports (JS and TS, Python, C# with asmdefs, GDScript). It keeps the time of the last full run and of the last selective check and takes the faster path: when the full suite was faster it runs that directly and says so. `WARMD_SELECT=1` forces the selection. In a bash project with `full=ci`, a change that needs the full self-test prints a `PUSH` line instead and leaves the full run to CI. Use it after every edit. In a Unity project check runs PlayMode tests only for the affected test classes, never the whole PlayMode suite: that runs in the merge gate or with `WARMD_FULL=1`. In Unity a filter that names a test file instead of a class (`DamageJobTests` for `DamageJobTests.cs`) runs the classes declared in that file and says so; a filter that matches no test is red. A test that hangs is named with `HUNG <test>`, at `test_timeout` or at the job timeout; the run then goes on in a fresh editor with the same filter, without the tests that already ran and without the hung one, up to `hung_resume` times, and ends with one list over all rounds (counts, every `HUNG` and every `RED` line, all rows in `.warmd/run/tests.txt`). Before every Unity run the daemon copy in `Assets/Editor/Warmd` is compared with the installed warmd and renewed when it differs, a warm editor restarts for it.
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
Outline with line numbers instead of the whole file. Syntax: `warmd map <file>`. With no file it prints a repo map: files ranked by how many files import them, each with the symbols its importers use, trimmed to `--budget N` tokens (default 1500). The repo map ranks Godot scenes too.
For a scene, `warmd map <scene.tscn>` prints its outline with line numbers: each node with its depth, type, script, instanced scene, groups and `%unique` name, then its signals as `line signal from -> to method`. At most `WARMD_MAP_NODES` nodes (default 80).
```text
warmd map src/cart.js
== cart.js
2 function lineTotal(item) {
6 function discount(total, code) {
```

### warmd where
Finds a term in a few lines instead of a search. Syntax: `warmd where <term>`. Prints at most 5 lines `file:line what` from a symbol index (`.gd`, `.tscn`, input actions, autoloads, groups, C#, TS, Python), path words, `# warmd: feature=a,b` tags and notes with `file:line`; German and English synonyms count. Then it lists what changed since the agent last read those places: moved, changed or gone. The index is kept per file hash in the git dir. A note whose file changed is found again through its symbol or marked `STALE`.
`warmd where --changed [ref]` lists every moved, changed, gone or added symbol since the last read, or since a git state.

### warmd peek
Plays a Godot scene headless and prints what it looks like as text. Syntax: `warmd peek <scene|res://path|Name> [frames]` (default 10 frames). Runs at a fixed 60 fps and lists per node its type, position, hidden state, animation, script and exported vars; it saves nothing. At most `WARMD_PEEK_NODES` nodes (default 80), the run ends after `WARMD_PEEK_TIMEOUT` seconds (default 120).

### warmd lint
Godot lints on the changed `.gd`, `.tscn` and `.tres` files, or on the given ones. Syntax: `warmd lint [files...]`. Runs as the first step of `warmd check` in a Godot project. Exit 1 on errors.
- ERROR only when the engine (headless, `godot/lint.gd`) or the disk proves it: unknown input action, `/root/` autoload, `tr` key, missing `res://` path, `res://` case that differs from the disk, collision layer outside 1-32.
- Everything else is WARN, at most `WARMD_LINT_WARN` (10): unconfirmed strings, groups nobody adds, layer names, `load`/`get_node` in `_process`, physics in `_process` or input, a shared `.tres` changed without `duplicate()`, unseeded random, wall clock, editable sub-scene children, scenes over `WARMD_LINT_NODES` (300) nodes, sub_resources over `WARMD_LINT_SUBRES_KB` (64) KB.
- The engine starts once, and only when candidates are still open.
```text
warmd lint
OK lint: no Godot file changed
```

### warmd audit
Shows what your agents pay for on every turn, biggest cost first.
It also lists every MCP server from `~/.claude.json` and `.mcp.json`, says which ones load their tool lists upfront (`"alwaysLoad": true`, `ENABLE_TOOL_SEARCH=false` or `auto`, a denied `ToolSearch`) and names the setting that defers them.

### warmd run
Runs any command and keeps its output short: up to 20 lines pass through unchanged, longer output becomes one OK or FAIL line with the error lines, and the full log stays on disk. After `warmd init` the hooks send noisy known commands (test runners, builds, linters) through it on their own.
`warmd run --heavy -- <command>` goes through the heavy queue first, like `warmd test`: free RAM, one of the machine's heavy slots, the disk check. A wait of 30 seconds prints one line naming the holders, `WAIT slot 2/2 busy: <worktree> <command>, <worktree> <command> (30s)`. With `heavy_cmd=<regex>` in `warmd.conf` the hook sends every Bash command that matches it there on its own (a leading `cd <dir> &&` stays in front), so agents that call a project's own engine or test runner directly never start more engines than there are slots. Every task file of `warmd split` says so in its `Heavy runs:` line.

```text
warmd run -- git log --oneline -40
OK exit 0, 40 lines, 3299 B, 0s, raw log <cache>/runs/20261103-190700-1193.log
aac9096 warmd checks itself on merge, watch test matches the batch start rule
e4aac13 WIP hook: SessionStart batch state, SubagentStop ledger+push, automerge, init installs hooks
2e81174 warmd layout: layout problems as text lines at desktop and phone width
```

### warmd stop
Ends the warm process for real. In a Unity project it then ends every other Unity editor started with exactly this `-projectPath` by another tool, because such an editor blocks the next start: a batchmode editor is asked first and ended hard after `WARMD_STOP_GRACE` seconds (default 15). An editor with a window may hold unsaved work, so it is only asked to close; `warmd stop --force` ends it hard. Each ended editor gets one line. `warmd stop --idle` (used by the agent hooks) keeps the engine while a warmd test, check or build of this project still runs.

## Agents

### warmd route
Names the cheapest model tier that fits a goal. Syntax: `warmd route <goal> [files]`.
```text
warmd route fix typo in cart.js
mid model=sonnet budget=100k agent=warmd-worker
```
Routing only learns upward: a failure moves a kind of task to a higher tier, a success never moves it down. A goal word from `top_words` routes to the top tier also for a read-only task (`files: none`); umlauts match in both spellings and any case (`Prüfung`, `PRUEFUNG`). A task line in `warmd split` may fix its tier with a fifth field: `name | goal | done check | files | tier=top` (`floor=` still holds, an editing task never goes below mid).

### warmd models
One model per role, kept in `warmd.conf` as `role_<role>=provider:model`. Syntax: `warmd models [--list | --set role=model... | --set preset=quality|balanced|frugal | --set cost_limit_day=N]`. Roles: `producer`, `worker`, `qa`, `reviewer`, `merge`, `scout`. Without arguments it opens a WinForms window on Windows and a text prompt elsewhere; the first interactive `warmd init` asks once. `--list` shows the success per model from the ledger. `reviewer` and `merge` never go below `floor`, `worker` and `qa` never get the cheap tier. `split` stops at `cost_limit_day` (`WARMD_COST_LIMIT=off` bypasses).
```text
warmd models --list
producer  (default)              model=opus         ok 18/18
worker    (default)              model=sonnet       ok 17/17
qa        (default)              model=sonnet       ok 17/17
reviewer  (default)              model=opus         ok 18/18
merge     (default)              model=sonnet       ok 17/17
scout     (default)              model=haiku        no data
cost_limit_day=none floor=top
```

### warmd split
A task whose goal names MCP tools (`roblox studio` or `mcp`, case-insensitive; change the pattern with `mcp_words` in `warmd.conf`) gets `subagent_type=warmd-worker-mcp` instead of `warmd-worker`/`warmd-scout`. That agent has no `tools` line, so the MCP tools of the session (Roblox Studio, any `mcp__*`) reach it; `warmd-worker` lists only Bash, Read, Edit, Write and would fail such a task silently. `warmd init` installs it, `warmd escalate`, `warmd handoff` and `warmd route` keep it. `init --slim` leaves it unrestricted.
Turns a task list into worktrees, model tiers and one-line prompts. Syntax: `warmd split <tasks.txt>`, one task per line: `name | goal | done check | files`.
```text
warmd split tasks.txt
AGENT fix-total: subagent_type=warmd-worker model=sonnet prompt="Read <project>/.warmd/tasks/fix-total.md and do it."
AGENT add-tests: subagent_type=warmd-worker model=sonnet prompt="Read <project>/.warmd/tasks/add-tests.md and do it."
OK 2 tasks split. Start now, in the background: warmd watch
```
Studio rules:
- Two tasks on the same scene never run in parallel: the second gets `WAIT <task>: ...` naming the way out (`warmd merge warmd/<holder>` or `warmd drop <holder>`) and is split again when the first is merged. A parked holder (its agent finished, no commit or file change for `scene_rest_hours`, default 4, 0 = always holds) holds no scene any more. A task's scenes are its `.tscn` files plus the scenes they reference by `res://`, one level deep.
- Every task file names a reviewer model that is not the author's model (`role_reviewer`, default the top tier).
- When the `warmd-worker` agent file is missing, split prints a `FALLBACK` line: a `general-purpose` agent with the worker rules inline. The agent files count in the folder the Claude Code session started in (`CLAUDE_PROJECT_DIR`, else the folder of the session's transcript) and in `~/.claude/agents`: a session started in a parent folder of the project gets the `FALLBACK` line, and `warmd init` warns about it.
- Every agent records its slowdowns with `warmd note "BRAKE: ..."`.
- A split while a merge of the same project runs waits for it (at most `merge_wait` seconds, default 900), so the worktrees start on the merged state; every task file names that commit in a `Base: <branch> at <sha> <subject>` line.
- Godot: a new or reused worktree gets the base checkout's git-ignored `.import` files it lacks, and an import when its class cache misses a `class_name` (once more when the engine crashes, `project.godot` left as committed); one `(worktree <name>: ...)` line says what was done.

### warmd note
Adds one finding to the brief all agents of a batch share. Syntax: `warmd note "<one line>"`. Exit 2 without a batch.

### warmd escalate
Same task, next model tier, with the earlier commits as context. Syntax: `warmd escalate <name>`.

### warmd handoff
Context is filling up: saves state and prints the line for a fresh agent. Syntax: `warmd handoff <name> "<what is done>" "<what is next>"`. Refuses uncommitted work.

### warmd finish
Records cost, pushes, prints a one-line report. Syntax: `warmd finish [--task <name>] [--tokens N --calls N --outcome ok|escalated|failed]`.
```text
warmd finish
DONE main 3e64022, 0 ahead, 0 uncommitted, local
```
A task past its time budget (`time_budget_cheap`, `time_budget_mid`, `time_budget_top`) gets `, OVER time budget: ...` in this line.
A read-only task (`files: none`, measuring or reading) has no worktree: `warmd finish --task <name>` in the base checkout records it and prints `DONE <name> read only, nothing to commit`; without `--task` it takes the one read-only task still open.

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
Runs in the background and ends when an agent stalls or the batch is over. Syntax: `warmd watch [--once] [minutes]`, default 5. An agent counts as active while a file or commit changes, a warmd run holds its worktree or a process runs inside it. The first minutes of a task, and of a fresh agent after a handoff, are reading: no `WAKE` before `watch_grace_cheap`, `watch_grace_mid` or `watch_grace_top` minutes of its tier (default 5, 10, 15). On a stall it prints one `WAKE <task>: idle N min in <path>. Send to the <task> agent: "..."` line per idle agent and exits 3; the session sends that message and starts the watch again. Queued AGENT lines end it the same way. An `ESCALATE` or `SHIP` line only a human can act on ends it with exit 4 and a closing `OPEN batch still runs` line; exit 0 only means no batch runs. `warmd watch --pause <name>` skips a task you stopped by hand until its worktree moves again. A task over its time budget is escalated: an `OVER <task>: ...` line and the `AGENT` line for the next tier.
```text
warmd watch --once
OK no batch running
```

### warmd merge
Safe merge into the base branch, rolls back on red. Syntax: `warmd merge <branch>... [--no-gate]`. Several branches are merged one after the other, one commit each, then one gate runs over all of them and one player build follows, not one per branch; red rolls every branch of the call back. After a conflict, resolve it and run `warmd merge --continue`: it commits the resolved branch and merges the ones after it. In a Godot project a conflict only in one-line lists of `project.godot` (`locale/translations=PackedStringArray(...)`, `editor_plugins/enabled`, ...) is joined on its own: HEAD's order stays, the branch's new entries are appended, an entry one side removed stays out, and one `resolved project.godot list <key>: +n entries` line names it. Any other conflict stops as before. The gate is `check`, or `gate=` from `warmd.conf`; in a Godot project whose class cache misses a `class_name` the merge brought, an import runs first; `--no-gate` skips it for an integration a human released. warmd cannot tell which changed file a `gate=` script reaches, so a red one runs once more after other heavy warmd runs ended (at most `gate_quiet_wait` seconds, default 300): green then merges with `WARN gate red only under load: ...`, red again rolls back; `gate_retry=0` turns this off, and a commit made during the gate skips it. With `package_dir` the merge starts `warmd package` in the background, so the player is always the merged base; without it the merge says that no player follows. Afterwards the engine caches of finished worktrees are freed (see `warmd disk`). The automatic merge at the end of a batch merges all green branches in one call and goes one by one only when that is red. A rolled-back merge writes a rule line into `.warmd/roles/<role>.md`, so the next agent of that role reads it. With `mutate=merge` in `warmd.conf` the merge also runs `warmd mutate`. Exit 1 on red.

```text
warmd merge warmd/a warmd/b warmd/c
```

### warmd batch-done
Ends the batch, so the shared checkout opens again.

### warmd drop
Cancels one task of a running batch that is not wanted any more. Syntax: `warmd drop <task> [reason] [--delete] [--force]`. The task leaves the batch: `warmd watch` stops waking it, `warmd status`, the batch guard and the automatic merge no longer count it, its files are free for the next split, and its queued ESCALATE or AGENT line is removed. It is recorded as dropped with the reason in `warmd-batch-dropped`, never as failed. The last drop of a batch ends it; when the tasks left are all finished, the automatic merge goes. The branch stays unless `--delete`: then the worktree and the branch (also on `origin`) are removed, but only when the branch has no commits that are not in the base and the worktree has no uncommitted files; otherwise it refuses with the reason and changes nothing. `--force` throws that work away. Split the task again and it is wanted again.
```text
warmd drop trace-sound "user does not want it" --delete
OK trace-sound dropped (user does not want it): worktree and branch warmd/trace-sound removed, watch and automerge ignore it
```

### warmd batch-resume
Builds the batch marker again from the open tasks: every task worktree with uncommitted work, commits not yet in the base, or a task file newer than its last commit. Same path form as `warmd split` writes, so the marker is never written by hand. Only tasks of the latest batch count: named in its shared brief, a task file from after the batch start, or an agent transcript that moved in the last 120 minutes; worktrees of earlier batches with unmerged commits stay out. Use it when the marker was lost while agents still work.

### warmd perf
Compares load time and bundle size to a stored baseline and refuses a regression over 5%. Syntax: `warmd perf [--save]`. Exit 2 without a baseline. The load time is the median of at least 5 loads after one discarded warm-up load, alternating with a tiny reference page from memory: when the reference loads slower than at `--save` (a busy CI runner), that difference is taken out before the compare. A regression needs a second measurement before it fails. Godot: `perf_scene=res://<scene>.tscn` in `warmd.conf` measures the frame time of that scene: wall time of 330 frames minus 30 frames without vsync, so the engine start cancels out. `perf_cmd` times any command (median of 3 runs) in every project. With `perf` set in `warmd.conf`, `warmd merge` runs the same compare and refuses a regression over `perf_tolerance` (5%).
```text
warmd perf
FAIL perf: no baseline, run warmd perf --save first
```

### warmd mutate
Proves that the tests notice the lines you changed. Syntax: `warmd mutate [--base REF] [--limit S] [--cmd C]`. One mutant per changed line (GDScript, sh, Python, JS and TS, never test files): each must turn a test red, else `SURVIVED file:line` and exit 1. The file is restored by a trap, also on a kill, and nothing is committed. The judge is `warmd check` without cache, or `--cmd`/`mutate_cmd=`; `--limit`/`mutate_limit=` caps the seconds (900). `mutate=merge` runs it in `warmd merge`. A line with `warmd: nomutate` is skipped. The score goes to `warmd-quality.tsv`.
```text
warmd mutate --base HEAD
OK mutate: no changed line to mutate since HEAD
```

### warmd nightly
Runs build and tests once without cache, each in its own process, and compares them with the cache. Syntax: `warmd nightly [--schedule|--report] [--no-mutate]`.
- `MISMATCH <name>`: the cached result differs and a second fresh run confirms it, so the cache key misses an input. Exit 1.
- `FLAKY <name>`: the second fresh run agrees with the cache, the result changes without a code change.
- Godot: every runner runs in its own engine with `--verbose`. A load the static graph did not predict is a `GAP` line and becomes an edge in `warmd-edges.tsv`.
- Then `warmd mutate` on the lines since the last night (`--no-mutate` or `mutate=off` skips it).
- A 5-line report goes to `.warmd/nightly.txt`, `--report` prints it. `--schedule` prints the schtasks and cron one-liner and installs nothing.
```text
warmd nightly --schedule
warmd nightly is not installed as a task by itself. One line, once, in a shell you trust:
  schtasks /Create /SC DAILY /ST 03:00 /TN "warmd nightly <name>" /TR "\"C:\Program Files\Git\usr\bin\bash.exe\" -lc \"cd '<project>' && warmd nightly >> .warmd/nightly.log 2>&1\""
  cron: 0 3 * * * cd '<project>' && warmd nightly >> .warmd/nightly.log 2>&1
The morning report: warmd nightly --report
```

### warmd ship
Builds a fresh integration branch `warmd-ship-<time>-<pid>` from `origin/<base>` (never shared between two ship calls or sessions; `--into` names one), merges the finished task branches one by one, pushes, opens or updates one PR, waits for CI and merges on green, and only when the PR head is the commit this call built (another session that pushed the branch stops it: `FAIL PR #N head is ..., not merged`). A conflict is resolved only when every conflicting line in `bin/warmd` is a usage or dispatch line, both sides are kept. Any other conflict stops with the file names. On red it names the failing tests and does not merge. `--release vX.Y.Z` first sets the version in `bin/warmd` and moves the Unreleased part of `CHANGELOG.md` to it, then creates the release with notes from `git log` since the last tag, deletes the merged task branches on `origin` and updates the installed copy when it is a clean clone of the same repo. Syntax: `warmd ship [--base B] [--release vX.Y.Z] <branch>...`. Needs `gh`.
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

### Claude Code plugin
`/plugin marketplace add Vyrenbusiness-source/warmd`, then `/plugin install warmd@warmd`. From a shell: `claude plugin marketplace add Vyrenbusiness-source/warmd` and `claude plugin install warmd@warmd [--scope project|local]`. The plugin brings the four hooks (`hooks/hooks.json`), the agents `warmd:warmd-worker`, `warmd:warmd-scout` and `warmd:warmd-merge`, and puts `warmd` on the PATH of the agent's Bash tool. A project without the warmd block in `CLAUDE.md` or `AGENTS.md` gets the block as session context at every start, nothing is written to the project. `warmd split` and `warmd route` name the namespaced agents. A project whose `.claude/settings.local.json` already holds hooks from `warmd init` keeps those, the plugin's hooks then do nothing, so no hook runs twice. `warmd init` under the plugin writes no hooks. `warmd ship --release` moves the version in `.claude-plugin/plugin.json` with `bin/warmd`, `/plugin update warmd@warmd` fetches it. The plugin's `warmd` is not on your own terminal's PATH: install the command for that.

### warmd init
Installs the engine side, agent definitions and a short block in `CLAUDE.md` or `AGENTS.md`, between `<!-- warmd ... -->` markers. The session start hook renews that block and the agent definitions in the shared checkout when a newer warmd brings other text, an older block without markers is replaced in place. With `--slim` it also gives project agents without a `tools` line the cheapest useful set. Syntax: `warmd init [--slim]`.

### warmd disk
Shows the free space and the finished worktrees that still hold an engine cache (a Unity `Library` is often several GB per worktree). `--free` cleans up now, wider than a merge: every worktree that is not an open task of the running batch, not locked, holds no engine and had 30 quiet minutes (no checkout, commit or index write) is removed with `git worktree remove --force` when its HEAD is in the base branch and it holds nothing of its own (untracked files count; `*.uid`, `*.import`, `*.translation`, `.godot/`, `override.cfg` do not), and gives its caches back otherwise. One line: `OK removed <n> merged worktrees, freed the caches of <m> others: <x> GB freed, <y> GB free`. Caches are the engine cache plus `target/`, `node_modules/` and `dist/` when git ignores them (in the worktree, the project folder and one level below). warmd does this by itself: `split` copies a cache only with room for it plus `disk_min_mb` and answers `WAIT` otherwise, every heavy run first frees finished caches and is refused below `disk_min_mb`, and every merge frees the caches (engine cache and ignored build folders) of the worktrees it finished. After a merge a cache is freed only when the worktree's HEAD is in the base branch, nothing is uncommitted, it is not in the running batch and no engine or warmd run is there; a worktree without work of its own also needs 30 quiet minutes. The next split that reuses it copies the cache again.
```text
warmd disk --free
```

### warmd doctor
Checks what is missing.
```text
warmd doctor
detected: web at <project>
ok git
ok git repo
machine: 8 cores, 31 GB RAM
```

### warmd resume
Resume after a reboot, Windows only. `warmd resume --arm <handoff.md>` writes `warmd-resume.cmd` into the user's Startup folder: after the next sign-in it opens a visible terminal in the folder `--arm` ran in, starts the Claude Code CLI (`~/.local/bin/claude.exe`, `WARMD_CLAUDE` overrides) with `Lies <handoff.md> und mache dort weiter.` and deletes itself, so it runs once. `--disarm` removes it, `warmd resume` alone says whether it is armed. Each call also says whether Windows signs in by itself (`AutoAdminLogon` in the Winlogon registry key); without it the PC waits at the sign-in screen. warmd only reads that value and never changes the sign-in.
```text
warmd resume --arm HANDOFF.md
OK resume armed: after the next sign-in Claude Code starts in C:\Users\me\game on C:\Users\me\game\HANDOFF.md (C:/Users/me/AppData/Roaming/Microsoft/Windows/Start Menu/Programs/Startup/warmd-resume.cmd)
WARN automatic sign-in is not set up (AutoAdminLogon 0): after a reboot the PC waits at the sign-in screen, the session resumes once someone signs in
```

### warmd reboot
`warmd reboot --if-starved` looks at the free RAM three times, 90 seconds apart (`WARMD_REBOOT_POLL`). Only when all three are below `ram_free_min`, the limit an engine run waits at, `reboot=1` is in `warmd.conf` and `warmd resume` is armed, it writes a line to `reboot.log` in the warmd cache and runs `shutdown /r /t 120`, which `shutdown /a` aborts. Without `reboot=1` it only prints what it would do (`DRY ...`). Armed is required: a reboot without resume would leave the work standing.
```text
warmd reboot --if-starved
DRY RAM stayed below ram_free_min 15% (9%, 8%, 8% over 180s). With reboot=1 in warmd.conf warmd would log it and run: shutdown /r /t 120
```

### warmd leak
Measures whether this machine loses kernel memory per process start: nonpaged and paged kernel pool and free RAM before and after N short process starts (default 500), as KB per start. It waits for a free slot and enough free RAM first, like every heavy run. Windows only, elsewhere it says so and exits 2. `WARMD_LEAK_CMD` sets the program started, `WARMD_LEAK_WARN_KB` (default 4) the growth per start that prints a `LEAK` line.
```text
warmd leak 500
warmd leak: 500 starts of true in 21s
nonpaged pool +2875 KB (+5.75 KB per start), now 1301 MB
paged pool    +12 KB (+0.02 KB per start), now 1908 MB
free RAM      -41 MB, now 5120 MB
LEAK kernel pool grows by about 5 KB per process start: a driver keeps memory until reboot (poolmon shows which tag)
```

### warmd feedback
Prints a prefilled GitHub issue with your bench numbers. Nothing is sent.

### warmd update
Fetches the newest version, only when you run it.

### warmd package
Builds a player with your own method (Unity), see `package_method` below. With `package_dir` the player has one fixed folder: the world step (`world_method`) runs first, the method gets the folder as `-warmdPackageDir <path>` and in `WARMD_PACKAGE_DIR` and overwrites what is there, and warmd checks that it wrote there. A player that still runs from the folder is waited for with one `WAIT` line, without holding a heavy slot, and nothing is written elsewhere instead. After every automatic merge at the end of a batch warmd runs `warmd package` on the merged base by itself, so there is always exactly one current player.

## Configuration

Everything is optional. Put a `warmd.conf` in the project root.

| Key | Meaning | Default |
|---|---|---|
| `build`, `test`, `lint`, `dev` | Override a command | detected |
| `heavy_cmd` | Regex: the hook sends matching Bash commands through `warmd run --heavy` (ATTRITION: `godot[^ ]* .*(--headless|-s +tests/)`) | none |
| `url` | Dev server URL | read from its output |
| `base` | Base branch | from `origin/HEAD` |
| `slots` | Heavy runs per machine | one per 4 cores and per 8 GB RAM, the smaller, at least 1 |
| `threads` | Build threads per heavy run | cores minus 2, shared by the slots |
| `agents` | Parallel agents of a batch | one per core and per 2 GB RAM, the smaller, at least 1 |
| `ram_free_min` | A Unity or Godot start waits while less than this percent of RAM is free, 0 turns it off | 15 |
| `ram_free_min_light` | Any other suite (web, Python, shell) waits only below this percent of free RAM, 0 turns it off | 3 |
| `ram_wait` | 0 turns the RAM wait off | 1 |
| `reboot` | 1 lets `warmd reboot --if-starved` restart the PC when the RAM stays below `ram_free_min` and `warmd resume` is armed | 0 |
| `nice` | Priority of heavy runs, 0 turns it off | 10 |
| `full` | `ci`: a bash project's full self-test runs on CI only | none |
| `budget_cheap`, `budget_mid`, `budget_top` | Token budget per tier in thousands, the handoff starts past 70% of it | 40, 100, 160 |
| `top_words` | Goal words that route to the top tier (regex, also for `files: none`; ä and ae match) | architecture, race condition, concurrency, physics, netcode, security, root cause, crash |
| `daemon_idle` | Minutes until an idle daemon ends itself (`idle_min` is the older name) | 10 |
| `world_method` | Unity: static method that builds the generated parts of the project. Runs in the warm editor before `test` and `check` whenever its sources changed since its last run, so a merge or a pull never leaves generated parts behind | off |
| `world_sources` | Paths (comma separated, in the project) whose change makes `world_method` run again | `Assets` |
| `world_outputs` | What `world_method` writes: not counted as a source change, left out of automatic commits; the merge gate commits it | none |
| `gfx_tests` | Unity: filter regex of tests that need a graphics device. A matching `warmd test` filter runs with graphics by itself (a headless daemon makes way); any test that fails with a graphics error such as `RenderTexture.Create failed` gets a `HINT needs graphics` line | none |
| `test_timeout` | Unity: seconds one test may run before it counts as hung and red; the test gets a `HUNG <test>` line and the run goes on after it (`hung_resume`) | off |
| `hung_resume` | Unity: how often a run goes on in a fresh editor after a `HUNG` test, the hung test and the finished ones left out; 0 stops at the first `HUNG` | 10 |
| `warm` | Keep a Godot process running | 0 |
| `export_smoke` | `warmd ship --release` and `warmd nightly` run the Godot export smoke (`warmd package`) first, red stops | 0 |
| `cheap`, `mid`, `top` | Model per tier | haiku, sonnet, opus |
| `floor` | Lowest tier this project accepts: `mid` or `top` | none |
| `top_paths` | Paths that need the top tier (regex) | none |
| `shot_method` | Unity capture method | none |
| `package_method`, `package_args` | Unity player build for `warmd package` | none |
| `test_port_env`, `test_port_base` | Env variable that gets a port of its own for every heavy run: base plus the slot number, unique on the machine; the Unity daemon sets it before each job | none, 7930 |
| `ram_stop_idle` | 0 keeps idle engine daemons of other worktrees running while a run waits for RAM | 1 |
| `package_dir` | The one player folder, relative to the project or absolute; set it and every merge refreshes the player there. Without it `merge` and `doctor` say that no player is built | none |
| `package_exe` | Player file name to wait for when it is no `.exe` or `.x86_64` | none |
| `gate` | Shell command `warmd merge` runs instead of `check` | none |
| `gate_retry` | A red `gate` runs once more alone before the merge rolls back (1), never (0) | 1 |
| `gate_quiet_wait` | Seconds that rerun waits for other heavy warmd runs to end | 300 |
| `merge_wait` | Seconds `warmd split` waits for a running merge of the same project | 900 |
| `scene_rest_hours` | Hours after which a finished, unmerged task stops holding its scenes for `split`; 0 holds until merge or drop | 4 |
| `disk_min_mb` | Space that stays free: split copies no cache and heavy runs refuse below it | 4096 |
| `disk_reclaim` | 0 keeps the engine caches of finished worktrees | 1 |
| `perf`, `perf_cmd`, `perf_tolerance`, `perf_dir` | What `warmd perf` measures and the allowed slowdown in percent | detected, 5 |
| `perf_scene` | Godot: scene whose frame time `warmd perf` measures | none |
| `godot_allow_errors` | Godot: regex on `file:line message` of script errors that do not make a build or test red | none |
| `port_env` | Env variable that gets a stable port per worktree | none |
| `mcp_words` | Regex (case-insensitive) on the task goal: a match routes the task to `warmd-worker-mcp` | `roblox studio|mcp` |
| `seed_links` | Untracked folders linked into new worktrees | none |
| `worktree_links` | Globs of git-ignored files or folders (relative to the project, e.g. `tools/luau/*.exe`) that `warmd split` copies (files) or links (folders) into each new worktree, so tool binaries exist there | none |
| `role_<role>` | Model per role as `provider:model`, roles `producer worker qa reviewer merge scout`; set with `warmd models` | preset quality |
| `time_budget_cheap`, `time_budget_mid`, `time_budget_top` | Time budget per tier in minutes; `watch` escalates a task past it, `finish` reports `OVER` | 30, 60, 120 |
| `watch_grace_cheap`, `watch_grace_mid`, `watch_grace_top` | Minutes after a task's start or handoff in which `watch` sends no `WAKE`, the agent reads | 5, 10, 15 |
| `cost_limit_day` | Daily cost limit in USD: `warmd split` stops when the day's ledger cost reaches it, `WARMD_COST_LIMIT=off` bypasses | none |
| `mutate` | `merge` runs `warmd mutate` in `warmd merge`, `off` skips it in `warmd nightly` | none |
| `mutate_cmd`, `mutate_limit` | Judge command of `warmd mutate` and its time limit in seconds | `warmd check` without cache, 900 |

Environment: `WARMD_NOCACHE=1`, `WARMD_SELECT=1` (always select affected tests), `WARMD_RAM_WAIT=1800` (longest RAM wait in seconds), `WARMD_UPDATE_CHECK=0` (no update check in `status` and `doctor`), `WARMD_CI_MAX=<minutes>` (cap of the CI wait), `WARMD_TIMEOUT=900`, `WARMD_PROJECT=<path>`, `WARMD_UNITY`, `WARMD_GODOT`, `WARMD_BROWSER`, `WARMD_GFX=1`, `WARMD_WINDOW=1`, `WARMD_MONITOR=2`, `WARMD_MAP_NODES=80`, `WARMD_PEEK_NODES=80`, `WARMD_PEEK_TIMEOUT=120`, `WARMD_LINT_WARN=10`, `WARMD_LINT_NODES=300`, `WARMD_LINT_SUBRES_KB=64`. Options: `-p <port>`, `--speed <N>`, `--play`, `--edit`, `--window`, `--sound`. Unity also has `warmd call Namespace.Class.Method`.

### warmd brake
Records what slowed an agent down in a machine-wide log (`brakes.tsv` in the warmd cache dir): date, project, task, cause, minutes, fix idea. Syntax: `warmd brake "<what>" [minutes] [fix idea]`. `warmd note "BRAKE: <what> | ~<min> | <fix>"` lands there too, once per text. `warmd report` and `warmd finish` print the brake minutes of the running batch in one line.

### warmd brakes
Causes from the brake log grouped by their words (case, digits and punctuation do not split a group) and ranked by total minutes lost, one line each, top 10. Syntax: `warmd brakes [--days N]`.

### warmd package (Godot)

Export smoke. The first preset of `export_presets.cfg` is exported with `--export-release` into a temp folder.
The release build starts headless for `export_frames` frames (default 120). A crash, a non-zero exit or a load error is red.
A release build prints no GDScript error, so the same pack then runs on the editor binary (`--main-pack`): a script error is red.
Without export templates only `--export-pack` runs, and the output says so. A build for another platform is exported but not started.
Needs `run/main_scene`. Config: `export_frames=`, `export_timeout=` (600 s), `export_run_timeout=` (120 s).

### warmd shot [scene] --golden | --golden-update [--from image.png]

Godot golden shot. The shot is compared with this machine's reference in `.warmd/golden/<machine>/<scene>.png`.
The answer is text: `SAME`, or `DIFF 3.2% in region x,y,w,h`. Channels within 8 of each other count as equal.
`golden_tolerance=<percent>` (default 0.5): a smaller share of differing pixels is `SAME` and still names its share.
Only `--golden-update` makes or renews a reference; a DIFF never does. `--from` compares an image made elsewhere.
A headless engine renders nothing. Then golden is red and says to run with `WARMD_GFX=1` on a machine with a display and GPU.

### warmd doctor (Godot)

Errors: `.uid` or `.import` files not versioned (folders a `.gitignore` pattern names and `.claude/worktrees/` are skipped, a `.uid` ignored by a `*.uid` pattern still counts), `.godot/` not ignored, Godot version not pinned, engine not the pinned version.
The pin is `godot_version=` in warmd.conf, else the version in `config/features` of project.godot.
A Godot outside PATH and `WARMD_GODOT` in a common place (Desktop, Downloads, Program Files, Steam, scoop, `~/.local/bin`) whose `--version` matches the pin is taken over into the warmd cache (`godot.path`) and reported `ok`; another version stays `MISSING` and is not remembered.

### Godot leaks at test end

Debug builds only. A WarmdTest test or a runner that leaves orphan nodes is red with the count:
`N orphan nodes left (leak, Node.print_orphan_nodes() lists them)`. A runner in its own engine is red on `ObjectDB instance(s) leaked at exit`.
Allowlist via `godot_allow_errors`, matched against `<file>: N orphan nodes` or `<file>: leaked at exit`.

### Godot budgets at merge

These run in the merge gate, or in any `warmd check` with `WARMD_BUDGET=1`. One engine start for all of them.
- `budget_texture_px=2048`: no changed texture longer than this on its long side (after `process/size_limit` of its .import).
- `budget_texture_raw_px=512`: no changed texture longer than this stored lossless or VRAM uncompressed (`compress/mode` 0 or 3).
- `budget_<scene>=draw_calls=200,memory_mb=64,nodes=500`: `<scene>.tscn` runs `budget_frames` frames (default 60), its peaks are compared. Draw calls need a renderer: such a budget runs with graphics.
- `rendered_smoke=1`: the main scene runs with graphics (graphics slot) on every merge; a script error is red.

### warmd sim
Runs Godot gameplay scenarios headless under a fixed tick, all in one engine start. Syntax: `warmd sim [--seed N] [file.sim|dir|name...]`. `--fixed-fps` is the number of physics ticks per second; the engine runs as fast as it can, never with `--time-scale`. One line per scenario, e.g. `FAIL jump: peak 6 > 5 at frame 16 of 200 (seed 1)` or `OK calm: peak 0 <= 1 (120 frames, seed 7)`. A scenario stops as soon as its verdict is decided.
- Scenario file `tests/sim/<name>.sim`: `scene res://x.tscn`, `seed N` (default 1), `frames N` (default 600), `isolate` (own engine), `metric <name> <max|min|last|avg|count|pct> <<=|<|>=|>|==> <limit> : <expression>` (Godot Expression on the scene root, `$Path` = node, sampled after every tick).
- Input lines: `<frame> press|release <action>`, `<frame> mouse x y`, `<frame> down|up <button> x y`.
- A script error while it runs is red with file:line. A hang or crash is red and never cached; the rest goes on in a new engine (`WARMD_SIM_TIMEOUT`).
- Verdicts are cached per scenario: code without `*.sim` + engine + scenario file + seed. `--seed N` overrides every seed and is its own key.
- Headless is not rendered: shaders, rendering, audio timing and the real mouse differ.

`warmd sim --record <scene> [--seed N] [--frames N] [--name x] [--headless]` plays the scene in a window and writes every input change per physics tick to `tests/sim/<x>.sim`. Add a metric that is red for the bug: the replay is a red scenario, then hand it to a worker.

### warmd state
Shows in one line whether warmd is working here: a run, merge, CI wait, a batch with its number of agents, the last result (green/red). Syntax: `warmd state [--json]`. `--json` prints `{active, what, agents, since, last, line}` for the VS Code status bar.
```text
warmd state
ACTIVE batch, 1 agents
```
VS Code extension in `vscode/`: `$(zap) warmd` idle (dim), `$(sync~spin) warmd <test|check|build|merge>` during a run, `$(organization) warmd N agents` in a batch, `$(cloud) CI` while waiting for CI, `$(pass)`/`$(error)` for 10 s after a result. The tooltip shows the state and the last line; a click runs `warmd status`. Install: `(cd vscode && npx @vscode/vsce package --skip-license) && code --install-extension vscode/warmd-*.vsix`.

### Project detection
warmd walks up from the current folder to the git root, then one level down, so an engine project in a subfolder of the repo is found too. `WARMD_PROJECT=<path>` always wins. A git root with its own `warmd.conf` (or warmd state in `.warmd/run`) stays the project: a `package.json` or `index.html` below it does not take over, only a Unity or Godot project in a subfolder does. Tooling folders (`vscode/`, `.vscode/`, `.github/`, `docs/`, `tools/`, `node_modules/`) never become the project. `warmd status` names the project in its first line.
