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
Per source, added to a base of 15,334 start tokens (haiku, 13 live runs, 2026-11-03):

| Source | Start tokens added |
|---|---|
| `CLAUDE.md` (40 rules) | +1,713 |
| 30 skills | +1,261 |
| 15 agents | -5 |
| One MCP server with 25 tools | +244 |
| User plugins and hooks | +3,184 |

Tool sets of one agent, start tokens:

| Tool set | Start tokens |
|---|---|
| `Read` | 1,804 |
| `Read, Grep, Glob` | 3,040 |
| `Read, Grep, Glob, Edit, Write` (the `--slim` default) | 3,762 |
| `Bash, Read, Edit, Write` | 5,629 |

## Code hash speed (`code_key`)

Measured 2026-11-03, 10-call average per row, commit `9c68401` (`17d6f02` before the rebase). `code_key` is the hash that decides whether a green result is cached.

| Changed files | Before | After |
|---|---|---|
| 40 | 662 ms | 115 ms (5.7x) |
| 1 | about 100 ms | about 100 ms |

Method: before, one `sha1sum` fork per changed file. After, 2 `git` and 2 `sha1sum` calls with files hashed in chunks of 100. A green-cache hit also no longer waits for a slot in the queue. `tests/run.sh` is green.

## A batch that runs itself (`tests/e2e.sh`)

Measured 2026-11-03, one live run, Windows 10, Claude Code `claude -p` with haiku, 2 agents one after another, RAM wait on (15% free required). After `warmd split` no warmd command was typed and the session did not wait for the merge.

| Step | Result |
|---|---|
| Whole session, both agents | 48 s, `claude exit 0` |
| Agent `mulfn` (green task) | 62,931 tokens, 7 tool calls, pushed |
| Agent `brksub` (breaks a test on purpose) | 116,715 tokens, 15 tool calls, pushed |
| Automatic merge after the last stop | `mulfn` merged in 2 s, `brksub` rolled back in 2 s (`FAIL sub 9 4 gave 13`), batch ended |
| After the session | main green and clean, no lock, no `MERGE_HEAD` |

Tokens are input, cache write, cache read and output summed over every turn of the agent's transcript. The merge job starts through `Win32_Process.Create`, outside the session's process tree, so it kept running after `claude -p` exited: the session ended at 19:38:18, the merge of both branches (about 4 s) started the same second and finished on its own. 15 of 15 checks green.
