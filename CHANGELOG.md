# Changelog

All notable changes to warmd. Versions follow [Semantic Versioning](https://semver.org). Every release is a git tag; pin one with `WARMD_VERSION_TAG=<tag>` at install.

## [Unreleased]

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

[Unreleased]: https://github.com/Vyrenbusiness-source/warmd-fewer-tokens-faster-agents/compare/v0.4.6...HEAD
[0.4.6]: https://github.com/Vyrenbusiness-source/warmd-fewer-tokens-faster-agents/compare/v0.4.5...v0.4.6
[0.4.5]: https://github.com/Vyrenbusiness-source/warmd-fewer-tokens-faster-agents/compare/v0.4.4...v0.4.5
[0.4.4]: https://github.com/Vyrenbusiness-source/warmd-fewer-tokens-faster-agents/compare/v0.4.3...v0.4.4
[0.4.3]: https://github.com/Vyrenbusiness-source/warmd-fewer-tokens-faster-agents/compare/v0.4.2...v0.4.3
[0.4.2]: https://github.com/Vyrenbusiness-source/warmd-fewer-tokens-faster-agents/compare/v0.4.1...v0.4.2
[0.4.1]: https://github.com/Vyrenbusiness-source/warmd-fewer-tokens-faster-agents/compare/v0.4.0...v0.4.1
[0.4.0]: https://github.com/Vyrenbusiness-source/warmd-fewer-tokens-faster-agents/compare/v0.3.0...v0.4.0
[0.3.0]: https://github.com/Vyrenbusiness-source/warmd-fewer-tokens-faster-agents/compare/v0.2.0...v0.3.0
[0.2.0]: https://github.com/Vyrenbusiness-source/warmd-fewer-tokens-faster-agents/releases/tag/v0.2.0
