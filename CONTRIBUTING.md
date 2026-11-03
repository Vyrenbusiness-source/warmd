# Contributing

Bug reports, fixes and reports from untested platforms are welcome.

## Run the tests

```bash
bash tests/run.sh      # no engine needed
bash tests/godot.sh    # needs Godot 4.3 or newer
```

## Add a stack

One file in `adapters/`. Look at an existing adapter for the functions it must define.

## Pull requests

- Keep the change small and say what it fixes.
- Run `bash tests/run.sh` before you push. CI runs it on Windows.
- Numbers in the README must come from a run you can show. Add the output to `docs/PROOF.md`.

## Platform

warmd is built and tested for Windows only. For a problem, open an issue with your Windows version, engine version and the output of `warmd doctor`.
