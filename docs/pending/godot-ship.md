### warmd package (Godot)

Export smoke. The first preset of `export_presets.cfg` is exported with `--export-release` into a temp folder.
The release build starts headless for `export_frames` frames (default 120). A crash, a non-zero exit or a load error is red.
A release build prints no GDScript error, so the same pack then runs on the editor binary (`--main-pack`): a script error is red.
Without export templates only `--export-pack` runs, and the output says so. A build for another platform is exported but not started.
Needs `run/main_scene`. Config: `export_frames=`, `export_timeout=` (600 s), `export_run_timeout=` (120 s).

### warmd shot [scene] --golden | --golden-update [--from image.png]

Godot golden shot. The shot is compared with this machine's reference in `.warmd/golden/<machine>/<scene>.png`.
The answer is text: `SAME`, or `DIFF 3.2% in region x,y,w,h`. Channels within 8 of each other count as equal.
`golden_tolerance=<percent>` (default 0.5): a smaller share of differing pixels is `SAME` and still names its share.
Only `--golden-update` makes or renews a reference; a DIFF never does. `--from` compares an image made elsewhere.
A headless engine renders nothing. Then golden is red and says to run with `WARMD_GFX=1` on a machine with a display and GPU.

### warmd doctor (Godot)

Errors: `.uid` or `.import` files not versioned, `.godot/` not ignored, Godot version not pinned, engine not the pinned version.
The pin is `godot_version=` in warmd.conf, else the version in `config/features` of project.godot.

### Godot leaks at test end

Debug builds only. A WarmdTest test or a runner that leaves orphan nodes is red with the count:
`N orphan nodes left (leak, Node.print_orphan_nodes() lists them)`. A runner in its own engine is red on `ObjectDB instance(s) leaked at exit`.
Allowlist via `godot_allow_errors`, matched against `<file>: N orphan nodes` or `<file>: leaked at exit`.

### Godot budgets at merge

These run in the merge gate, or in any `warmd check` with `WARMD_BUDGET=1`. One engine start for all of them.
- `budget_texture_px=2048`: no changed texture longer than this on its long side (after `process/size_limit` of its .import).
- `budget_texture_raw_px=512`: no changed texture longer than this stored lossless or VRAM uncompressed (`compress/mode` 0 or 3).
- `budget_<scene>=draw_calls=200,memory_mb=64,nodes=500`: `<scene>.tscn` runs `budget_frames` frames (default 60), its peaks are compared. Draw calls need a renderer: such a budget runs with graphics.
- `rendered_smoke=1`: the main scene runs with graphics (graphics slot) on every merge; a script error is red.
