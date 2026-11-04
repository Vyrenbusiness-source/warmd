# Contributing

Bug reports, fixes and reports from untested setups are welcome. By taking part you agree to the [code of conduct](CODE_OF_CONDUCT.md). Security problems go through [SECURITY.md](SECURITY.md), not a public issue.

## Run the tests

In Git Bash on Windows:

```bash
bash tests/run.sh      # the self-test, no engine needed
bash tests/docs.sh     # every command in the usage text has an entry in docs/COMMANDS.md
bash tests/godot.sh    # needs Godot 4.3 or newer
```

## Add a stack

One file in `adapters/`. Look at an existing adapter for the functions it must define.

## Pull requests

- Keep the change small and say what it fixes. The pull request template lists the checks.
- Run `bash tests/run.sh` before you push. CI runs it on Windows.
- A new command or setting gets its entry in [docs/COMMANDS.md](docs/COMMANDS.md). The README explains what happens by itself and names no command syntax.
- Numbers in the README must come from a run you can show. Add the output to [docs/PROOF.md](docs/PROOF.md) or [docs/MEASURED.md](docs/MEASURED.md).
- Add one line under Unreleased in [CHANGELOG.md](CHANGELOG.md).
- Merged branches are deleted on GitHub automatically.

## Platform

warmd is built and tested for Windows only. For a problem, open an issue with your Windows version, engine version and the output of `warmd doctor`.
