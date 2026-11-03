# Measured

Back to the [README](../README.md). Raw output is in [PROOF.md](PROOF.md).


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

Numbers are per run. Repeat them on your own project with `warmd bench`.

## Agent start cost (`warmd init --slim`)

Measured 2026-11-03 with real `claude -p` runs on a throwaway project, `SLIM_LIVE=1 bash tests/slim.sh` (function `slim_matrix` in `lib/slim.sh`). Unit: input tokens of the first call of one subagent. Source: commit `b04fe81`.

| Tool set of the agent | Start tokens |
|---|---|
| All tools (agent has no `tools` line) | 15,334 |
| `Read, Grep, Glob, Edit, Write` (the `--slim` default) | 3,762 |
| Same set plus `Bash` | 5,629 (+1,867) |

The probe project switches each source on and off: `CLAUDE.md` (40 rules), 30 skills, 15 agents, one MCP server with 25 tools. `slim_matrix` prints name, before, after and delta for each source. Run it to get the per-source rows for your own setup. They are not copied here because they depend on your setup.

## Code hash speed (`code_key`)

Measured 2026-11-03, 10-call average per row, commit `9c68401` (`17d6f02` before the rebase). `code_key` is the hash that decides whether a green result is cached.

| Changed files | Before | After |
|---|---|---|
| 40 | 662 ms | 115 ms (5.7x) |
| 1 | about 100 ms | about 100 ms |

Method: before, one `sha1sum` fork per changed file. After, 2 `git` and 2 `sha1sum` calls with files hashed in chunks of 100. A green-cache hit also no longer waits for a slot in the queue. `tests/run.sh` is green.
