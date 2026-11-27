### warmd sim
Runs Godot gameplay scenarios headless under a fixed tick, all in one engine start. Syntax: `warmd sim [--seed N] [file.sim|dir|name...]`. `--fixed-fps` is the number of physics ticks per second; the engine runs as fast as it can, never with `--time-scale`. One line per scenario, e.g. `FAIL jump: peak 6 > 5 at frame 16 of 200 (seed 1)` or `OK calm: peak 0 <= 1 (120 frames, seed 7)`. A scenario stops as soon as its verdict is decided.
- Scenario file `tests/sim/<name>.sim`: `scene res://x.tscn`, `seed N` (default 1), `frames N` (default 600), `isolate` (own engine), `metric <name> <max|min|last|avg|count|pct> <<=|<|>=|>|==> <limit> : <expression>` (Godot Expression on the scene root, `$Path` = node, sampled after every tick).
- Input lines: `<frame> press|release <action>`, `<frame> mouse x y`, `<frame> down|up <button> x y`.
- A script error while it runs is red with file:line. A hang or crash is red and never cached; the rest goes on in a new engine (`WARMD_SIM_TIMEOUT`).
- Verdicts are cached per scenario: code without `*.sim` + engine + scenario file + seed. `--seed N` overrides every seed and is its own key.
- Headless is not rendered: shaders, rendering, audio timing and the real mouse differ.

`warmd sim --record <scene> [--seed N] [--frames N] [--name x] [--headless]` plays the scene in a window and writes every input change per physics tick to `tests/sim/<x>.sim`. Add a metric that is red for the bug: the replay is a red scenario, then hand it to a worker.
