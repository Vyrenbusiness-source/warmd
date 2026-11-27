### warmd state
Shows in one line whether warmd is working here: a run, merge, CI wait, a batch with its number of agents, the last result (green/red). Syntax: `warmd state [--json]`. `--json` prints `{active, what, agents, since, last, line}` for the VS Code status bar.
```text
warmd state
ACTIVE batch, 1 agents
```
VS Code extension in `vscode/`: `$(zap) warmd` idle (dim), `$(sync~spin) warmd <test|check|build|merge>` during a run, `$(organization) warmd N agents` in a batch, `$(cloud) CI` while waiting for CI, `$(pass)`/`$(error)` for 10 s after a result. The tooltip shows the state and the last line; a click runs `warmd status`. Install: `(cd vscode && npx @vscode/vsce package --skip-license) && code --install-extension vscode/warmd-*.vsix`.
