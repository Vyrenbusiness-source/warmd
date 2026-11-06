# Launch posts, drafts

Drafts only. Nothing here has been posted. Every number links to a measured run in this repo, none is estimated.
Facts to keep in every post: Windows only (Git Bash), MIT, no telemetry, the full log stays one path away.

## Plan

1. **Same day, US morning** (about 15:00 to 17:00 German time, Tuesday to Thursday): Show HN, then r/ClaudeAI an hour later. GitHub Trending counts stars inside 24 hours, so both go out on one day ([research](research.md#what-they-have-in-common)).
2. **Next day:** r/Unity3D and r/godot, each with the engine's own numbers. Read each sub's self-promotion rule first.
3. **Stay for the first three hours** and answer every comment. Expect the questions at the end of this file.
4. **From 2026-11-16** (or at 100 stars): awesome lists, see [awesome-lists.md](awesome-lists.md).
5. **Later, after the first stars:** Product Hunt and X.

Not a fit: r/LocalLLaMA (warmd routes Claude model tiers and runs on Windows, the sub runs local models mostly on Linux and macOS).

---

## Hacker News (Show HN)

**Title** (75 characters, HN allows 80):

```
Show HN: Warmd – Unity tests in 3 s instead of 56 s for Claude Code agents
```

Alternative if the Unity focus feels too narrow:

```
Show HN: Warmd – your coding agent waits less and reads less
```

**URL:** https://github.com/Vyrenbusiness-source/warmd-fewer-tokens-faster-agents

**Text:**

```
I build a Unity game with several Claude Code agents in parallel. Most of their time went into waiting: every test run started a fresh Unity editor in batch mode, 56 seconds for one test class, and then the agent read a 33 KB log to find one line.

warmd keeps a headless editor running between runs, so the same test class takes 3 s. A green run hands the agent 41 bytes ("OK 3s test, 8 passed") instead of the log. Unchanged code is answered from a cache in 0.4 s. A red run prints the test, file:line, expected and actual, plus the path of the full log, so nothing is hidden.

It also does this for Godot, Vite/Vitest, pytest, cargo, go test and dotnet, runs only the tests a change can reach (real import graph), and merges agent branches one at a time with a rollback when the checks go red.

I tried to measure the bill, not bytes. A/B with claude -p, 5 runs per arm, one real bug: web project 26% fewer tokens and 27% lower cost, both arms fixed it 5 of 5. Python: 7% fewer, which is within the spread. Task time on small projects is equal; the gain there is cost, on game engines it is time. Method and raw tables are in docs/ab.md.

Limits: Windows only for now (Git Bash), about 4,200 lines of bash. No telemetry, it only talks to your git remote.

I'd like to hear where it breaks on your project, and whether anyone has numbers for Unreal.
```

---

## Reddit r/ClaudeAI

Flair: the sub's showcase flair for projects built with Claude.

**Title:**

```
My Claude Code agents spent most of each Unity test waiting for the editor. Now 3 s instead of 56 s, and they read 41 bytes instead of a 33 KB log (open source, MIT)
```

**Text:**

```
I run several Claude Code agents on a Unity project. Two things burned time and tokens:

1. Every test run started Unity in batch mode: 56 s for one test class.
2. The agent then read the whole editor log (33,323 bytes) to find out it was green.

warmd fixes both without the agent doing anything new. After `warmd init` the agent's instructions and hooks call it:

- A headless editor stays warm between runs: the same test class takes 3 s.
- Green is one line: `OK 3s test` / `8 passed, 0 failed, 0 skipped`.
- Red is the test, file:line, expected and actual, plus the path of the full log.
- Unchanged code is answered from a green cache in 0.4 s.
- Only tests the change can reach run (real import graph for C#, GDScript, JS/TS, Python).

It also routes tasks to the cheapest model tier (reads on haiku, edits on sonnet, hard areas on opus), escalates one tier on a real failure, and hands off to a fresh agent before the context fills.

Measured, not estimated: an A/B with `claude -p`, 5 runs per arm, one real bug. Web project: 26% fewer tokens, 27% lower cost, both arms fixed it 5 of 5. Python: 7% fewer, within the spread, so I don't claim that one. Raw tables: docs/ab.md.

Windows only for now. Also works with Godot, Vitest, pytest, cargo, go test, dotnet, and with Codex and Cursor.

https://github.com/Vyrenbusiness-source/warmd-fewer-tokens-faster-agents

Happy to answer questions, and I'd like to know what it does on your project: `warmd bench` measures before and after.
```

---

## Reddit r/Unity3D

Flair: Resources / Tools (check the sub's current flair list and self-promotion rule before posting).

**Title:**

```
I kept a headless Unity editor warm between test runs: one EditMode class 56 s → 3 s, a PlayMode test 54 s → 8 s with time lapse (free, MIT)
```

**Text:**

```
Built this for AI coding agents, but it works the same from a terminal.

Every Unity test run from the command line starts a new editor in batch mode. On my HDRP project that was 56 s for one EditMode test class and 54 s for one PlayMode test.

warmd starts the editor once with -nographics and keeps it open. Test runs go to that editor through the Test Runner API:

- one EditMode test class: 56 s → 3 s
- the full PlayMode test: 54 s → 26 s, and 8 s with `--speed 8` (Time.timeScale for the test)
- repeat with unchanged code: 0.4 s from a cache
- a hung test names itself: `timeout after 5s in phase testing, stuck in: <test>`
- output is one line when green, the failing assertion with file:line when red

It never touches an editor you opened by hand, it stops its own editor after 30 idle minutes, and it waits for free RAM before starting a heavy run. Windows only for now. The Unity side is one C# file in Assets/Editor/Warmd.

https://github.com/Vyrenbusiness-source/warmd-fewer-tokens-faster-agents

Numbers are from Unity 6000.4 on Windows 10, raw output in docs/PROOF.md. I'd like to hear the numbers on your project.
```

---

## Reddit r/godot

Flair: Resource / Plugin (check the sub's rules first).

**Title:**

```
Running Godot tests from an AI coding agent: one test in 0.9 s, and the agent reads only the failing assertion (GUT, gdUnit4 or the built-in runner, MIT)
```

**Text:**

```
I use Claude Code agents on game projects. With Godot the engine starts fast, so the problem is not waiting but reading: the agent pays tokens for the whole test output every run.

warmd runs the tests (built-in runner, GUT or gdUnit4) and hands the agent one line when green and the failing test with file:line, expected and actual when red. Unchanged code is answered from a cache. It runs only the tests whose scripts a change can reach, from a real GDScript dependency graph.

One Godot test takes 0.9 s end to end on Windows 10 with Godot 4.7. The Godot side is three small GDScript files in addons/warmd. Windows only for now.

https://github.com/Vyrenbusiness-source/warmd-fewer-tokens-faster-agents

Feedback from GUT and gdUnit4 users is welcome, those are the runners I tested least.
```

---

## X (thread)

Attach `docs/assets/hero-dark.png` to the first post, `docs/assets/speed-dark.png` to the second.

```
1/ Your coding agent waits less and reads less.

warmd keeps Unity, Godot and web dev servers warm for Claude Code, Codex and Cursor. One Unity test class: 56 s → 3 s. Open source, MIT.

github.com/Vyrenbusiness-source/warmd-fewer-tokens-faster-agents
```

```
2/ A green Unity run used to hand the agent a 33,323-byte log. With warmd it gets 41 bytes: "OK 3s test, 8 passed". Red gets the test, file:line, expected and actual. Unchanged code: 0.4 s from cache.
```

```
3/ Measured the bill, not bytes: A/B with claude -p, 5 runs per arm, one real bug. Web: 26% fewer tokens, 27% lower cost, 5 of 5 fixed in both arms. Python: within the spread, so no claim. Raw tables in the repo.
```

```
4/ It also routes each task to the cheapest model tier, escalates on real failures, hands off before the context fills and merges agent branches with rollback. Windows only for now. Where does it break on your project?
```

---

## Discord (Claude Developers, showcase channel)

```
warmd: keeps the Unity editor, Godot and web dev servers warm for Claude Code and hands the agent only the error. One Unity test class 56 s → 3 s, a green run is 41 bytes instead of a 33 KB log, A/B on a web bugfix: 26% fewer tokens, 27% lower cost. Windows, MIT, no telemetry. https://github.com/Vyrenbusiness-source/warmd-fewer-tokens-faster-agents
```

---

## Product Hunt (later)

- **Name:** warmd
- **Tagline** (60 characters max): `Your coding agent waits less and reads less`
- **Description:** `warmd keeps Unity, Godot and web engines warm for Claude Code, Codex and Cursor, caches green test runs and hands the agent only the error. One Unity test class: 56 s to 3 s. Open source, MIT, Windows.`
- **Gallery:** hero, speed, tokens and auto images from `docs/assets`, dark variants.

---

## Questions to expect, with short answers

- **"Why not `cargo test -q` or `| tail -20`?"** Quiet flags cut green output, not the wait. On Unity the wait is the cost: 56 s cold vs 3 s warm. On red, warmd keeps the assertion and file:line that `tail` can cut off.
- **"Bytes are not tokens, does it lower the bill?"** The A/B counts billed tokens and dollars from the `claude -p` JSON: 26% fewer tokens and 27% lower cost on the web project, Python within the spread. See docs/ab.md.
- **"Doesn't it hide context the agent needs?"** Every result prints the path of the full log. The agent can read it when it wants.
- **"macOS, Linux?"** Not yet. CI runs on Windows only, so that is the only claim.
- **"Telemetry?"** None. It talks to your git remote and, with GitHub CI, to `gh`.
- **"What does it change in my project?"** `.warmd/` (git-ignored), a short block in CLAUDE.md or AGENTS.md, `.claude/agents`, and the engine file (Assets/Editor/Warmd or addons/warmd).
