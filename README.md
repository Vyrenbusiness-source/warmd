<div align="center">

<img src="docs/assets/social.png" alt="warmd: your AI agent should not wait for the engine" width="820">

# warmd

**Install once. After that warmd runs the slow parts for your coding agent, and you do nothing.**

For Windows, in Git Bash or PowerShell. [Install in one line](#install).

[![Star on GitHub](https://img.shields.io/github/stars/Vyrenbusiness-source/warmd-fewer-tokens-faster-agents?style=social&label=Star)](https://github.com/Vyrenbusiness-source/warmd-fewer-tokens-faster-agents/stargazers)
[![CI](https://github.com/Vyrenbusiness-source/warmd-fewer-tokens-faster-agents/actions/workflows/ci.yml/badge.svg)](https://github.com/Vyrenbusiness-source/warmd-fewer-tokens-faster-agents/actions/workflows/ci.yml)
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

**Saves you tokens or time? [Star it](https://github.com/Vyrenbusiness-source/warmd-fewer-tokens-faster-agents/stargazers).** One click, and others find it.

</div>

## What it brings

Real runs on Windows 10, your numbers will differ. Method and raw tables: [docs/ab.md](docs/ab.md) for web and Python, [MEASURED.md](docs/MEASURED.md) for games.

### Websites

Sample project: Vite and Vitest, 6 test files, 17 tests.

- **Test output.** A red run costs 136 tokens instead of 714, a green run 6 instead of 289.
- **Repeat run.** 0.43 s instead of 1.7 s while the code is unchanged.
- **Agent fixing one bug.** 26% fewer tokens and 27% lower cost per run, about 2 turns fewer. 5 of 5 fixed in both arms.
- **Not faster.** The agent took 23.1 s against 22.2 s, inside the spread. After a one-file change warmd runs 18 to 59% of the tests, but build plus selection takes longer than this whole suite of under 2 s.

### Programming

Sample project: Python and pytest, 5 test files, 13 tests.

- **Test output.** A red run costs 153 tokens instead of 479, a green run 6 instead of 309.
- **Repeat run.** 0.43 s instead of 0.9 s while the code is unchanged.
- **Agent fixing one bug.** 7% fewer tokens and 11% lower cost per run. Both gaps are inside the spread, so this is a direction, not a proof.
- **Not faster.** The agent took 20.5 s against 19.4 s. warmd runs 31% of the tests after a change, but on 13 tests that finish in 0.1 s the selection costs more than it saves.

### Games

Unity 6000.4 on a large HDRP project, and Godot 4.7. Here the engine start is the wait, so time is where warmd helps most.

- **One Unity test class.** 3 s instead of 56 s.
- **Full PlayMode test.** 26 s instead of 54 s, 8 s with time lapse.
- **Repeat run.** 0.4 s instead of 3 s while the code is unchanged.
- **Test output.** A green Unity run is 41 bytes instead of a 33,323 byte log.
- **Godot.** One test in 0.9 s. Godot starts fast, so nothing needs to stay warm.

No agent A/B has been measured for games yet.

![Bars: Unity test class 56 s to 3 s, PlayMode 54 s to 26 s and 8 s with time lapse, repeat run 3 s to 0.4 s](docs/assets/speed.png)

## How it saves tokens and time

One line per saver: what it saves, and why.

- **Warm engine.** Saves the engine start on every run, because the Unity editor or dev server stays open between runs.
- **Short test output.** Saves tokens, because the agent reads one line on green and only the error lines on red. The full log stays on disk.
- **Green cache.** Saves the whole run, because a passing result stays valid until the code changes, across all worktrees. Red is never cached.
- **Affected tests.** Saves test time on large suites, because only the tests that reach the changed files through imports run. On small suites it does not pay off.
- **Outline instead of the full file.** Saves tokens, because the agent first gets the structure with line numbers and then reads only the lines it needs.
- **Repo map.** Saves the first round of file reads, because the agent gets the most referenced symbols of the whole project in one short map: 248 instead of 567 tokens on the web sample, 177 instead of 445 on the Python sample.
- **Tool lists only when needed.** Saves start tokens, because the setup check names every MCP server that loads all its tools up front and the setting that defers them.
- **Lean agent start.** Saves tokens on every subagent, because each starts with only the tools it needs: 3,762 start tokens instead of 15,334.
- **Cheapest fitting model.** Saves cost, because a task starts on the cheapest tier that can do it and moves up one tier on its own after a real failure. A project can set the lowest tier and the number of parallel agents.
- **Shared brief.** Saves repeated searches, because all agents of a batch read one short file with who owns what and what the others found.
- **Handoff.** Saves the price of a full context, because an agent near its limit writes down its state and a fresh agent continues from there.
- **Wake on stall.** Saves idle time, because an agent whose worktree has not moved for 5 minutes is caught and told its next step.
- **Merge with rollback.** Saves cleanup, because finished branches merge one at a time, the result runs the project's checks, and red is rolled back.

![Bars: Unity green run 33,323 to 41 bytes, web red run 714 to 136 tokens, Python red run 479 to 153 tokens](docs/assets/tokens.png)

## Runs itself

Install once and set up each project once. The setup adds a short block to `CLAUDE.md` or `AGENTS.md`, agent definitions and hooks, and from then on your agent calls warmd by itself. A session that restarts or compacts picks up its batch where it was. When an agent finishes, its real token count is recorded and its branch is pushed. When the last agent of a batch is done, the branches merge with rollback on red; with a CI on GitHub they go through one pull request, wait for the checks and merge on green. An agent near its context limit hands over to a fresh one by itself, and a failed task moves to the next model by itself. Your code is never shortened.

The syntax of every step is in the [reference](docs/COMMANDS.md), for when you want to run one by hand.

![Flow: a task list is split into worktrees for Haiku, Sonnet and Opus, merged with rollback; shared brief and escalation below](docs/assets/flow.png)

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
| **Godot** | Nothing, starts in 0.2 s | Built-in runner, GUT or gdUnit4 |
| **Web** | Dev server | Vitest, Jest or your script |
| **Rust, Go, Python, .NET** | Nothing | Native test runner |

Screenshots: a web page at desktop and phone width with layout problems as text lines, one frame of a Godot scene, and your own capture method in Unity.

## Limits that protect your machine

- **Queue.** At most two heavy Unity runs per machine, so six agents do not take the PC down.
- **One job per daemon.** A second caller waits instead of overwriting the first result.
- **Merge lock.** While a merge runs in a checkout, other runs there are refused with a clear message.
- **Caller gone.** A run whose agent or shell has died ends itself and frees the queue.
- **Idle end.** An idle daemon stops after 30 minutes.

## Safety

About 3,400 lines of bash, one C# file, three small GDScript files and a PowerShell installer. You can read it in one sitting.

- **No network.** It sends nothing anywhere, there is no telemetry. Only the final report talks to the outside, and only with `git push` to your own remote.
- **What it writes.** `.warmd/` (ignored by git), a cache in `~/.cache/warmd`. The setup adds `.claude/agents`, a short block in `CLAUDE.md` or `AGENTS.md`, and the engine file: `Assets/Editor/Warmd` for Unity, `addons/warmd` for Godot.
- **What it can undo.** A merge only starts from a clean checkout. On red it runs `git reset --hard HEAD`, which is safe there because the tree was clean before.
- **What it kills.** Only processes it started. An editor you opened by hand is never touched, warmd refuses to run instead.
- **Pin a version.** Set `WARMD_VERSION_TAG` for the install, or clone and read it first.

Do not trust the numbers, run them. The [public CI run](https://github.com/Vyrenbusiness-source/warmd-fewer-tokens-faster-agents/actions/workflows/ci.yml) measures a fresh project on every push. Raw output: [PROOF.md](docs/PROOF.md).

## More

[Reference for every command and setting](docs/COMMANDS.md) · [Cheap models and parallel agents](docs/AGENTS.md) · [A/B per area](docs/ab.md) · [Measured](docs/MEASURED.md) · [Proof](docs/PROOF.md) · [FAQ](docs/FAQ.md) · [Contributing](CONTRIBUTING.md) · MIT license
