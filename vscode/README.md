# warmd status for VS Code

A status bar item (left) that shows when warmd works in this workspace.

| Icon | Means |
|---|---|
| `$(zap) warmd` (dim) | warmd is installed here, nothing runs |
| `$(sync~spin) warmd test` | a run is active: build, test, check, bench, shot, merge |
| `$(organization) warmd 4 agents` | a batch runs, 4 agents still work |
| `$(cloud) CI` | warmd waits for CI (`warmd ci`, `warmd ship`) |
| `$(pass)` / `$(error)` | the last test or check was green or red, shown for 10 s |

The tooltip holds the state and the last result line. A click runs `warmd status` in the output channel "warmd".

It activates when the workspace has `.warmd/` or `warmd.conf`, or when `warmd` is on PATH.

## Cost

It never starts a shell on a timer. It watches the files warmd already writes (`.warmd/run/active/`, `.warmd/run/runs.log`,
`.warmd/merge.owner`, `.warmd/ci.wait`, `<git-common-dir>/warmd-batch`) with `fs.watch`, checks their size and time every
3 s as a fallback, and runs `warmd state --json` only when one of them changed (and every 30 s while a run is shown, in case
it died without cleaning up).

## Install

```
(cd vscode && npx @vscode/vsce package --skip-license)
code --install-extension vscode/warmd-0.1.0.vsix
```

Plain JavaScript, no build step, no dependencies. Not on the marketplace.

## Settings

- `warmd.path`: the warmd script, if it is not on PATH, in `~/.local/bin` or in `~/.warmd/bin`.
- `warmd.bash`: Windows only, the bash.exe that runs warmd. Default: Git Bash.
