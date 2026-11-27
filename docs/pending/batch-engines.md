### warmd lint
Godot lints on the changed .gd, .tscn and .tres files, or the files given. ERROR lines are proven by the engine (godot/lint.gd, headless) or the file system and turn warmd check red; WARN lines are capped (WARMD_LINT_WARN, default 10). Checks Input actions, groups, autoload paths, collision layers, tr keys, res:// paths and their case, per-frame load/get_node, shared resources without duplicate(), unseeded randomness, editable children and big scenes. Syntax: `warmd lint [files...]`.

### warmd models
Model per role, shown in a window on Windows, else a prompt. Syntax: `warmd models [--list | --set role=model]`.

### warmd mutate
Flips one operator or value per changed line (< and <=, + and -, true and false, a number plus one, == and !=, -lt and -le) and runs the selected tests: every mutant must turn them red, a green one is listed as file:line. Changed lines only, test files never, the file is always restored. A line with `warmd: nomutate` is skipped. warmd.conf: `mutate_cmd=`, `mutate_limit=` (seconds, default 900), `mutate=merge` gates warmd merge. Syntax: `warmd mutate [--base REF] [--limit S] [--cmd C]`.

### warmd nightly
Everything once without the cache: cache key (MISMATCH when a fresh result differs, FLAKY when a test changes its mind), dependency graph (GAP for an engine-loaded file the static graph misses, kept in warmd-edges.tsv), and warmd mutate on the lines changed since the last night. Five-line report, also in .warmd/nightly.txt. `--schedule` prints the schtasks/cron line, `--report` the last report, `--no-mutate` skips mutation. Syntax: `warmd nightly [--schedule|--report] [--no-mutate]`.
