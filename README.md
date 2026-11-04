<div align="center">

<img src="docs/assets/social.png" alt="warmd: your coding agent should not wait for the engine. 95% faster Unity test class, 98% fewer tokens per green run, 26% fewer tokens per agent fix" width="820">

# warmd

**Install once. warmd keeps the engine warm, answers unchanged code from cache, shows your coding agent only the error, routes each task to the cheapest model that fits and merges the results with rollback on red. All by itself.**

For Windows, in Git Bash or PowerShell. [Install in one line](#install).

[![Star on GitHub](https://img.shields.io/github/stars/Vyrenbusiness-source/warmd-fewer-tokens-faster-agents?style=social&label=Star)](https://github.com/Vyrenbusiness-source/warmd-fewer-tokens-faster-agents)
[![CI](https://github.com/Vyrenbusiness-source/warmd-fewer-tokens-faster-agents/actions/workflows/ci.yml/badge.svg)](https://github.com/Vyrenbusiness-source/warmd-fewer-tokens-faster-agents/actions/workflows/ci.yml)
[![Release](https://img.shields.io/github/v/release/Vyrenbusiness-source/warmd-fewer-tokens-faster-agents)](https://github.com/Vyrenbusiness-source/warmd-fewer-tokens-faster-agents/releases/latest)
[![License: MIT](https://img.shields.io/badge/license-MIT-green)](LICENSE)
![Windows](https://img.shields.io/badge/platform-Windows-0078d4)
![Unity](https://img.shields.io/badge/Unity-6-black?logo=unity)
![Godot](https://img.shields.io/badge/Godot-4-478cbf?logo=godotengine&logoColor=white)
![Agents](https://img.shields.io/badge/agents-Claude%20Code%20%7C%20Codex%20%7C%20Cursor-ff7a30)

<img src="docs/assets/demo.png" alt="Real session: warmd test fails with the error lines only, a one-line fix, the test passes, the repeat run is cached in 0.424 s" width="720">


<sub>Real session on Windows 10 in Git Bash, output unchanged, on a small Node project with one failing test.</sub>

<table>
<tr>
<td align="center" width="50%"><h3>95% faster</h3>one Unity test class<br><sub>56 s → 3 s, large HDRP project</sub></td>
<td align="center" width="50%"><h3>98% fewer tokens</h3>per green test run<br><sub>web 289 → 6, Python 309 → 6</sub></td>
</tr>
<tr>
<td align="center" width="50%"><h3>0.43 s</h3>repeat run, code unchanged<br><sub>green results are cached</sub></td>
<td align="center" width="50%"><h3>26% fewer tokens</h3>agent fixing a web bug<br><sub>5 runs per arm, <a href="docs/ab.md">docs/ab.md</a></sub></td>
</tr>
</table>

**Saves you tokens or time? [Star it](https://github.com/Vyrenbusiness-source/warmd-fewer-tokens-faster-agents).** One click, and others find it.

</div>

## What it brings

Real runs on Windows 10, nothing estimated. Method and raw tables: [docs/ab.md](docs/ab.md) for web and Python, [MEASURED.md](docs/MEASURED.md) for games.

### Websites

Sample project: Vite and Vitest, 6 test files, 17 tests.

- **Test output.** A red run costs 136 tokens instead of 714, a green run 6 instead of 289.
- **Repeat run.** 0.43 s instead of 1.7 s while the code is unchanged.
- **Agent fixing one bug.** 26% fewer tokens and 27% lower cost per run, about 2 turns fewer. 5 of 5 fixed in both arms.
- **Small suite, direct run.** After a one-file change warmd selects 18 to 59% of the tests. This whole suite finishes in under 2 s, faster than build plus selection, so `warmd check` measures both paths and runs the full suite directly.
- **Agent time.** 23.1 s with warmd, 22.2 s without, equal within the spread. On this project the gain is tokens and cost.

### Programming

Sample project: Python and pytest, 5 test files, 13 tests.

- **Test output.** A red run costs 153 tokens instead of 479, a green run 6 instead of 309.
- **Repeat run.** 0.43 s instead of 0.9 s while the code is unchanged.
- **Agent fixing one bug.** 7% fewer tokens, 11% lower cost and one turn fewer per run, 5 of 5 fixed in both arms. The gap is smaller than on web and within one standard deviation.
- **Small suite, direct run.** warmd selects 31% of the tests after a change. 13 tests finish in 0.1 s, faster than build plus selection, so `warmd check` runs the full suite directly.
- **Agent time.** 20.5 s with warmd, 19.4 s without, equal within the spread.

### Games

Unity 6000.4 on a large HDRP project, and Godot 4.7. Here the engine start is most of the wait, and that is where warmd saves the most time.

- **One Unity test class.** 3 s instead of 56 s.
- **Full PlayMode test.** 26 s instead of 54 s, 8 s with time lapse.
- **Repeat run.** 0.4 s instead of 3 s while the code is unchanged.
- **Test output.** A green Unity run is 41 bytes instead of a 33,323 byte log.
- **Godot.** One test in 0.9 s. Godot starts in about 170 ms, so warmd runs it fresh and keeps no daemon.

The agent A/B covers web and Python; the game numbers are per run.

![Bars: Unity test class 56 s to 3 s, PlayMode 54 s to 26 s and 8 s with time lapse, repeat run 3 s to 0.4 s](docs/assets/speed.png)

## What happens by itself

After `warmd init` your agent calls warmd through its instructions and hooks. Nobody types a warmd command. Each line names what it saves and how.

<img src="docs/assets/features.png" alt="Feature grid: tests and builds, agents, merge, CI and machine" width="820">

### Tests and builds

- **Warm engine.** The Unity editor runs headless and stays open, the web dev server too, so no run pays the engine start again. A daemon that hangs is restarted and the job repeats once.
- **Error-only output.** A green run is one line. A red run is the failing test, `file:line`, expected and actual. The full log stays on disk.
- **Green cache.** A passing result stays valid until the code changes, across all worktrees, so a repeat run answers in about 0.43 s. Red is never cached.
- **Affected tests.** A real import graph for JS and TS, Python, C# with asmdefs and GDScript selects every test that reaches the changed files. `warmd check` measures the full run and the selective run and takes the faster one, so a small suite runs whole.
- **Time lapse.** `--speed N` raises `Time.timeScale` for Unity tests that wait on game time, fixed steps keep their size: a 54 s PlayMode test runs in 8 s.
- **Screenshots and layout as text.** Desktop and 390 px phone captures sized for an agent, and layout problems (overflow, clipped text, overlapping boxes) as text lines, with the Chrome or Edge you already have.
- **Performance baseline.** Web build size and load time, Unity and Godot frame time or your own command against a stored baseline. A slowdown above 5% is refused.

![Bars: Unity green run 33,323 to 41 bytes, web red run 714 to 136 tokens, Python red run 479 to 153 tokens](docs/assets/tokens.png)

### Agents

- **Cheapest fitting model.** A reading task starts on the cheap tier, an edit on the mid tier, hard areas and paths you name on the top tier. Tiers are the aliases `haiku`, `sonnet` and `opus`, so a new model release needs no change.
- **Escalation.** After a real failure the same task moves to the next tier with the earlier commits as context. An area that needed it twice starts one tier higher next time.
- **Handoff.** Past 70% of its token budget, after 60 tool calls or at a compaction, an agent commits, writes its state and a fresh agent continues. A long context costs more per turn than a short note.
- **Wake on stall.** A watch runs during every batch. An agent whose worktree has not moved for 5 minutes is reported with its next step, and a fresh batch never alarms in its first minutes.
- **Shared brief.** All agents of a batch read one short file: who owns which file and what the others found. One agent finds a fact, no other searches for it again.
- **Repo map and outlines.** The most referenced symbols of the project in one short map, 248 instead of 567 tokens on the web sample, 177 instead of 445 on Python. A large file comes as an outline with line numbers, then only the needed lines.
- **Lean agent start.** Each subagent starts with only the tools it needs: 3,762 start tokens instead of 15,334. `warmd audit` names every MCP server that loads all its tools up front and the setting that defers them.
- **Real cost per task.** Tokens are read from the agent transcripts and recorded per task, tier and outcome, including what escalation cost. No estimates, nothing leaves the machine.

![Flow: a task list is split into worktrees for Haiku, Sonnet and Opus, merged with rollback; shared brief and escalation below](docs/assets/flow.png)

### Merge, CI and your machine

- **Resumes itself.** A session that restarts or compacts picks up its task or batch where it was.
- **Merge with rollback.** When the last agent of a batch stops, its pushed branches merge one at a time in the background and the project's checks run on each result. Red is rolled back, the base stays green.
- **One PR, CI that reports itself.** With a GitHub CI the branches go through one pull request. The wait prints an ETA from the median of recent runs, a `SLOW` line past 1.5 times that median, ends at the first red job with the failing test names, and merges on green. A release also updates your installed copy when it is a clean clone.
- **Full suite on CI.** With `full=ci` a bash project's full self-test runs on CI only, and the local check runs the per-file tests.
- **RAM wait.** A heavy start waits in the queue while less than 15% of RAM is free, so parallel agents never freeze the machine.

The syntax of every step is in the [reference](docs/COMMANDS.md), for when you want to run one by hand.

## Install

In Git Bash:

```bash
curl -fsSL https://raw.githubusercontent.com/Vyrenbusiness-source/warmd-fewer-tokens-faster-agents/main/install.sh | bash
```

Or in PowerShell, which also installs Git for Windows if it is missing:

```powershell
irm https://raw.githubusercontent.com/Vyrenbusiness-source/warmd-fewer-tokens-faster-agents/main/install.ps1 | iex
```

Then run `warmd init` once in your project. warmd runs on Windows only.

## Supported projects

warmd detects the project from its files. There is nothing to configure.

| Stack | Kept warm | Tests |
|---|---|---|
| **Unity** | Headless editor | EditMode and PlayMode, Test Runner API |
| **Godot** | Nothing, one test in 0.9 s | Built-in runner, GUT or gdUnit4 |
| **Web** | Dev server | Vitest, Jest or your script |
| **Rust, Go, Python, .NET** | Nothing | Native test runner |

Screenshots: a web page at desktop and phone width with layout problems as text lines, one frame of a Godot scene, and your own capture method in Unity.

## Limits that protect your machine

- **Queue.** Heavy runs share a few slots per machine, one per 4 cores and 8 GB of RAM, at least one. Six agents do not take the PC down.
- **One job per daemon.** A second caller waits instead of overwriting the first result.
- **Merge lock.** While a merge runs in a checkout, other runs there are refused with a clear message.
- **Caller gone.** A run whose agent or shell has died ends itself and frees the queue.
- **RAM wait.** A heavy start waits while less than 15% of RAM is free, at most 30 minutes.
- **Idle end.** An idle daemon stops after 30 minutes.

## Safety

About 4,100 lines of bash, one C# file, three small GDScript files and a PowerShell installer. You can read it in one sitting.

- **No telemetry.** It sends nothing to anyone. It talks only to git remotes: to yours, it pushes finished branches, and with a GitHub CI it uses `gh` to open the pull request, wait for the checks and merge. `warmd status` and `warmd doctor` check at most every 6 hours whether a newer version exists (a `git fetch` of the warmd clone, `WARMD_UPDATE_CHECK=0` turns it off). A new version is installed only by `warmd update`, or by a `warmd ship --release` of warmd itself.
- **What it writes.** `.warmd/` (ignored by git), a cache in `~/.cache/warmd`. The setup adds `.claude/agents`, a short block in `CLAUDE.md` or `AGENTS.md`, and the engine file: `Assets/Editor/Warmd` for Unity, `addons/warmd` for Godot.
- **What it can undo.** A merge only starts from a clean checkout. On red it runs `git reset --hard HEAD`, which is safe there because the tree was clean before.
- **What it kills.** Only processes it started. An editor you opened by hand is never touched, warmd refuses to run instead.
- **Pin a version.** Set `WARMD_VERSION_TAG` for the install, or clone and read it first.

Every number can be repeated. The [public CI run](https://github.com/Vyrenbusiness-source/warmd-fewer-tokens-faster-agents/actions/workflows/ci.yml) measures a fresh project on every push. Raw output: [PROOF.md](docs/PROOF.md).

## More

[Reference for every command and setting](docs/COMMANDS.md) · [Cheap models and parallel agents](docs/AGENTS.md) · [A/B per area](docs/ab.md) · [Measured](docs/MEASURED.md) · [Proof](docs/PROOF.md) · [FAQ](docs/FAQ.md) · [Changelog](CHANGELOG.md) · [Contributing](CONTRIBUTING.md) · [Security](SECURITY.md) · [Code of conduct](CODE_OF_CONDUCT.md) · [MIT license](LICENSE)
