# A/B: same task with and without warmd

Measured 2026-11-03 with `bash tests/ab/run.sh 2 haiku`. Task: a small Node project (`tests/ab/sample`) with one failing test; fix the source. Arm `with` has `warmd` on the PATH and a one-line hint to use `warmd test` and `warmd map`. Numbers come from `claude -p --output-format json` (tokens, `duration_ms`, `total_cost_usd`). Nothing is estimated.

| side | run | input | cache-new | cache-read | output | seconds | turns | usd | fixed |
|---|---|---|---|---|---|---|---|---|---|
| without | 1 | 58 | 14075 | 73885 | 1388 | 16.1 | 10 | 0.0324 | yes |
| with | 1 | 58 | 6803 | 79016 | 1193 | 14.3 | 7 | 0.0229 | yes |
| without | 2 | 74 | 7320 | 103518 | 1292 | 15.8 | 9 | 0.0265 | yes |
| with | 2 | 66 | 6714 | 90406 | 1326 | 15.6 | 8 | 0.0246 | yes |

Mean per run (tokens = input + cache-new + cache-read + output):

| side | runs | tokens | output | seconds | usd | fixed |
|---|---|---|---|---|---|---|
| without | 2 | 100805 | 1340 | 16.0 | 0.0294 | 2/2 |
| with | 2 | 92791 | 1260 | 14.9 | 0.0238 | 2/2 |

Read: with warmd about 8% fewer tokens, 7% less time, 19% less cost. Two runs per arm on a tiny task: a direction, not a proof. Run more with `tests/ab/run.sh 5 haiku`.
