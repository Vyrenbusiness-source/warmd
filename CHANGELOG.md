# Changelog

All notable changes to warmd. Versions follow [Semantic Versioning](https://semver.org). Every release is a git tag; pin one with `WARMD_VERSION_TAG=<tag>` at install.

## [Unreleased]

### Fixed
- An engine that exits while warmd waits for it to start (compiler errors end a batchmode Unity with return code 1) ends the wait at once: the heavy slot is freed, the unique `error CS` lines of the engine log (at most 10) and a closing `FAIL` follow, exit 1. Was up to 600 s of "daemon not ready" with the slot held and nobody alive. Checked with the kill builtin on Linux and macOS, one tasklist every 5 s on Windows (`WARMD_SPAWN_POLL`)
- `warmd build`, `check` and `test` always close with an `OK` or `FAIL` line, also after an exit deep inside the run: an agent that pipes through `tail` loses the exit code, never the verdict
- Past the context limit an agent can still save: `git add`, `commit` and `push`, a `cd` before them and `| tail` behind them pass with `warmd handoff`, `note` and `finish`; every part of a chain has to be one of these
- The automatic WIP commit leaves warmd's own `Assets/Editor/Warmd` and the `.sln`, `.slnx` and `.csproj` files Unity writes out of the task branch
- `warmd watch` ends with exit 4 and an `OPEN batch still runs` line for an `ESCALATE` or `SHIP` line, exit 0 only when no batch runs; a fresh agent on the task drops its old `ESCALATE` line

- Unity daemons stay warm through compile errors: the editor starts with `-ignoreCompilerErrors`, so a compile error no longer ends it ("Aborting batchmode due to failure") and the next run no longer starts cold (first checks measured 576 to 595 s cold against 9 s warm); the daemon answers the `error CS` lines as `FAIL`. An editor that lives but never beats because the errors keep the daemon's own code from loading is ended after 60 quiet log seconds (`WARMD_STUCK_QUIET`)
- Every worktree of a split gets the base's `Library`, also a reused one or one that already exists: one `robocopy /MIR` (stale files of an older task go), never while an engine or a warmd run works there. Godot and web seeds no longer nest or start a program on a reused worktree

- Unity test runs are silent: the daemon mutes the editor at start and before every job and sets `AudioListener.volume = 0` when a test run enters PlayMode; `warmd test --sound` lets one run be heard
- Parallel PlayMode runs in different worktrees no longer collide on one network port: `test_port_env=<NAME>` gives every heavy run its own port, `test_port_base` (default 7930) plus its slot number, exported and set in the Unity daemon before each job

- `warmd ship` waits for CI with one `gh` call per poll and nothing else: `nap` instead of `sleep`, the job parser in builtins (was awk, tail, tr and two date per poll), polls every 30 s, every 60 s while the run is younger than half its median. `warmd watch` reads task names from the worktree's HEAD file, remembers normalised paths and stops asking whether an agent died at start once it worked: far fewer program starts per round (on a machine that keeps kernel memory per process start, process objects grew from 11k to 145k in 50 min)

- `warmd test --window` runs with graphics in batchmode (the `WARMD_GFX=1` path) with the hang detector on: a visible editor hung in a real run, `HUNG` never fired and the editor stayed open until the agent ended it. `WARMD_WINDOW_REAL=1` still opens the window; why the window editor's hang detector stays silent is open

- `warmd finish` refuses the base checkout (nothing recorded, nothing pushed, the base branch is never pushed by it) and points to the task worktree; a warmd run the agent left behind in its worktree is ended and its slot freed at once

### Added
- Prewarm at session start: the engine of every open task worktree starts in the background through the normal queue (slots, RAM wait), like after `warmd split`
- RAM short: before a run waits for RAM, the engine daemon of another worktree that is idle longest (alive, idle, no job, no run) is stopped; `ram_stop_idle=0` switches it off
- `package_dir` in warmd.conf: one player folder, refreshed after every finished batch (world step, then `warmd package`), overwritten in place; a player that runs from it is waited for

## [0.4.16] - 2026-11-06

### Changed
- Hook test: the pre-hook answers with PATH pointing nowhere, CHANGELOG
- Hooks start no program on the PreToolUse path: early dispatch, builtin JSON parsing

## [0.4.15] - 2026-11-06

### Changed
- Queued runs judge the places with builtins: no program start while every place is held

## [0.4.14] - 2026-11-06

### Fixed
- The PreToolUse hook starts no program for a Bash or Agent call (was about 20 starts, 45 process objects per call): `bin/warmd` dispatches `hook-pre`, `hook-subagent` and `hook-compact` before loading the other libs, the hook JSON is parsed with builtins, python's name is cached; SubagentStop and the minute context check also start fewer programs
- A queued run checks the places with builtins and starts no program while every place has a live owner (was about 25 starts per poll); queue polls every 5 s, the RAM wait every 15 s, `warmd watch` every 90 s (`WARMD_QUEUE_POLL`, `WARMD_RAM_POLL`, `WARMD_WATCH_POLL`)
- Wait loops (queue, RAM, daemon start, job result, watch) wait with `nap`, a read on a FIFO, instead of `sleep`: under Git Bash every sleep is a process start, and on machines that keep kernel memory per process start eight queued runs ate 40 GB in 40 minutes

## [0.4.13] - 2026-11-05

### Changed
- Pre-hook refuses find / on Windows: under Git Bash it walks /proc and leaks a handle per process until reboot

## [0.4.12] - 2026-11-05

### Changed
- Unity: the dialog watcher never holds the caller's output open
- Unity: a dialog at the window start is a blocked start, said on stderr and in result.txt
- Unity: warmd test --window runs tests in a visible editor on monitor 2
- Unity: a run goes on after a HUNG test, one list over all rounds

## [0.4.11] - 2026-11-05

### Changed
- A run that ends inside the engine start shows its output, the exit code and the log
- Test: world_outputs check ignores the earlier manifest change
- Automatic commits leave world_outputs out
- world_method: generated parts are built again before tests whenever their sources changed
- The automatic merge stops the engine its gate warmed in the base checkout
- Agent rules built in: instructions block kept current at session start, 2-line replies, background runs never escalate; AGENT lines carry the branch state and the stop-first rule; automatic commits leave engine leftovers out
- Stop hook records nothing while the agent's own run works or waits; a queued run is no failure; watch holds AGENT lines while the old agent still works
- Unity: daemon copy renewed before every run, idle daemon ends after 10 min, a hung test is named with the results before it, check never runs the whole PlayMode suite
- warmd leak measures kernel pool and free RAM per process start
- warmd status shows free RAM, Unity editors per project and the batch per branch; warmd stop ends other editors on this project
- warmd batch-resume rebuilds the batch marker from the open tasks, in the path form split writes
- warmd watch keeps a long batch alive: the marker is stale only when no agent worked for 240 minutes
- A stopped agent whose own warmd run goes on keeps its engine, and warmd watch keeps waiting for it
- Automatic merge goes into the base branch, in its own worktree, never into the shared checkout's branch

## [0.4.10] - 2026-11-05

### Changed
- Unity: a --play filter finds PlayMode tests, an empty suite no longer counts as a passed test

## [0.4.9] - 2026-11-05

### Changed
- batch_guard accepts both spellings of a worktree path in the batch marker

## [0.4.8] - 2026-11-05

### Changed
- Session start renews the batch marker when agents start again, a batch from before a reboot is no longer dropped as stale
- warmd <cmd> --help prints the command's usage instead of running it
- Seed links go into info/exclude and are renewed on reused worktrees

## [0.4.7] - 2026-11-04

### Changed
- watch counts a growing agent transcript as movement; a stopped agent's engine stops
- Unity tests run only the project's own assemblies (packages=1 runs embedded package tests too); InitTestScene leftovers are no change

## [0.4.6] - 2026-11-04

### Changed
- Hooks of an older warmd are renewed at session start
- Site redesign: real hero session from capture.sh, render.py fills the terminal from hero.log, all images rendered light and dark

## [0.4.5] - 2026-11-04

### Fixed
- A light suite (web, Python, shell) no longer waits half an hour behind the 15 percent RAM limit made for engines; it waits only below `ram_free_min_light` (default 3 percent).

## [0.4.4] - 2026-11-04

### Fixed
- `warmd watch` never wakes a task whose agent has stopped, until an Agent call starts the task again; `warmd split` drops finished, merged tasks from a running batch.
- The automatic merge after the last agent runs no local gate under `full=ci` and queues the `warmd ship` line instead; work already on origin is skipped even when the local base branch is stale.
- `warmd ship` returns the checkout to the branch it started on and fast-forwards it.

### Changed
- README and images: what runs by itself, measured numbers stated as scope, every image rebuilt by `docs/assets/render.py`.

## [0.4.3] - 2026-11-04

### Fixed
- The CI wait takes only the run of the pushed commit. Right after a push GitHub can still list the previous run of the branch, and that run must never count for the new head.

## [0.4.2] - 2026-11-04

### Added
- The CI self-test runs as parallel jobs over balanced suite groups, about 4.5 minutes instead of 15 to 17; a guard fails when a suite is in no group or in two.
- `full=ci` in `warmd.conf`: `warmd check` never runs the full suite locally and names the CI as the place.
- `warmd ci` and `warmd ship` print an ETA from the median of recent green runs and a SLOW line naming job and step once a run passes 1.5 times that median. The first red job ends the wait at once. The wait ends at twice the median run time (at least 5 min, 20 min without history); `WARMD_CI_MAX` sets the cap in minutes.
- `warmd watch` prints the CI ETA of an agent that waits on CI and counts that agent as working.
- `warmd ship --release vX.Y.Z` sets the version in `bin/warmd`, moves the Unreleased section of `CHANGELOG.md` to that version and fast-forwards the installed copy when it is a clean clone of the same repo. After a green merge it deletes the merged task branches on origin.
- `warmd status` and `warmd doctor` print one `UPDATE` line when the installed copy is behind its origin, read from local refs and refreshed by a background fetch at most every 6 hours.

### Fixed
- The CI wait polls instead of blocking on `gh run watch`; a job whose steps are all completed counts by its steps, GitHub kept one `in_progress` for 20 minutes after its last step.
- `warmd --version` printed 0.4.0 after release v0.4.1.
- `warmd ship` refuses a checkout with uncommitted changes up front and names the files; a merge git refuses without a conflict names git's reason.

## [0.4.1] - 2026-11-04

### Fixed
- Unity dotnet stage: package projects come from `Library/ScriptAssemblies`; restores run one after another.
- Handoff WIP commits take new files, an Agent call clears the task's pause marker, `warmd split` keeps space-separated files apart.
- `warmd board` lists every worktree, `warmd route` without a goal prints usage.

## [0.4.0] - 2026-11-03

Everything runs on its own after one install, Windows only.

### Added
- One automatic path from finished agents to main: integration branch, pull request, CI wait, merge on green, release (`warmd ship`, `warmd ci`). [#8](https://github.com/Vyrenbusiness-source/warmd-fewer-tokens-faster-agents/pull/8)
- A failed task moves to the next model tier by itself; an agent near its context limit hands over to a fresh one by itself. [#3](https://github.com/Vyrenbusiness-source/warmd-fewer-tokens-faster-agents/pull/3)
- Repo map: `warmd map` without a file prints the most referenced symbols, 248 instead of 567 tokens on the web sample, 177 instead of 445 on the Python sample.
- `warmd audit` names MCP servers that load all their tools up front and the setting that defers them.
- Measured A/B per area in [docs/ab.md](docs/ab.md): web and Python test runs read 68 to 98 % fewer tokens.
- One-line install in PowerShell; `warmd doctor` names every missing piece with its fix.
- `agents=` (parallel agent limit) and `floor=` (lowest model tier) in `warmd.conf`. [#9](https://github.com/Vyrenbusiness-source/warmd-fewer-tokens-faster-agents/pull/9)

### Changed
- `warmd check` runs the full suite when its last time beats build plus selection, so it is never slower than the plain run on small suites (1.2 s instead of 2 s or more in `tests/generic.sh`).
- `warmd split` appends to a running batch; a worktree whose branch is merged starts again from base. [#9](https://github.com/Vyrenbusiness-source/warmd-fewer-tokens-faster-agents/pull/9)
- A performance regression needs a second measurement before it fails. [#10](https://github.com/Vyrenbusiness-source/warmd-fewer-tokens-faster-agents/pull/10)

### Fixed
- `warmd watch` counts a CI wait as activity, skips paused tasks and reports agents that die at start once. [#6](https://github.com/Vyrenbusiness-source/warmd-fewer-tokens-faster-agents/pull/6)
- The SubagentStop hook job survives the end of `claude -p` on Windows; tokens are summed over all turns. [#4](https://github.com/Vyrenbusiness-source/warmd-fewer-tokens-faster-agents/pull/4)
- Worktree paths: Windows 8.3 short names and long names are compared in one form. [#10](https://github.com/Vyrenbusiness-source/warmd-fewer-tokens-faster-agents/pull/10)
- `warmd audit` reads a 600 KB `~/.claude.json` in 0.1 s instead of 103 s.

## [0.3.0] - 2026-11-03

Runs on its own after one install: hooks restore the batch after a restart, record real tokens, push and merge with rollback on red. [#2](https://github.com/Vyrenbusiness-source/warmd-fewer-tokens-faster-agents/pull/2)

### Added
- Stalled agents are caught within 5 minutes and woken (`warmd watch`).
- `warmd gain`: real tokens and dollars from the transcripts.
- `warmd init --slim`: subagent start tokens 15,334 to 3,762.
- `warmd layout`: layout problems as text lines instead of screenshots.
- Merge FAIL lines name the failing tests.

### Changed
- Faster code key: 662 ms to 115 ms at 40 changed files.
- Green-cache hits never wait for RAM or a queue slot.
- Windows only, CI on `windows-latest`. [#1](https://github.com/Vyrenbusiness-source/warmd-fewer-tokens-faster-agents/pull/1)

## [0.2.0] - 2026-11-02

Documentation and packaging release. No code changes in `bin`, `lib` or `adapters`.

### Changed
- README rewritten: install on the first screen, measured highlights, shorter body.
- Details moved to `docs/`: COMMANDS, AGENTS, MEASURED, FAQ.

### Added
- CONTRIBUTING.md and a bug report template.

## 0.1.0 - 2026-11-02

First public version, not tagged: headless daemon and CLI for Unity, Godot, web and any test suite, short test output, green cache, affected tests, worktrees per agent, merge gate, `warmd bench` and the public proof job.

[Unreleased]: https://github.com/Vyrenbusiness-source/warmd-fewer-tokens-faster-agents/compare/v0.4.16...HEAD
[0.4.16]: https://github.com/Vyrenbusiness-source/warmd-fewer-tokens-faster-agents/compare/v0.4.15...v0.4.16
[0.4.15]: https://github.com/Vyrenbusiness-source/warmd-fewer-tokens-faster-agents/compare/v0.4.14...v0.4.15
[0.4.14]: https://github.com/Vyrenbusiness-source/warmd-fewer-tokens-faster-agents/compare/v0.4.13...v0.4.14
[0.4.13]: https://github.com/Vyrenbusiness-source/warmd-fewer-tokens-faster-agents/compare/v0.4.12...v0.4.13
[0.4.12]: https://github.com/Vyrenbusiness-source/warmd-fewer-tokens-faster-agents/compare/v0.4.11...v0.4.12
[0.4.11]: https://github.com/Vyrenbusiness-source/warmd-fewer-tokens-faster-agents/compare/v0.4.10...v0.4.11
[0.4.10]: https://github.com/Vyrenbusiness-source/warmd-fewer-tokens-faster-agents/compare/v0.4.9...v0.4.10
[0.4.9]: https://github.com/Vyrenbusiness-source/warmd-fewer-tokens-faster-agents/compare/v0.4.8...v0.4.9
[0.4.8]: https://github.com/Vyrenbusiness-source/warmd-fewer-tokens-faster-agents/compare/v0.4.7...v0.4.8
[0.4.7]: https://github.com/Vyrenbusiness-source/warmd-fewer-tokens-faster-agents/compare/v0.4.6...v0.4.7
[0.4.6]: https://github.com/Vyrenbusiness-source/warmd-fewer-tokens-faster-agents/compare/v0.4.5...v0.4.6
[0.4.5]: https://github.com/Vyrenbusiness-source/warmd-fewer-tokens-faster-agents/compare/v0.4.4...v0.4.5
[0.4.4]: https://github.com/Vyrenbusiness-source/warmd-fewer-tokens-faster-agents/compare/v0.4.3...v0.4.4
[0.4.3]: https://github.com/Vyrenbusiness-source/warmd-fewer-tokens-faster-agents/compare/v0.4.2...v0.4.3
[0.4.2]: https://github.com/Vyrenbusiness-source/warmd-fewer-tokens-faster-agents/compare/v0.4.1...v0.4.2
[0.4.1]: https://github.com/Vyrenbusiness-source/warmd-fewer-tokens-faster-agents/compare/v0.4.0...v0.4.1
[0.4.0]: https://github.com/Vyrenbusiness-source/warmd-fewer-tokens-faster-agents/compare/v0.3.0...v0.4.0
[0.3.0]: https://github.com/Vyrenbusiness-source/warmd-fewer-tokens-faster-agents/compare/v0.2.0...v0.3.0
[0.2.0]: https://github.com/Vyrenbusiness-source/warmd-fewer-tokens-faster-agents/releases/tag/v0.2.0
