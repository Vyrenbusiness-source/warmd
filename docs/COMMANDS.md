# Commands and configuration

Back to the [README](../README.md).

## Commands

```text
warmd status                 what was detected, what is warm
warmd bench [filter]         cold, warm and cached timings on your own project
warmd build                  fastest possible compile or typecheck
warmd test [filter]          run tests, green results are cached by code hash
warmd check                  build, then only the tests your change touches
warmd shot [url|path]        desktop and phone screenshot, small enough for an agent
warmd map <file>             outline with line numbers instead of reading the file
warmd audit                  what your agents really pay for, biggest first
warmd stop                   end the warm process for real

warmd route <goal> [files]   cheapest fitting model tier
warmd split <tasks.txt>      worktrees, models and one-line prompts for parallel agents
warmd note "<one line>"      add a finding to the brief all agents of a batch share
warmd escalate <name>        same task, next model tier
warmd finish                 push and print a one-line report
warmd board                  all worktrees at a glance
warmd merge <branch>         safe merge into the base branch, rolls back on red
warmd merge --continue       finish a merge after you resolved its conflicts

warmd init                   install the engine side and agent definitions
warmd doctor                 check what is missing
warmd package                build a player with your own method (Unity)
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
| `floor` | Lowest tier this project accepts: `mid` or `top` | none |
| `top_paths` | Paths that need the top tier (regex) | none |
| `shot_method` | Unity capture method | none |
| `package_method`, `package_args` | Unity player build for `warmd package` | none |
| `gate` | Shell command `warmd merge` runs instead of `check` | none |
| `port_env` | Env variable that gets a stable port per worktree | none |
| `seed_links` | Untracked folders linked into new worktrees | none |

Environment: `WARMD_NOCACHE=1` ignores the cache, use it for a release gate. Also `WARMD_TIMEOUT`, `WARMD_UNITY`, `WARMD_GODOT`, `WARMD_BROWSER`, `WARMD_GFX=1` (Unity daemon with graphics).

