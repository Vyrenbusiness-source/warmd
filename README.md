<div align="center">

<picture>
  <source media="(prefers-color-scheme: dark)" srcset="docs/assets/hero-dark.png">
  <img src="docs/assets/hero-light.png" width="800" alt="warmd: your coding agent waits less and reads less. Real session: warmd test shows only the failing assertion, a one-line fix, the test passes, the repeat run is answered from the cache.">
</picture>

**Your coding agent waits less and reads less.**<br>
warmd keeps the engine warm, skips tests whose code did not change and hands the agent only the error.<br>
<sub>Unity · Godot · Web · Python · Rust · Go · .NET, on Windows, for Claude Code, Codex and Cursor</sub>

<table>
<tr>
<td align="center" width="25%"><h3>56 s → 3 s</h3>one Unity test class<br><sub><a href="docs/MEASURED.md">warm headless editor</a></sub></td>
<td align="center" width="25%"><h3>33,323 → 41</h3>bytes read per green run<br><sub><a href="docs/PROOF.md#tokens">Unity log vs. warmd</a></sub></td>
<td align="center" width="25%"><h3>26% fewer</h3>tokens, 27% lower cost<br><sub><a href="docs/ab.md">agent A/B, 5 of 5 fixed per arm</a></sub></td>
<td align="center" width="25%"><h3>0.4 s</h3>repeat run, code unchanged<br><sub><a href="docs/PROOF.md#unity">answered from the green cache</a></sub></td>
</tr>
</table>

```text
/plugin marketplace add Vyrenbusiness-source/warmd-fewer-tokens-faster-agents
/plugin install warmd@warmd
```

