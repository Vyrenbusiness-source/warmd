# Changelog

All notable changes to warmd. Versions follow [Semantic Versioning](https://semver.org). Every release is a git tag; pin one with `WARMD_VERSION_TAG=<tag>` at install.

## [Unreleased]

## [0.6.4] - 2026-11-27

### Changed
- docs: README for v0.6.3, every command grouped with real images
- docs: Godot, agents and VS Code images from real warmd output

## [0.6.3] - 2026-11-27

### Changed
- docs: 1 pending command entries into docs/COMMANDS.md
- ship: own integration branch per call, merge only the PR head this call built
- fix(detect): keep the caller's path spelling, compare spelling-independent; ship refuses an existing release tag
- fix(detect): cd into git's spelling of the start folder, relative paths match PROJECT
- fix(detect): walk up in git's spelling of the root, 8.3 short paths compared unequal
- fix(detect): git root with warmd.conf stays the project, tooling folders never win

## [0.6.2] - 2026-11-27

### Fixed

- Godot: a missing `godot.path` cache file no longer prints `No such file or directory` on every run.

## [0.6.1] - 2026-11-27

### Fixed

- `warmd lint` (Godot): a `res://` path the code only asks about (`file_exists(...)`, `ResourceLoader.exists(...)`, `dir_exists_absolute(...)`, `globalize_path(...)`) is no longer a missing-path error, and a line with `# warmd: nolint` gives no `res://` finding (a test that passes a missing path on purpose).

## [0.6.0] - 2026-11-27

### Added
- `warmd lint [files...]`: Godot lints on changed `.gd`, `.tscn`, `.tres`. ERROR only when the headless engine (`godot/lint.gd`) or the disk proves it: unknown input action, `/root/` autoload, `tr` key, missing `res://` path, `res://` case differs from disk, collision layer outside 1-32. Everything else is WARN, capped by `WARMD_LINT_WARN` (10); `WARMD_LINT_NODES` (300), `WARMD_LINT_SUBRES_KB` (64). The engine starts once, only for open candidates. Exit 1 on errors. First step of `check` in Godot projects
- `warmd nightly [--schedule|--report] [--no-mutate]`: build and tests without cache in separate processes. `MISMATCH` (cache key wrong, confirmed by a second fresh run, exit 1) or `FLAKY`. Godot runners each in their own engine with `--verbose`; loads the static graph did not predict are `GAP` and become edges in `warmd-edges.tsv`. Then `warmd mutate` on the lines since the last night; 5-line report in `.warmd/nightly.txt`. `--schedule` prints the schtasks/cron one-liner and installs nothing
- `warmd mutate [--base REF] [--limit S] [--cmd C]`: one mutant per changed line (GDScript, sh, Python, JS/TS, never test files), each must turn a test red, else `SURVIVED file:line` and exit 1. Restored by trap even on kill, nothing committed. `mutate_cmd=`, `mutate_limit=` (900), `mutate=merge`, `warmd: nomutate`. Score in `warmd-quality.tsv`
- `warmd models [--list | --set role=model... | --set preset=quality|balanced|frugal | --set cost_limit_day=N]`: one model per role (`role_<role>=provider:model`, roles producer worker qa reviewer merge scout), WinForms window on Windows, text prompt elsewhere; `--list` shows success per model from the ledger. Reviewer and merge never below `floor`, worker and qa never cheap. The first interactive `init` asks once. New conf keys `time_budget_cheap/mid/top` (30, 60, 120 min) and `cost_limit_day` (enforced by `split`)
- `warmd sim [--seed N] [file.sim|dir|name...]`: Godot gameplay scenarios headless under a fixed tick (`--fixed-fps`, as fast as the engine can, no `--time-scale`), all in one engine start, one line each: `FAIL jump: peak 6 > 5 at frame 16 of 200 (seed 1)`. `tests/sim/<name>.sim` names `scene`, `seed`, `frames`, `isolate`, `metric <name> <max|min|last|avg|count|pct> <op> <limit> : <expression>` (sampled after every tick) and input lines (`press`/`release` an action, `mouse`, `down`/`up`). A scenario stops once its verdict is decided; a script error is red with file:line; a hang or crash is red, never cached, the rest goes on in a new engine (`WARMD_SIM_TIMEOUT`). Verdicts cached per scenario, seed and engine
- `warmd sim --record <scene> [--seed N] [--frames N] [--name x] [--headless]`: plays the scene in a window and writes every input change per physics tick to `tests/sim/<x>.sim`. Add a metric that is red for the bug and the replay is a red scenario a worker can fix
- `warmd state [--json]`: one line whether warmd works here (run, merge, CI wait, batch with its agents, last result). VS Code extension in `vscode/`: a status bar icon for idle, run, batch, CI and the last result; a click runs `warmd status`
- `warmd brake "<what>" [minutes] [fix idea]` and `warmd brakes [--days N]`: a machine-wide log of what slowed agents down, ranked by minutes lost. `BRAKE:` notes land there; `report` and `finish` show the brake minutes of the batch
- `warmd ship --release` runs `warmd package` first when `warmd.conf` has `export_smoke=1`; a red export smoke stops the release before the version moves. `warmd nightly` runs it too and its first line says `export OK` or `export RED`
- `warmd package` for Godot: export smoke. The first preset of `export_presets.cfg` is exported with `--export-release` and started headless for `export_frames` frames (120); a crash, a non-zero exit or a load error is red, and the same pack runs on the editor binary (`--main-pack`) so a script error is red too. Without export templates only `--export-pack` runs. `export_timeout=` (600 s), `export_run_timeout=` (120 s)
- `warmd shot [scene] --golden | --golden-update [--from image.png]`: Godot golden shot against this machine's reference in `.warmd/golden/<machine>/<scene>.png`, answered as `SAME` or `DIFF 3.2% in region x,y,w,h`; `golden_tolerance=` (0.5%). Only `--golden-update` writes a reference
- `warmd doctor` for Godot: `.uid` or `.import` files not versioned, `.godot/` not ignored, Godot version not pinned (`godot_version=` or `config/features`), engine not the pinned version
- Godot leaks: a test or runner that leaves orphan nodes is red with the count (debug builds); a runner in its own engine is red on `ObjectDB instance(s) leaked at exit`. `godot_allow_errors` applies
- Godot budgets at merge (or `WARMD_BUDGET=1`), one engine start: `budget_texture_px=`, `budget_texture_raw_px=`, `budget_<scene>=draw_calls=N,memory_mb=N,nodes=N` over `budget_frames` (60), `rendered_smoke=1` runs the main scene with graphics on every merge

### Changed
- Studio rules: two tasks on the same scene never run in parallel (the second gets `WAIT`; scenes from `res://` refs in `.tscn`, one level); every task file names a reviewer model other than the author's; `watch` escalates a task over its time budget (`OVER` plus `AGENT` line), `finish` reports `OVER`; routing only learns upward; a rolled-back merge writes a rule line into `.warmd/roles/<role>.md`; `split` prints a `FALLBACK` general-purpose line with inline rules when the `warmd-worker` agent file is missing; every agent records slowdowns as `BRAKE`
- docs: lint, nightly, mutate, models and the studio rules in docs/COMMANDS.md and the README

### Fixed
What slowed the agents of the v0.6 batch down, from the brake log:
- A task's docs entry goes to `docs/pending/<task>.md`, accepted by `tests/docs.sh`; `warmd ship` moves it into docs/COMMANDS.md. No task is red only because it may not edit COMMANDS.md
- `warmd finish` merges a clean `origin/<base>` and names a conflict at once; `warmd ci` opens a draft PR and fails fast on `CONFLICTING`, which runs no CI
- The hook denies `python` calls that hang on Windows (Store stub, empty stdin, `/tmp` in code); `warmd doctor` flags the stub
- CI caches the Godot download of the godot job
- Suites come from the files and the CI group `rest` runs the unnamed ones; `warmd ship` joins two branches' `ci.yml` suite steps. Two branches that each add a suite no longer conflict on one line
- `warmd split` never switches a worktree folder that holds another unfinished task's branch
- `warmd doctor` finds a Godot outside PATH and remembers it for `WARMD_GODOT`
- `cost_limit_day` is enforced: `warmd split` refuses new tasks once today's ledger estimate reached it (`WARMD_COST_LIMIT=off` lets one through)
- `mutate=merge` gates `warmd merge`, the affected-test selection reads the engine-proven edges of `warmd-edges.tsv`, and a restarted agent gets the model of `role_worker`/`role_scout`
- tests/brakes.sh measures `nap` in tenths of a second: whole-second ticks read two 1 s naps as 3 s on CI

## [0.5.1] - 2026-11-27

### Changed
- docs: Godot runners in one engine start and the changed scene/resource check
- godot: a one-shot engine that ends without a result shows its first error; guest reads stay typed under strict warnings
- godot: the build loads and instantiates changed .tscn and .tres, engine errors red with the file
- godot: all runners in one engine start, random order from a printed seed, # warmd: isolate

## [0.5.0] - 2026-11-27

### Added

- `warmd where <term>`: at most 5 lines `file:line what` from a symbol index (`.gd`, `.tscn`, input actions, autoloads, groups, C#, TS, Python), path words, `# warmd: feature=a,b` tags and notes with `file:line`, German and English synonyms included; then what changed since the agent last read (moved, changed, gone). The index is kept per file hash in the git dir; a note whose file changed is found again through its symbol or marked `STALE`. `warmd where --changed [ref]` lists all changes since the last read or a git state
- `warmd map <scene.tscn>`: scene outline with line numbers, node depth, type, script, instanced scenes, groups, `%unique` names and signals (`line signal from -> to method`), at most `WARMD_MAP_NODES` (80) nodes. The repo map ranks Godot scenes too
- `warmd peek <scene|res://|Name> [frames]` (default 10): plays a Godot scene headless at a fixed 60 fps and lists per node its type, position, hidden state, animation, script and exported vars; saves nothing. `WARMD_PEEK_NODES=80`, `WARMD_PEEK_TIMEOUT=120`
- Red cache: a red build or test is kept 2 hours (green 7 days) per code state and engine fingerprint. A red hit prints `RED cached, code unchanged: <line>. Change code first. Log: <path>`, keeps the exit code and answers at once without waiting for a slot or RAM. Timeouts, kills (exit 124 and up, also one killed test in a sh suite, now printed as `<test> killed (exit N)`), a missing engine, RAM waits and crashes are never kept. `WARMD_NOCACHE=1` bypasses both caches
- Godot: a green compile is cached like a test run. The key holds the code including `project.godot`, the engine fingerprint (engine version and binary, warmd version, `export_presets.cfg`, `WARMD_GODOT`, `WARMD_UNITY`, `WARMD_GFX`, `WARMD_WINDOW`, `WARMD_FULL`)
- `godot_allow_errors=<regex>` in `warmd.conf`, matched against `file:line message`: the only way to let a Godot script error pass, addons included
- `perf_scene` (Godot frame time of a scene, 5% limit at merge) is now documented in docs/COMMANDS.md
- Godot test: all runners (`tests/run_*.gd`) in one engine start, run one after another by `godot/daemon.gd`, each with its own verdict. Random order from a printed seed, `WARMD_SEED=<n>` replays it. `# warmd: isolate` in a runner's first 10 lines gives it an engine of its own, so does a runner that does not compile as a guest or quits through the real tree. A crash or hang names the runner and the rest get a new engine
- Godot build: every changed `.tscn` and `.tres` (against HEAD and the base branch) is loaded and instantiated headless, never saved. Engine errors are red as `file: message` (dead paths, missing scripts, broken inherited scenes, signals connected to missing methods); `godot_allow_errors` applies, the changed files are in the build's cache key
- `worktree_links` in `warmd.conf`: globs of git-ignored files (e.g. `tools/luau/*.exe`) that `warmd split` copies into every new or reused worktree (folders are linked). Default empty

### Fixed

- Godot build: a red compile names each error as `file:line message`. Strict GDScript warnings at level 2 (`debug/gdscript/warnings/untyped_declaration`, `unsafe_*`) are red, proven in CI with Godot 4.4.1
- Godot test: a test that stops on a script error or ran no assert is red, and so is a runner that prints `SCRIPT ERROR` and exits 0. Old copies of `addons/warmd/warmd_test.gd` count no asserts until `warmd init` runs again
- A killed or timed out single test in a sh suite (exit 124 and up) made the whole run red-cached; it is now named and never kept
- `warmd check` in a project without `test=` and without a Rust, Go, Python, .NET source change (e.g. Luau) said "no code changed against main" after the task was committed. It compares with the merge-base (committed and uncommitted work) and now says how many files changed and that no test ran, until `test=` is set
- `warmd split` sent every task to `warmd-worker`, whose tools are Bash, Read, Edit, Write, so a task that needs MCP tools (Roblox Studio, any `mcp__*`) failed silently. A goal that matches `mcp_words` (default `roblox studio|mcp`) now gets the new agent `warmd-worker-mcp`, which has no tools restriction. `warmd init` installs it; `escalate`, `handoff` and `route` keep it; `init --slim` does not add a tools line to it

## [0.4.52] - 2026-11-14

### Fixed

- `warmd merge` (and the automatic batch merge) no longer stops at a `project.godot` conflict that parallel branches cause by each adding an entry to the same one-line list (`locale/translations=PackedStringArray(...)`, `editor_plugins/enabled`, any `key=PackedStringArray("...")`). When every conflicted file is a `project.godot` and every differing line pair in its conflict blocks is the same list key on both sides, the lists are joined three-way (HEAD's order kept, the branch's new entries appended, an entry one side removed from the base stays out), the file is staged and the merge goes on with one `resolved project.godot list <key>: +n entries` line. CRLF and the diff3 conflict style are kept. Any other conflict still stops as before. Chosen over a git merge driver: that needs a `.gitattributes` entry in every project plus git config in every clone, replaces git's whole-file merge for all of `project.godot` and runs in every manual merge and rebase too

## [0.4.51] - 2026-11-14

### Fixed

- Godot: a new or moved `class_name` script is now found in every warmd worktree, so the class cache (`.godot/global_script_class_cache.cfg`) is renewed with one import before the compile. The search for `class_name` scripts skipped every file when a folder above the project starts with a dot (warmd's own `.warmd-worktrees`): `grep --exclude-dir` matched that folder in the project path. After `git merge main` brought new classes, `warmd check` reported them as `does not parse` until a manual `godot --import`. An unchanged cache still costs no import

## [0.4.50] - 2026-11-13

### Fixed

- Test selection: a new, untracked file that nothing references (agent settings such as `.claude/settings.local.json`, scratch images) no longer forces the whole suite. Tracked files and config-like names (`package.json`, `project.godot`, `tsconfig*.json`, ...) still select all. In a Godot project this cut a merge gate from all 78 runners to the affected ones.

## [0.4.49] - 2026-11-13

### Fixed
- An agent that ends its turn to wait for its own background command (a script started with `run_in_background`, no warmd run) no longer counts as stopped: nothing is recorded for that turn, so `warmd watch` does not report `OK batch ended` and the automatic merge does not take the half-done branch when the other tasks finish. The stop is recorded when the agent comes back and ends for real; a last message with the `DONE` line of `warmd finish` always counts as the end

## [0.4.48] - 2026-11-12

### Fixed
- `warmd split` never silently reuses the old branch of a finished task with the same name: a branch without commits missing from base is deleted or moved to the current base (also its reused worktree), a branch with unmerged commits or uncommitted changes is refused with a `GAP` line naming it, suggesting a new task name or `warmd drop <task> --delete`

## [0.4.47] - 2026-11-12

### Fixed
- `warmd merge` no longer takes edits made in the checkout while the gate runs into the merge commit: only what the gate wrote (`Assets/Editor/Warmd/`, `.uid`, `world_outputs`) is amended in, any other change stays uncommitted and is named in a `WARN` line

## [0.4.46] - 2026-11-12

### Fixed
- A failing Godot test runner now says why: `FAIL runner <file> (exit N)`, `(timeout after Ns)`, `(crashed: 0xC0000005 access violation, exit N)` for Windows crash codes and signals, and `(exit N after success output)` when it printed `ALL OK` / `0 fehlgeschlagen` / `FAILED: 0` before the non-zero exit
- A runner can set its own timeout with `# warmd: timeout=300` in its first 10 lines (default stays `WARMD_TIMEOUT`, 900s), so a realtime audio test is not killed while the machine is busy

## [0.4.45] - 2026-11-12

### Fixed
- `warmd check` in a Godot project with its own `tests/run_*.gd` runners (extends SceneTree) now treats them as tests: a changed source selects the runners that load it, a changed or new runner selects itself, and a runner with `class_name` before `extends` is found. A Godot project with no test of any kind prints `WARN no tests found ... Nothing ran` instead of a silent green

## [0.4.44] - 2026-11-12

### Fixed
- `warmd watch` no longer ends with an AGENT restart line for a task that already reported DONE with `warmd finish` (outcome ok) and only waits for the merge. `warmd finish` marks the task; its stop no longer escalates it, a queued AGENT line for it is dropped, and a new agent started on the task clears the mark

## [0.4.43] - 2026-11-12

### Added
- `warmd drop <task> [reason] [--delete] [--force]` cancels one task of a running batch: it leaves the batch (so `warmd watch` stops waking it, `warmd status`, the batch guard and the automatic merge ignore it, and the batch can end), frees its files, drops its queued ESCALATE or AGENT line and is recorded as dropped, not failed. The branch stays unless `--delete`, which removes the worktree and branch only when there are no commits outside the base and no uncommitted files, otherwise it refuses and changes nothing

## [0.4.42] - 2026-11-12

### Fixed
- `warmd merge` (and so the automatic merge at the end of a batch) no longer fails with "untracked working tree files would be overwritten" when Godot created a `.uid` or `.import` file in the base checkout that the incoming branch tracks: those import byproducts are removed first, Godot regenerates them. Any other untracked file that would be overwritten still stops the merge, and the FAIL line now lists the file names

## [0.4.41] - 2026-11-12

### Fixed
- `warmd handoff` and the `warmd finish` uncommitted count no longer count Godot import byproducts as work: a tracked `.uid` file Godot rewrote on import (and new `.uid`/`.import` files) does not trigger "commit your work first". `warmd watch`, the agent restart line ("N uncommitted"), `warmd status` and the merge gate ("uncommitted changes") ignore them too. A real change to any other tracked file still counts everywhere

## [0.4.40] - 2026-11-11

### Fixed
- The hook no longer refuses a project script run (`bash tools/x.sh`) with "a Godot run with a window plays sound" when every Godot call in that script names `--audio-driver`. The script is read (also after `cd dir &&`); a script without a Godot call is not judged at all. A script with a Godot call without a driver, a direct Godot call without a driver and an unreadable script are still refused. A `grep`, `tasklist`, `ls` or `echo` that only names godot as a pattern or a file (`tasklist | grep -i godot`) is no Godot run either; only a real call of the Godot executable counts

## [0.4.39] - 2026-11-11

### Fixed
- The hook no longer refuses a project script run (`bash tools/x.sh`) with "a Godot run with a window plays sound" when every Godot call in that script names `--audio-driver`. The script is read (also after `cd dir &&`); a script without a Godot call is not judged at all. A script with a Godot call without a driver, a direct Godot call without a driver and an unreadable script are still refused
- Godot: a branch that moves a `class_name` script no longer turns the build, `warmd check` and the merge gate red with `Class "X" hides a global script class`. The class cache in `.godot/global_script_class_cache.cfg` still named the old path, so the compile saw the class twice. Before every compile and test run warmd now compares the cache with the scripts on disk (a cached path that is gone, a `class_name` script missing or at another path; `.gdignore` and hidden folders are skipped) and renews it with one `--import`. A "hides a global script class" error the check did not foresee is retried once after an import and counts as red only when it stays; a difference an import does not clear (two scripts with one `class_name`) is noted and does not cost an import on every build

## [0.4.38] - 2026-11-08

### Fixed
- The automatic merge no longer takes work away from the base checkout. A red gate rolled back with `git reset --hard` to the HEAD from before the merge, so a commit made (and pushed) during the gate and every uncommitted edit were gone, and the base was left behind its upstream. The rollback now goes back only to the HEAD this merge started from, only while HEAD is still the merge's own commit, never behind the upstream, and with `reset --keep`, so edits in other files stay; otherwise nothing is touched, the merge says "not rolled back" and the batch stays open without merging more on top. A commit made during a green gate is no longer amended
- The automatic merge refuses a base checkout with uncommitted changes (or an open merge) before it merges anything and leaves it untouched; branches already in the base branch are skipped with "nothing new" before any checkout is made or touched, also in `warmd merge`

## [0.4.37] - 2026-11-08

### Fixed
- Godot: a project runner (`tests/run_*.gd`) that does not parse or compile is red, also when Godot ends with exit 0 and the script still prints its ok line (`Parse Error`, `Compile Error`, `Failed to load script` in its output); before, `warmd test` and `warmd check` reported green and cached it
- A reused worktree whose finished line still names the branch of its previous task no longer counts as finished: the automatic merge does not end the batch while its new task runs, `warmd split` keeps it in the batch marker and drops the stale line; before, its agent got "a batch runs, this is the shared checkout" refusals
- `warmd batch-resume` takes only the tasks of the latest batch (named in its shared brief, a task file from after the batch start, or an agent transcript that moved in the last 120 minutes); before, every old worktree with unmerged commits came back as open

## [0.4.36] - 2026-11-08

### Fixed
- `warmd split`: a finished task (its agent stopped) no longer owns its files; a paused task blocked every new task on the same files with "already owned in this batch"

## [0.4.35] - 2026-11-08

### Fixed
- A new batch (`warmd split` without a running batch) drops the queued lines of the batch before it: an old `ESCALATE` line of a task merged long ago stopped the first `warmd watch` of the next batch with exit 4

## [0.4.34] - 2026-11-07

### Fixed
- A finished mark names the branch its task held: a worktree that a later split gave a new task no longer counts as finished from its old task's mark, so a split cannot prune it and hand it to a second agent while the first one works there

## [0.4.33] - 2026-11-07

### Added
- A Godot run with a window needs `--audio-driver` (`Dummy` for tests), or it is denied with the fix: test windows played the game's sound on the user's speakers

## [0.4.32] - 2026-11-07

### Fixed
- `warmd finish` marks its task finished in the batch, also when the coordinator stopped the agent and no stop hook ran; before, the merged task kept owning its files and the next split failed with "already owned in this batch"

## [0.4.31] - 2026-11-07

### Added
- Godot: worktrees share the import cache. Before an `--import` (by an agent or by warmd) every import another checkout already made with the same `.import` settings and the same source md5 is copied instead of compressed again; 8192x4096 BPTC textures took minutes per worktree after every merge

## [0.4.30] - 2026-11-07

### Added
- A Godot run with a window and no time limit (`timeout N`, `--quit-after`, `--quit`) is denied with the fix in the reason: agents left test windows open when a scene never quit

## [0.4.29] - 2026-11-07

### Added
- Repeat guard: a heavy run (engine, `warmd test/check/build/shot`, generators, `--bench`/`--shot`) with the same command on the same tree state runs at most 3 times (`WARMD_REPEAT_MAX`); the next one is denied with the reason. Agents ran the same check up to ten times without changing a file

## [0.4.28] - 2026-11-07

### Fixed
- Session start in a batch names the task a reused worktree holds now (its `warmd/<task>` branch), not an older task that once ran there; after a restart the AGENT lines read the wrong task files

## [0.4.27] - 2026-11-07

### Fixed
- `warmd split` appending to a batch frees finished, merged tasks even when Godot left untracked `.uid`/`.import` files in their worktree; before, their files stayed owned and the new task failed with "already owned in this batch"

## [0.4.26] - 2026-11-06

### Fixed
- `warmd split`: a goal may contain `|` (for example `|offset| <= 49`): the name is the first field, files the last, the done check the one before; the task file no longer breaks apart

## [0.4.25] - 2026-11-06

### Fixed
- Heavy runs wait for free RAM before they take a slot: a run waiting for RAM no longer holds a slot and stalls every other agent behind it

## [0.4.24] - 2026-11-06

### Fixed
- `warmd perf` no longer fails an unchanged web app on a busy machine: the load time is the median of at least 5 loads after a discarded warm-up, and a reference page measured in the same browser takes out what a slower machine adds. Old baselines without the reference compare as before
- The docs test fails when the version in `.claude-plugin/plugin.json` differs from `bin/warmd`; `warmd ship --release` moves both
- `warmd test` on a `node --test` project names the failing test, its file:line, the message and actual/expected (spec and TAP reporter), instead of a keyword filter that dropped the test name and the actual value

## [0.4.23] - 2026-11-06

### Fixed
- `warmd split`: only tasks still in the batch own files; a merged or pruned task no longer blocks a new task on the same files with "already owned in this batch"
- `warmd split` no longer hands one worktree to two agents: a reused worktree forgets the "finished" mark of its previous task, so a later split in the same batch does not prune it as free

## [0.4.22] - 2026-11-06

### Added
- Claude Code plugin: `/plugin marketplace add Vyrenbusiness-source/warmd`, then `/plugin install warmd@warmd`. It brings the hooks, the agents as `warmd:warmd-worker`, `warmd:warmd-scout` and `warmd:warmd-merge`, `warmd` on the agent's PATH and the instructions as session context. Its hooks step aside in a project that has `warmd init` hooks. CI checks it with `claude plugin validate`

### Changed
- The repo is now `Vyrenbusiness-source/warmd`, the short name the command already has. Old URLs, clones and the old install lines redirect
- `warmd ship --release` writes the release notes from the version's CHANGELOG section plus a compare link, not from raw commit subjects; without a section it falls back to the commit subjects, minus release and WIP commits

## [0.4.21] - 2026-11-06

### Fixed
- `warmd ship` takes a fresh integration branch when another worktree already holds `warmd-ship`, instead of failing with "cannot branch from origin/main"
- Godot: `warmd build` skips folders holding `.gdignore`, as Godot does, so raw asset packs with their own scripts no longer turn the build red

## [0.4.20] - 2026-11-06

### Fixed
- Godot: `warmd` finds an engine binary kept next to `project.godot` (`Godot*.exe`, `Godot*.x86_64`), also from a worktree via the main checkout, so `WARMD_GODOT` is no longer needed there
- Godot: a project without WarmdTest, GUT or gdUnit4 runs its own SceneTree runners (`tests/run_*.gd`, exit code counts) instead of reporting "0 tests ran"

## [0.4.19] - 2026-11-06

### Changed
- The `warmd-merge` agent merges all finished branches in one `warmd merge a b c` call instead of one at a time

### Added
- `warmd merge a b c` merges several branches one after the other and runs one gate and one player build for all of them, not one per branch; red rolls all of them back, a conflict stops at its branch and `warmd merge --continue` goes on with the rest. `--no-gate` for an integration a human released. The automatic merge at the end of a batch merges all green branches in one call and goes one by one only when that is red
- Every `warmd merge` with `package_dir` starts `warmd package` in the background (one at a time), so the player always is the merged base, also for merges an agent runs by hand. Without `package_dir` merge and doctor say so instead of building nothing in silence
- Disk: `split` copies an engine cache (a Unity `Library` is often 4 to 7 GB) only with room for it plus `disk_min_mb` (default 4096) and answers `WAIT` otherwise; heavy runs first free finished caches and are refused below `disk_min_mb`; every merge and the end of every batch free the caches of finished worktrees (HEAD in the base, clean, not in the batch, no engine). `warmd disk` shows it, `--free` frees now, doctor reports low space. Three new worktrees filled a disk and merges died with "unable to write file"

### Changed
- `warmd watch` and `split` read the process list once per 20 s and match worktree paths as plain text: one PowerShell per round instead of two per idle worktree (`WARMD_PROCS_TTL`). The old check escaped the path into a pattern that never matched

## [0.4.18] - 2026-11-06

### Fixed
- An agent's shell goes back to the main checkout after every Bash call when its worktree lies outside the session's folders, so `warmd finish` and `handoff` acted on the main checkout. The task file now says to start every Bash call with `cd "<worktree>" &&`, and `finish` and `handoff` refuse the shared checkout while a batch runs, like test, check and build; a worktree of an older batch still ends and hands off its own task

## [0.4.17] - 2026-11-06

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
- One automatic path from finished agents to main: integration branch, pull request, CI wait, merge on green, release (`warmd ship`, `warmd ci`). [#8](https://github.com/Vyrenbusiness-source/warmd/pull/8)
- A failed task moves to the next model tier by itself; an agent near its context limit hands over to a fresh one by itself. [#3](https://github.com/Vyrenbusiness-source/warmd/pull/3)
- Repo map: `warmd map` without a file prints the most referenced symbols, 248 instead of 567 tokens on the web sample, 177 instead of 445 on the Python sample.
- `warmd audit` names MCP servers that load all their tools up front and the setting that defers them.
- Measured A/B per area in [docs/ab.md](docs/ab.md): web and Python test runs read 68 to 98 % fewer tokens.
- One-line install in PowerShell; `warmd doctor` names every missing piece with its fix.
- `agents=` (parallel agent limit) and `floor=` (lowest model tier) in `warmd.conf`. [#9](https://github.com/Vyrenbusiness-source/warmd/pull/9)

### Changed
- `warmd check` runs the full suite when its last time beats build plus selection, so it is never slower than the plain run on small suites (1.2 s instead of 2 s or more in `tests/generic.sh`).
- `warmd split` appends to a running batch; a worktree whose branch is merged starts again from base. [#9](https://github.com/Vyrenbusiness-source/warmd/pull/9)
- A performance regression needs a second measurement before it fails. [#10](https://github.com/Vyrenbusiness-source/warmd/pull/10)

### Fixed
- `warmd watch` counts a CI wait as activity, skips paused tasks and reports agents that die at start once. [#6](https://github.com/Vyrenbusiness-source/warmd/pull/6)
- The SubagentStop hook job survives the end of `claude -p` on Windows; tokens are summed over all turns. [#4](https://github.com/Vyrenbusiness-source/warmd/pull/4)
- Worktree paths: Windows 8.3 short names and long names are compared in one form. [#10](https://github.com/Vyrenbusiness-source/warmd/pull/10)
- `warmd audit` reads a 600 KB `~/.claude.json` in 0.1 s instead of 103 s.

## [0.3.0] - 2026-11-03

Runs on its own after one install: hooks restore the batch after a restart, record real tokens, push and merge with rollback on red. [#2](https://github.com/Vyrenbusiness-source/warmd/pull/2)

### Added
- Stalled agents are caught within 5 minutes and woken (`warmd watch`).
- `warmd gain`: real tokens and dollars from the transcripts.
- `warmd init --slim`: subagent start tokens 15,334 to 3,762.
- `warmd layout`: layout problems as text lines instead of screenshots.
- Merge FAIL lines name the failing tests.

### Changed
- Faster code key: 662 ms to 115 ms at 40 changed files.
- Green-cache hits never wait for RAM or a queue slot.
- Windows only, CI on `windows-latest`. [#1](https://github.com/Vyrenbusiness-source/warmd/pull/1)

## [0.2.0] - 2026-11-02

Documentation and packaging release. No code changes in `bin`, `lib` or `adapters`.

### Changed
- README rewritten: install on the first screen, measured highlights, shorter body.
- Details moved to `docs/`: COMMANDS, AGENTS, MEASURED, FAQ.

### Added
- CONTRIBUTING.md and a bug report template.

## 0.1.0 - 2026-11-02

First public version, not tagged: headless daemon and CLI for Unity, Godot, web and any test suite, short test output, green cache, affected tests, worktrees per agent, merge gate, `warmd bench` and the public proof job.

[Unreleased]: https://github.com/Vyrenbusiness-source/warmd/compare/v0.6.4...HEAD
[0.6.4]: https://github.com/Vyrenbusiness-source/warmd/compare/v0.6.3...v0.6.4
[0.6.3]: https://github.com/Vyrenbusiness-source/warmd/compare/v0.6.2...v0.6.3
[0.6.2]: https://github.com/Vyrenbusiness-source/warmd/compare/v0.6.1...v0.6.2
[0.6.1]: https://github.com/Vyrenbusiness-source/warmd/compare/v0.6.0...v0.6.1
[0.6.0]: https://github.com/Vyrenbusiness-source/warmd/compare/v0.5.1...v0.6.0
[0.5.1]: https://github.com/Vyrenbusiness-source/warmd/compare/v0.5.0...v0.5.1
[0.5.0]: https://github.com/Vyrenbusiness-source/warmd/compare/v0.4.52...v0.5.0
[0.4.52]: https://github.com/Vyrenbusiness-source/warmd/compare/v0.4.51...v0.4.52
[0.4.51]: https://github.com/Vyrenbusiness-source/warmd/compare/v0.4.50...v0.4.51
[0.4.50]: https://github.com/Vyrenbusiness-source/warmd/compare/v0.4.49...v0.4.50
[0.4.49]: https://github.com/Vyrenbusiness-source/warmd/compare/v0.4.45...v0.4.49
[0.4.45]: https://github.com/Vyrenbusiness-source/warmd/compare/v0.4.44...v0.4.45
[0.4.44]: https://github.com/Vyrenbusiness-source/warmd/compare/v0.4.43...v0.4.44
[0.4.43]: https://github.com/Vyrenbusiness-source/warmd/compare/v0.4.42...v0.4.43
[0.4.42]: https://github.com/Vyrenbusiness-source/warmd/compare/v0.4.41...v0.4.42
[0.4.41]: https://github.com/Vyrenbusiness-source/warmd/compare/v0.4.40...v0.4.41
[0.4.40]: https://github.com/Vyrenbusiness-source/warmd/compare/v0.4.39...v0.4.40
[0.4.39]: https://github.com/Vyrenbusiness-source/warmd/compare/v0.4.38...v0.4.39
[0.4.38]: https://github.com/Vyrenbusiness-source/warmd/compare/v0.4.37...v0.4.38
[0.4.37]: https://github.com/Vyrenbusiness-source/warmd/compare/v0.4.36...v0.4.37
[0.4.36]: https://github.com/Vyrenbusiness-source/warmd/compare/v0.4.35...v0.4.36
[0.4.35]: https://github.com/Vyrenbusiness-source/warmd/compare/v0.4.34...v0.4.35
[0.4.34]: https://github.com/Vyrenbusiness-source/warmd/compare/v0.4.33...v0.4.34
[0.4.33]: https://github.com/Vyrenbusiness-source/warmd/compare/v0.4.32...v0.4.33
[0.4.32]: https://github.com/Vyrenbusiness-source/warmd/compare/v0.4.31...v0.4.32
[0.4.31]: https://github.com/Vyrenbusiness-source/warmd/compare/v0.4.30...v0.4.31
[0.4.30]: https://github.com/Vyrenbusiness-source/warmd/compare/v0.4.29...v0.4.30
[0.4.29]: https://github.com/Vyrenbusiness-source/warmd/compare/v0.4.28...v0.4.29
[0.4.28]: https://github.com/Vyrenbusiness-source/warmd/compare/v0.4.27...v0.4.28
[0.4.27]: https://github.com/Vyrenbusiness-source/warmd/compare/v0.4.26...v0.4.27
[0.4.26]: https://github.com/Vyrenbusiness-source/warmd/compare/v0.4.25...v0.4.26
[0.4.25]: https://github.com/Vyrenbusiness-source/warmd/compare/v0.4.24...v0.4.25
[0.4.24]: https://github.com/Vyrenbusiness-source/warmd/compare/v0.4.23...v0.4.24
[0.4.23]: https://github.com/Vyrenbusiness-source/warmd/compare/v0.4.22...v0.4.23
[0.4.22]: https://github.com/Vyrenbusiness-source/warmd/compare/v0.4.21...v0.4.22
[0.4.21]: https://github.com/Vyrenbusiness-source/warmd/compare/v0.4.20...v0.4.21
[0.4.20]: https://github.com/Vyrenbusiness-source/warmd/compare/v0.4.19...v0.4.20
[0.4.19]: https://github.com/Vyrenbusiness-source/warmd/compare/v0.4.18...v0.4.19
[0.4.18]: https://github.com/Vyrenbusiness-source/warmd/compare/v0.4.17...v0.4.18
[0.4.17]: https://github.com/Vyrenbusiness-source/warmd/compare/v0.4.16...v0.4.17
[0.4.16]: https://github.com/Vyrenbusiness-source/warmd/compare/v0.4.15...v0.4.16
[0.4.15]: https://github.com/Vyrenbusiness-source/warmd/compare/v0.4.14...v0.4.15
[0.4.14]: https://github.com/Vyrenbusiness-source/warmd/compare/v0.4.13...v0.4.14
[0.4.13]: https://github.com/Vyrenbusiness-source/warmd/compare/v0.4.12...v0.4.13
[0.4.12]: https://github.com/Vyrenbusiness-source/warmd/compare/v0.4.11...v0.4.12
[0.4.11]: https://github.com/Vyrenbusiness-source/warmd/compare/v0.4.10...v0.4.11
[0.4.10]: https://github.com/Vyrenbusiness-source/warmd/compare/v0.4.9...v0.4.10
[0.4.9]: https://github.com/Vyrenbusiness-source/warmd/compare/v0.4.8...v0.4.9
[0.4.8]: https://github.com/Vyrenbusiness-source/warmd/compare/v0.4.7...v0.4.8
[0.4.7]: https://github.com/Vyrenbusiness-source/warmd/compare/v0.4.6...v0.4.7
[0.4.6]: https://github.com/Vyrenbusiness-source/warmd/compare/v0.4.5...v0.4.6
[0.4.5]: https://github.com/Vyrenbusiness-source/warmd/compare/v0.4.4...v0.4.5
[0.4.4]: https://github.com/Vyrenbusiness-source/warmd/compare/v0.4.3...v0.4.4
[0.4.3]: https://github.com/Vyrenbusiness-source/warmd/compare/v0.4.2...v0.4.3
[0.4.2]: https://github.com/Vyrenbusiness-source/warmd/compare/v0.4.1...v0.4.2
[0.4.1]: https://github.com/Vyrenbusiness-source/warmd/compare/v0.4.0...v0.4.1
[0.4.0]: https://github.com/Vyrenbusiness-source/warmd/compare/v0.3.0...v0.4.0
[0.3.0]: https://github.com/Vyrenbusiness-source/warmd/compare/v0.2.0...v0.3.0
[0.2.0]: https://github.com/Vyrenbusiness-source/warmd/releases/tag/v0.2.0
