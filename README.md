<div align="center">

<img src="docs/assets/social.png" alt="warmd: your AI agent should not wait for the engine" width="820">

# warmd

**Run Unity tests in 3 seconds instead of 56. Stop paying your AI agent to wait.**

A headless daemon and one-command CLI for Unity, Godot, web projects and any test suite.<br>
It finds your stack on its own and works with Claude Code, Codex, Cursor and anything that can run a shell command.

[![CI](https://github.com/Vyrenbusiness-source/warmd-unity-godot-ai-agents/actions/workflows/ci.yml/badge.svg)](https://github.com/Vyrenbusiness-source/warmd-unity-godot-ai-agents/actions/workflows/ci.yml)
[![License: MIT](https://img.shields.io/badge/license-MIT-green)](LICENSE)
![Unity](https://img.shields.io/badge/Unity-6-black?logo=unity)
![Godot](https://img.shields.io/badge/Godot-4-478cbf?logo=godotengine&logoColor=white)
![Agents](https://img.shields.io/badge/agents-Claude%20Code%20%7C%20Codex%20%7C%20Cursor-ff7a30)

<table>
<tr>
<td align="center" width="25%"><h3>95% faster</h3>one Unity test class<br><sub>56 s → 3 s, large HDRP project</sub></td>
<td align="center" width="25%"><h3>99% fewer tokens</h3>per green Unity test run<br><sub>33 KB log → 41 bytes</sub></td>
<td align="center" width="25%"><h3>0.4 s</h3>repeat run, code unchanged<br><sub>green results are cached</sub></td>
<td align="center" width="25%"><h3>26 s → 8 s</h3>full PlayMode run<br><sub>with <code>--speed 8</code></sub></td>
</tr>
</table>

**[Install](#install) · [What you get](#what-you-get) · [Cheap models first](#cheap-models-first) · [Measured](#measured) · [Commands](#commands) · [FAQ](#faq)**

**Do not trust the numbers, run them:** `warmd bench` measures your own project, and the [public CI run](https://github.com/Vyrenbusiness-source/warmd-unity-godot-ai-agents/actions/workflows/ci.yml) measures a fresh one on every push. Raw output is in [PROOF.md](docs/PROOF.md).

<img src="docs/assets/demo.gif" alt="warmd check finds a failing Unity test, then passes" width="720">

<sub>Illustrative session. Timings come from the measurements below.</sub>

</div>

If warmd saves you a wait, [give it a star](https://github.com/Vyrenbusiness-source/warmd-unity-godot-ai-agents/stargazers). It helps other people find it.

## Why

An AI agent working on a game spends most of its time waiting for the engine, and every wait gets paid for again in context. A 300-line build log costs tokens on each following turn. A second run of the same test costs the same minute again.

warmd removes both costs. The slow thing stays warm, the output stays short, and nothing runs twice.

## Install

```bash
curl -fsSL https://raw.githubusercontent.com/Vyrenbusiness-source/warmd-unity-godot-ai-agents/main/install.sh | bash
cd your-project
warmd init
warmd check
```

`warmd init` installs what your stack needs, adds agent definitions to `.claude/agents`, and adds a short block to `CLAUDE.md` or `AGENTS.md`. Your agent picks it up from there.

Needs bash and git. On Windows, use Git Bash.

## What you get

warmd detects the project from its files. There is nothing to configure.

| Stack | Kept warm | `build` | `test` | `shot` |
|---|---|---|---|---|
| **Unity** | Headless editor | `dotnet`, no Unity needed | EditMode and PlayMode through the Test Runner API | Your own capture method |
| **Godot** | Nothing by default, it starts in 0.2 s | Parses every script | Built-in runner, GUT or gdUnit4 | One frame of a scene |
| **Web** | Dev server | Typecheck and lint | Vitest, Jest or your script | Desktop and phone width |
| **Rust, Go, Python, .NET** | Nothing to keep warm | `cargo check`, `go build`, `ruff`, `dotnet` | Native test runner | |

Every stack gets the same four things:

- **Affected tests.** `warmd check` builds, then runs only the tests that mention what you changed.
- **Green cache.** A passing run stays passing until the code changes, across all worktrees. Red is never cached.
- **Short output.** One line on success. On failure only the error lines, with `file:line` where the stack allows it.
- **A queue.** At most two heavy Unity runs per machine, so six agents do not take the PC down.

For web work, `warmd shot` is often the fastest feedback an agent can get. It takes a desktop and a real 390 px phone screenshot in about 1.3 seconds, sized to cost few tokens.

## Cheap models first

Most agent tasks do not need your best model. warmd starts each one on the cheapest tier that fits and moves up only after a real failure.

```text
# tasks.txt: name | goal | done check | files
footer | add a footer to the landing page | warmd check passes | src/footer.css
sync   | find the root cause of the desync | test Net_Sync green | src/net/sync.ts
unused | list unused CSS classes | list of file:line | none
```

```console
$ warmd split tasks.txt
AGENT footer: subagent_type=warmd-worker model=sonnet prompt="Read .warmd/tasks/footer.md and do it."
AGENT sync: subagent_type=warmd-worker model=opus prompt="Read .warmd/tasks/sync.md and do it."
AGENT unused: subagent_type=warmd-scout model=haiku prompt="Read .warmd/tasks/unused.md and do it."
OK 3 tasks split
```

- **Clean split.** Each editing task gets its own git worktree with its slow caches seeded (`Library`, `.godot`, `node_modules`). If two tasks claim one file, the batch is refused before anything is created.
- **Stays current by itself.** Tiers map to the aliases `haiku`, `sonnet` and `opus`, which always point to the newest release. When a new model ships there is nothing to change.
- **Cheap first, then up.** An agent stops after two failed fixes. `warmd escalate <name>` hands the same task to the next tier, with the earlier commits as context.
- **It learns.** An area that needed escalation twice starts one tier higher next time.
- **A shared brief.** `warmd split` writes one short file that all agents of a batch read: who owns which file, plus findings. An agent adds a fact with `warmd note "price lives in src/price.ts:3"`, and the next one skips that search. It lives in the git directory, so every worktree sees the same copy and it is never committed. It keeps the newest 40 findings.
- **One-line reports.** `warmd finish` pushes and prints facts from git and the last run, so a final report costs almost nothing.

Any other model name works too, including other vendors. Tiers are config:

```ini
# warmd.conf
cheap=haiku
mid=sonnet
top=opus
top_paths=src/net/|physics/
```

## Measured

Windows 10, Unity 6000.4, Godot 4.7, Chrome. Your numbers will differ.

| Run | Before | With warmd |
|---|---|---|
| Unity, one test class, large HDRP project | 56 s | 3 s |
| Unity, full PlayMode test, same project | 54 s | 26 s |
| Same test with `--speed 8` | 54 s | 8 s |
| Unity, repeat with unchanged code | 3 s | 0.4 s |
| Unity, empty project | 3 to 4 s | 1.3 s |
| Godot, one test | | 0.9 s |
| Web, 2 screenshots with a warm Vite server | | 1.3 s |
| Vitest, touched test only instead of all | 4 s | 1.9 s |

Output per test run, in bytes. Tokens are roughly bytes divided by 4.

| Run | Raw output | warmd | Saved |
|---|---|---|---|
| Unity, green | 33,323 | 41 | 99.9% |
| Vitest, green | 270 | 11 | 96% |
| Vitest, one failure | 877 | 490 | 44% |

Honest notes:

- These numbers cover one run, not a whole session. A session also pays for reading code and for thinking. Red runs save less, because the error is the part an agent needs.
- The gain grows with project size. An empty Unity project starts so fast that the daemon barely matters.
- Godot starts in about 0.2 seconds, faster than a round trip to a running daemon, so warmd runs it fresh each time. Set `warm=1` in `warmd.conf` for projects with slow autoloads.

## Commands

```text
warmd status                 what was detected, what is warm
warmd bench [filter]         cold, warm and cached timings on your own project
warmd build                  fastest possible compile or typecheck
warmd test [filter]          run tests, green results are cached by code hash
warmd check                  build, then only the tests your change touches
warmd shot [url|path]        desktop and phone screenshot, small enough for an agent
warmd map <file>             outline with line numbers instead of reading the file
warmd stop                   end the warm process for real

warmd route <goal> [files]   cheapest fitting model tier
warmd split <tasks.txt>      worktrees, models and one-line prompts for parallel agents
warmd note "<one line>"      add a finding to the brief all agents of a batch share
warmd escalate <name>        same task, next model tier
warmd finish                 push and print a one-line report
warmd board                  all worktrees at a glance
warmd merge <branch>         safe merge into the base branch, rolls back on red

warmd init                   install the engine side and agent definitions
warmd doctor                 check what is missing
```

Unity extras: `--play`, `--edit`, `--speed N`, and `warmd call Namespace.Class.Method` to run a static method in the warm editor.

## Configuration

Everything is optional. Put a `warmd.conf` in the project root:

| Key | Meaning | Default |
|---|---|---|
| `build`, `test`, `lint`, `dev` | Override a command | detected |
| `url` | Dev server URL | read from its output |
| `base` | Base branch | from `origin/HEAD` |
| `slots` | Heavy runs per machine | 2 for Unity, half the cores otherwise |
| `idle_min` | Minutes until an idle daemon ends itself | 30 |
| `warm` | Keep a Godot process running | 0 |
| `cheap`, `mid`, `top` | Model per tier | haiku, sonnet, opus |
| `top_paths` | Paths that need the top tier (regex) | none |
| `shot_method` | Unity capture method | none |

Environment: `WARMD_NOCACHE=1` ignores the cache, use it for a release gate. Also `WARMD_TIMEOUT`, `WARMD_UNITY`, `WARMD_GODOT`, `WARMD_BROWSER`, `WARMD_GFX=1` (Unity daemon with graphics).

## FAQ

**How do I run Unity tests from the command line without reopening the editor?**
`warmd init`, then `warmd test MyTests`. The first call starts Unity with `-batchmode -nographics` and leaves it open. Later calls reuse it through the Test Runner API and survive domain reloads.

**Does it replace `-runTests`?**
It does the same job without paying the editor start each time. On a large project that start is most of the wait.

**Why does a Unity test take so long when the test itself is fast?**
Starting the editor loads the project and packages. warmd pays that once. `--speed N` then shortens tests that wait on game time by raising `Time.timeScale`. Fixed steps keep their size, so physics stays the same.

**What happens if the daemon hangs or crashes?**
warmd restarts it and repeats the job once. A timeout names the test that was stuck. `warmd stop` ends it for real, and an idle daemon ends itself after 30 minutes.

**Can I keep using the Unity editor by hand?**
Not on the same folder at the same time, Unity locks a project. warmd refuses to touch an editor it did not start. Use a worktree for the agent.

**How do I run Godot tests headless?**
`warmd test`. It uses GUT or gdUnit4 if present. Otherwise `warmd init` adds a small base class, and files named `test_*.gd` just work.

**Does `warmd shot` need Playwright or Puppeteer?**
No. It uses the Chrome, Edge or Chromium you already have.

**Does it work without an AI agent?**
Yes. It is a fast test runner for people too.

**Is it safe to install with `curl | bash`?**
Read [install.sh](install.sh) first, it is 12 lines. You can also clone the repo and run `bin/warmd` directly.

## Tested on

| | Windows | Linux | macOS |
|---|---|---|---|
| Web, generic | Local and CI | CI | CI |
| Godot | Local | CI | Untested |
| Unity | Local | Untested | Untested |

Unity needs a real editor, so it has no CI job yet. The Linux and macOS paths for Unity exist and have never been run. Reports are welcome.

## Contributing

Run `bash tests/run.sh`. It needs no engine. `bash tests/godot.sh` needs Godot 4.3 or newer. Adding a stack means one file in `adapters/`.

## License

MIT. If warmd saved you time, [a star](https://github.com/Vyrenbusiness-source/warmd-unity-godot-ai-agents/stargazers) is the best thanks.