<sub>Inside Claude Code, then restart it. Codex, Cursor or your own terminal: see [Install](#install).</sub>

[Install](#install) · [Proof](#proof) · [Reference](docs/COMMANDS.md) · [FAQ](docs/FAQ.md)

[![CI](https://github.com/Vyrenbusiness-source/warmd-fewer-tokens-faster-agents/actions/workflows/ci.yml/badge.svg)](https://github.com/Vyrenbusiness-source/warmd-fewer-tokens-faster-agents/actions/workflows/ci.yml)
[![Release](https://img.shields.io/github/v/release/Vyrenbusiness-source/warmd-fewer-tokens-faster-agents?color=d4442a)](https://github.com/Vyrenbusiness-source/warmd-fewer-tokens-faster-agents/releases/latest)
[![License: MIT](https://img.shields.io/badge/license-MIT-1d1915)](LICENSE)
[![Stars](https://img.shields.io/github/stars/Vyrenbusiness-source/warmd-fewer-tokens-faster-agents?style=social)](https://github.com/Vyrenbusiness-source/warmd-fewer-tokens-faster-agents)

</div>

## The problem

A coding agent spends most of a test run waiting for the engine to start, then pays tokens to read a log it mostly ignores.
warmd keeps the engine warm, answers unchanged code from cache and hands the agent only the error.

What the agent reads after one Unity test run, real output from [PROOF.md](docs/PROOF.md#unity):

| | Without warmd | With warmd |
|---|---|---|
| **Green** | 33,323 bytes of editor log, about 8,300 tokens, after a cold editor start | `OK 3s test`<br>`8 passed, 0 failed, 0 skipped` |
| **Red** | The same log with the failure somewhere inside | `RED Adds: ScoreTests.cs:2 Expected: 5    But was:  -1` |
| **Repeat, code unchanged** | The whole run again | `OK cached, code unchanged: 1 passed, 0 failed, 0 skipped` in 0.4 s |

## What runs by itself

After `warmd init` your agent calls warmd through its instructions and hooks. Nobody types a warmd command.

<picture>
  <source media="(prefers-color-scheme: dark)" srcset="docs/assets/auto-dark.png">
  <img src="docs/assets/auto-light.png" width="800" alt="Four stations: 01 test, warm and short; 02 route, cheapest model; 03 merge, green or back; 04 machine, never frozen">
</picture>

| | |
|---|---|
| **01 Test** | **Warm engine:** the Unity editor runs headless and stays open, the web dev server too. **Affected tests:** a real import graph for JS and TS, Python, C# and GDScript, and `warmd check` takes the faster of full and selective. **Green cache:** a passing result holds until the code changes, across worktrees. **Error only:** green is one line, red is the test, `file:line`, expected and actual. |
| **02 Route** | **Cheapest tier:** reading starts on `haiku`, edits on `sonnet`, hard areas on `opus`. **Escalation:** a real failure moves the task one tier up with its commits as context. **Handoff:** past 70% of the budget or 60 tool calls an agent commits and a fresh one continues. **Shared brief:** one fact found by one agent is never searched again. |
| **03 Merge** | **One at a time:** pushed branches merge in the background and the project's checks run on each result. **Rollback:** red is reset, the base stays green. **CI:** with GitHub CI the branches go through one pull request, the wait prints an ETA and stops at the first red job. |
| **04 Machine** | **RAM wait:** a heavy start queues while less than 15% of RAM is free. **Queue:** one heavy slot per 4 cores and 8 GB. **Idle end:** a daemon stops after 30 minutes. **Own processes only:** an editor you opened by hand is never touched. |

Also: time lapse for Unity tests (`--speed N`), screenshots and layout problems as text, a performance baseline, repo maps and file outlines, lean subagent starts and real token cost per task. Every one is in the [reference](docs/COMMANDS.md).

## Proof

Real runs on Windows 10, nothing estimated. The [public CI](https://github.com/Vyrenbusiness-source/warmd-fewer-tokens-faster-agents/actions/workflows/ci.yml) measures a fresh project on every push.

<picture>
  <source media="(prefers-color-scheme: dark)" srcset="docs/assets/speed-dark.png">
  <img src="docs/assets/speed-light.png" width="800" alt="Unity test class 56 s to 3 s, PlayMode test 54 s to 26 s and 8 s with time lapse, repeat run 3 s to 0.4 s">
</picture>

<picture>
  <source media="(prefers-color-scheme: dark)" srcset="docs/assets/tokens-dark.png">
  <img src="docs/assets/tokens-light.png" width="800" alt="Unity green run 33,323 to 41 bytes, web green run 289 to 6 tokens, web red run 714 to 136 tokens, Python red run 479 to 153 tokens">
</picture>

| Agent fixing one bug, 5 runs per arm | Tokens | Cost | Fixed |
|---|---|---|---|
| Web, Vite and Vitest | **26% fewer** | 27% lower | 5 of 5 in both arms |
| Python, pytest | 7% fewer, within the spread | 11% lower | 5 of 5 in both arms |

Task time is equal within the spread in both areas: the gain on small projects is tokens and cost, on game engines it is time. Method and raw tables: [docs/ab.md](docs/ab.md), raw output: [docs/PROOF.md](docs/PROOF.md), game numbers: [docs/MEASURED.md](docs/MEASURED.md).

## Install

Claude Code, as a plugin. It brings the hooks, the agent definitions and the `warmd` command for the agent, nothing to run in your project:

```text
/plugin marketplace add Vyrenbusiness-source/warmd-fewer-tokens-faster-agents
/plugin install warmd@warmd
```

For Codex, Cursor or your own terminal, install the command. Git Bash:

```bash
curl -fsSL https://raw.githubusercontent.com/Vyrenbusiness-source/warmd-fewer-tokens-faster-agents/main/install.sh | bash
```

PowerShell, which also installs Git for Windows if it is missing:

```powershell
irm https://raw.githubusercontent.com/Vyrenbusiness-source/warmd-fewer-tokens-faster-agents/main/install.ps1 | iex
```

Then run `warmd init` once in your project. warmd detects the stack from its files, there is nothing to configure.
With the plugin, `warmd init` is optional: it adds the block to `CLAUDE.md` and the agent definitions to the project, the plugin's hooks step aside for the ones it writes.

| Stack | Kept warm | Tests |
|---|---|---|
| **Unity** | Headless editor | EditMode and PlayMode, Test Runner API |
| **Godot** | Nothing, one test in 0.9 s | Built-in runner, GUT or gdUnit4 |
| **Web** | Dev server | Vitest, Jest or your script |
| **Rust, Go, Python, .NET** | Nothing | Native test runner |

<details>
<summary><b>Safety: what it sends, writes, undoes and kills</b></summary>

About 4,200 lines of bash, one C# file, three small GDScript files and a PowerShell installer. You can read it in one sitting.

- **No telemetry.** It talks only to git remotes: it pushes finished branches to yours, and with a GitHub CI it uses `gh` to open the pull request, wait for the checks and merge. `warmd status` and `warmd doctor` check at most every 6 hours for a newer version with a `git fetch` of the warmd clone, `WARMD_UPDATE_CHECK=0` turns it off. A new version is installed only by `warmd update`, or by a `warmd ship --release` of warmd itself.
- **What it writes.** `.warmd/` (ignored by git), a cache in `~/.cache/warmd`. The setup adds `.claude/agents`, a short block in `CLAUDE.md` or `AGENTS.md`, and the engine file: `Assets/Editor/Warmd` for Unity, `addons/warmd` for Godot.
- **What it can undo.** A merge only starts from a clean checkout. On red it runs `git reset --hard HEAD`, which is safe there because the tree was clean before.
- **What it kills.** Only processes it started. An editor you opened by hand is never touched, warmd refuses to run instead.
- **Limits.** One job per daemon, a merge lock per checkout, a run whose caller died ends itself, the RAM wait lasts at most 30 minutes.
- **Pin a version.** Set `WARMD_VERSION_TAG` for the install, or clone and read it first.

</details>

## More

[Every command and setting](docs/COMMANDS.md) · [Cheap models and parallel agents](docs/AGENTS.md) · [A/B per area](docs/ab.md) · [Measured](docs/MEASURED.md) · [Proof](docs/PROOF.md) · [FAQ](docs/FAQ.md) · [Changelog](CHANGELOG.md) · [Contributing](CONTRIBUTING.md) · [Security](SECURITY.md) · [MIT license](LICENSE)

<sub>Saves you tokens or time? A star helps others find it.</sub>
