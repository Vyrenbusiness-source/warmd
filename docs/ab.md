# A/B: the same work with and without warmd

Two small sample projects, each measured without warmd (the plain test command an agent would type) and with warmd. Windows 10, 8 cores, Git Bash, Node 24, Python 3.13, measured 2026-11-03. Everything here comes from `tests/ab/run.sh`; nothing is estimated.

| area | project | plain command |
|---|---|---|
| Web | `tests/ab/web`: Vite, Vitest with jsdom, 6 DOM components, 6 test files, 17 tests | `npm test` |
| Programming | `tests/ab/py`: Python, pytest, 5 modules, 5 test files, 13 tests | `python -m pytest` |

Each project has one real bug that a test catches: the web price formatter drops the leading zero of single-digit cents (`12.5` instead of `12.05`), the Python `split` loses the remainder cents (`[333, 333, 333]` for 1000 in 3).

## How it is measured

- **Output per test run**: bytes of what the agent reads from one red run and one green run. Plain output is taken with `NO_COLOR=1` and colour codes stripped, so the plain side is a lower bound. Tokens are real: one `claude -p` call (haiku) with a fixed frame, then one call per output inside that frame; the difference in input tokens is the output's token count.
- **Repeat run, code unchanged**: the fix is committed, one warm-up run each, then 3 timed runs each; the median is reported. warmd answers from its green cache (key: git tree plus changed files).
- **Tests after a one-file change**: one comment line appended to one source file. Plain runs everything; `warmd check` runs its build step first (web: `npm run build`, which is `vite build`; Python: `python -m compileall`) and then only the test files that reach the changed file through imports.
- **Agent A/B**: `claude -p --model haiku`, tools Bash, Read, Edit, task "one failing test, fix the source, confirm the tests pass". Arm `with` has warmd on the PATH and one sentence naming `warmd test`, `warmd check` and `warmd map`. 5 runs per arm, arms alternate, one run at a time, each run waits for at least 15 % free RAM. Each run gets a fresh copy and an empty warmd cache. A run counts as fixed when the test files are unchanged and the plain test command passes afterwards. Tokens = input + cache-new + cache-read + output, from the JSON usage; seconds and dollars are `duration_ms` and `total_cost_usd`. Spread is the sample standard deviation.

## Web (Vite, Vitest)

**Output per test run**

| run | plain bytes | warmd bytes | plain tokens | warmd tokens |
|---|---|---|---|---|
| red (1 failing test) | 1596 | 321 | 714 | 136 |
| green | 586 | 11 | 289 | 6 |

warmd prints the failing test, the assertion and the line, plus the path of the full log. The red run reads 81 % fewer tokens, the green run 98 % fewer.

**Repeat run, code unchanged**: plain `npm test` 1692 ms, `warmd test` 425 ms (cache hit, median of 3). Saves 75 %; the plain time is mostly Vitest start-up and jsdom.

**Tests after a one-file change**

| changed file | plain | warmd check | plain ms | warmd check ms |
|---|---|---|---|---|
| `src/components/badge.js` (leaf) | 6 files, 17 tests | 1 file, 3 tests | 1705 | 3822 |
| `src/components/price.js` (shared by 3 components) | 6 files, 17 tests | 3 files, 10 tests | 1723 | 3925 |

warmd check selects 18 % and 59 % of the tests. The selective path includes `vite build` and the import graph; this full suite takes under 2 s, which is faster. `warmd check` keeps the time of the last full run and of the last selective run and takes the faster path, so on this project it runs the full suite directly. Selection pays off on suites where tests cost more than the build.

**Agent A/B** (haiku, 5 runs per arm)

| side | run | input | cache-new | cache-read | output | seconds | turns | usd | fixed |
|---|---|---|---|---|---|---|---|---|---|
| without | 1 | 90 | 16940 | 140840 | 1959 | 24.7 | 11 | 0.0456 | yes |
| with | 1 | 50 | 6714 | 67287 | 1332 | 19.6 | 6 | 0.0223 | yes |
| without | 2 | 58 | 8513 | 86047 | 1210 | 18.5 | 7 | 0.0258 | yes |
| with | 2 | 74 | 7750 | 109161 | 1653 | 32.3 | 10 | 0.0294 | yes |
| without | 3 | 58 | 8715 | 85014 | 1436 | 21.6 | 7 | 0.0271 | yes |
| with | 3 | 58 | 6787 | 79724 | 1332 | 21.0 | 7 | 0.0237 | yes |
| without | 4 | 66 | 9994 | 103197 | 1638 | 22.9 | 10 | 0.0315 | yes |
| with | 4 | 50 | 6808 | 67417 | 1400 | 21.3 | 6 | 0.0228 | yes |
| without | 5 | 66 | 10653 | 107007 | 1672 | 23.5 | 11 | 0.0329 | yes |
| with | 5 | 50 | 6506 | 67049 | 1168 | 21.5 | 6 | 0.0212 | yes |

