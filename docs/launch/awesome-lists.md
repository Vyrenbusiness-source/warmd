# Awesome lists, drafts

Drafts only. Nothing has been submitted. Rules and star counts checked 2026-11-06.
One list at a time, each entry written as a description, no sales pitch, no emoji, matching the style of the entries next to it.

First commit of warmd: 2026-11-02. Several lists want 14 days of history, so the earliest date for those is **2026-11-16**.

| List | Stars | Section | How to submit | Earliest |
|---|---|---|---|---|
| [hesreallyhim/awesome-claude-code](https://github.com/hesreallyhim/awesome-claude-code) | 57,400 | Testing, or Agent Orchestration | Only the [web issue form](https://github.com/hesreallyhim/awesome-claude-code/issues/new?template=recommend-resource.yml), filled in by a human. No PR, no `gh`, one resource at a time. | 2026-11-16, or at 100 stars |
| [jqueryscript/awesome-claude-code](https://github.com/jqueryscript/awesome-claude-code) | 544 | Tools & Utilities | PR, guidelines "under construction", follow the existing style | now |
| [jamesmurdza/awesome-ai-devtools](https://github.com/jamesmurdza/awesome-ai-devtools) | 3,996 | Agent Infrastructure, Configuration & Context Management | PR with the [template checklist](https://github.com/jamesmurdza/awesome-ai-devtools/blob/main/.github/PULL_REQUEST_TEMPLATE.md): developer tool, clear description, matching style | now |
| [ai-boost/awesome-harness-engineering](https://github.com/ai-boost/awesome-harness-engineering) | 5,070 | Design Primitives, Verification & CI Integration | PR, format `- [Title](URL) — 1–2 sentence note explaining why` | now |
| [insthync/awesome-unity3d](https://github.com/insthync/awesome-unity3d) | 2,749 | Open Source Repositories, AI Agent | PR, follow the existing style | now |
| [Calinou/awesome-godot](https://github.com/Calinou/awesome-godot) | 10,962 | Plugins and scripts, Godot 4 | PR, free license (MIT is fine), alphabetical order | now |

Not a fit today: [composio-community/awesome-claude-plugins](https://github.com/composio-community/awesome-claude-plugins) and [rohitg00/awesome-claude-code-toolkit](https://github.com/rohitg00/awesome-claude-code-toolkit) list Claude Code plugins with a `.claude-plugin` manifest, which warmd does not ship yet. [RyanNielson/awesome-unity](https://github.com/RyanNielson/awesome-unity) and [agarrharr/awesome-cli-apps](https://github.com/agarrharr/awesome-cli-apps) are archived. [e2b-dev/awesome-ai-agents](https://github.com/e2b-dev/awesome-ai-agents) lists agents, not agent tooling.

## Entry lines

### hesreallyhim/awesome-claude-code (issue form fields)

- **Name:** warmd
- **URL:** https://github.com/Vyrenbusiness-source/warmd-fewer-tokens-faster-agents
- **Category:** Testing
- **Description:**

```
Keeps the Unity editor, Godot and web dev servers warm between test runs, answers unchanged code from a green cache and hands the agent one line when green and the failing assertion with file:line when red. Installs instructions and hooks so Claude Code calls it without prompting, routes tasks to model tiers and merges agent branches with rollback. Windows.
```

### jqueryscript/awesome-claude-code

```
- [**warmd**](https://github.com/Vyrenbusiness-source/warmd-fewer-tokens-faster-agents) - Keeps Unity, Godot and web dev servers warm for coding agents, caches green test runs and passes only the failing assertion to the agent.
```

### jamesmurdza/awesome-ai-devtools

```
- [warmd](https://github.com/Vyrenbusiness-source/warmd-fewer-tokens-faster-agents) — Test and build helper for Claude Code, Codex and Cursor agents. Keeps Unity, Godot and web dev servers warm, runs only affected tests, caches green runs and returns only the error.
```

### ai-boost/awesome-harness-engineering

```
- [warmd](https://github.com/Vyrenbusiness-source/warmd-fewer-tokens-faster-agents) — Verification layer for coding agents: a warm engine, affected-test selection and a green cache keep test runs short, and the agent reads one line per green run instead of the log. Its A/B reports billed tokens and cost per arm with the spread.
```

### insthync/awesome-unity3d (AI Agent)

```
* [warmd](https://github.com/Vyrenbusiness-source/warmd-fewer-tokens-faster-agents) - Keeps a headless Unity editor warm for AI coding agents and runs EditMode and PlayMode tests through it, with a green cache, PlayMode time lapse and error-only output
```

### Calinou/awesome-godot (Plugins and scripts, Godot 4)

```
- [warmd](https://github.com/Vyrenbusiness-source/warmd-fewer-tokens-faster-agents) - Runs Godot tests (built-in runner, GUT or gdUnit4) for AI coding agents, selects the tests a change can reach and reports only the failing assertion.
```
