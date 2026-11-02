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
- Run `bash tests/run.sh` before you push. CI runs it on Windows, Linux and macOS.
- Numbers in the README must come from a run you can show. Add the output to `docs/PROOF.md`.

## Platform reports

Unity on Linux and macOS has never been run. If you try it, open an issue with your OS, Unity version and the output of `warmd doctor`.