| side | tokens (mean ± sd) | output tokens | seconds | usd | turns | fixed |
|---|---|---|---|---|---|---|
| without | 117035 ± 26301 | 1583 ± 280 | 22.2 ± 2.4 | 0.0326 ± 0.0079 | 9.2 | 5/5 |
| with | 86474 ± 18796 | 1377 ± 176 | 23.1 ± 5.2 | 0.0239 ± 0.0032 | 7.0 | 5/5 |

Read: with warmd 26 % fewer tokens and 27 % lower cost per run, about 2 turns fewer, every run fixed in both arms. The token gap is a bit more than one standard deviation of either arm. Task time is equal within the spread: 23.1 s against 22.2 s, with one warmd run (run 2) at 32 s.

## Programming (Python, pytest)

**Output per test run**

| run | plain bytes | warmd bytes | plain tokens | warmd tokens |
|---|---|---|---|---|
| red (1 failing test) | 1583 | 336 | 479 | 153 |
| green | 1000 | 11 | 309 | 6 |

The red run reads 68 % fewer tokens, the green run 98 % fewer. The plain pytest header on this machine lists 4 installed plugins; a clean environment prints a little less.

**Repeat run, code unchanged**: plain `python -m pytest` 895 ms, `warmd test` 433 ms (cache hit, median of 3). Saves 52 %.

**Tests after a one-file change**

| changed file | plain | warmd check | plain ms | warmd check ms |
|---|---|---|---|---|
| `shop/parse.py` | 5 files, 13 tests | 2 files, 4 tests | 886 | 2643 |
| `shop/stock.py` | 5 files, 13 tests | 2 files, 4 tests | 893 | 2589 |

warmd check selects 31 % of the tests (the module's own tests plus `test_orders.py`, which imports both). 13 tests that finish in 0.1 s are faster than `compileall` plus the import graph, so here too `warmd check` takes the full run.

**Agent A/B** (haiku, 5 runs per arm)

| side | run | input | cache-new | cache-read | output | seconds | turns | usd | fixed |
|---|---|---|---|---|---|---|---|---|---|
| without | 1 | 50 | 8605 | 70950 | 1717 | 17.6 | 8 | 0.0269 | yes |
| with | 1 | 50 | 6705 | 67280 | 1310 | 16.2 | 6 | 0.0222 | yes |
| without | 2 | 50 | 7611 | 68193 | 1335 | 15.9 | 6 | 0.0235 | yes |
| with | 2 | 66 | 7120 | 93858 | 1617 | 22.4 | 8 | 0.0269 | yes |
| without | 3 | 66 | 8697 | 96721 | 1785 | 25.0 | 8 | 0.0300 | yes |
| with | 3 | 58 | 7016 | 80842 | 1615 | 21.1 | 7 | 0.0255 | yes |
| without | 4 | 58 | 9248 | 84543 | 1831 | 17.5 | 9 | 0.0297 | yes |
| with | 4 | 50 | 6747 | 67390 | 1410 | 17.1 | 6 | 0.0228 | yes |
| without | 5 | 74 | 8714 | 109288 | 1714 | 21.2 | 9 | 0.0309 | yes |
| with | 5 | 66 | 7220 | 93802 | 1771 | 25.5 | 8 | 0.0278 | yes |

| side | tokens (mean ± sd) | output tokens | seconds | usd | turns | fixed |
|---|---|---|---|---|---|---|
| without | 96250 ± 17763 | 1676 ± 197 | 19.4 ± 3.7 | 0.0282 ± 0.0030 | 8.0 | 5/5 |
| with | 89199 ± 13646 | 1545 ± 183 | 20.5 ± 3.8 | 0.0250 ± 0.0025 | 7.0 | 5/5 |

Read: with warmd 7 % fewer tokens and 11 % lower cost per run, one turn fewer, every run fixed in both arms. Both gaps are within one standard deviation. Task time is equal within the spread: 20.5 s against 19.4 s.

## Scope of these numbers

- Clear: warmd's test output is 68 to 98 % smaller in tokens, and an unchanged repeat run is answered from the cache in about 0.43 s.
- Clear: after a one-file change warmd check selects 18 to 59 % (web) and 31 % (Python) of the tests.
- Affected tests on these suites: the full run is faster than build plus selection, so `warmd check` runs it whole. Time gains from selection apply to suites where tests cost more than the build; the game numbers in [MEASURED.md](MEASURED.md) show the engine-start side.
- Agent level: tokens and cost fall in both areas (26 % and 7 % tokens, 27 % and 11 % cost), task time is equal within the spread. Five runs per arm on small bug fixes; the web gap is larger than one standard deviation, the Python gap within one. Per-run savings grow with the length of the test output, which these small samples keep short.

## Reproduce

```bash
bash tests/ab/run.sh measure web      # output bytes, repeat time, affected tests; no model calls
bash tests/ab/run.sh tokens web       # 5 one-turn haiku calls, real token counts of the outputs
bash tests/ab/run.sh agent web 5 haiku   # 10 agent runs, one after another, about 4 minutes and 0.30 usd
# the same with py
```

`AB_OUT=<dir>` keeps the raw outputs and TSV files, `AB_FREE_PCT` sets the RAM floor (default 15 %). The sample projects are `tests/ab/web` (run `npm install` once to try it by hand) and `tests/ab/py`.
