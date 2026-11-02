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
