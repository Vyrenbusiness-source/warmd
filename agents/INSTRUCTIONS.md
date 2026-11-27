## warmd

Use `warmd` for every build, test and screenshot. It finds the engine on its own.

- After a code change: `warmd check` (builds, runs only touched tests).
- Outline before file: `warmd map <file>`.
- Messages to the user: at most 2 lines, result first, no preamble.
- Long runs (Unity tests, a run that waits in the queue) start in the background, then wait for the notification. Never start a second run while one runs. A queued run is no failure: never ESCALATE for it.
- Parallel work: `warmd split <file>`. No polling. Start each `AGENT` line as given; when a `FALLBACK` line follows it (the agent type is not registered in this session), start the `FALLBACK` line instead. `WAIT` tasks share a scene or a slot: split them again later.
- Something cost you time (CI wait, queue, missing tool, unclear doc, flaky test, slow command, long search)? Run `warmd note "BRAKE: <what> | ~<minutes lost> | <fix idea>"` at once.
- Models per role: `warmd models --list`, change with `warmd models --set role=model`.
- After a split, start `warmd watch` in the background. It exits 3 when an agent was idle for 5 minutes and prints one `WAKE <task>: ...` line per idle agent. Send that line's quoted message to the named agent, then start `warmd watch` again. An `OVER` line (time budget passed) comes with an `AGENT` line: stop the old agent, start the new one. Exit 4 (an `ESCALATE` or `SHIP` line, then `OPEN batch still runs`) needs you, the batch goes on: act on it, then start `warmd watch` again. Exit 0 means the batch is over.
