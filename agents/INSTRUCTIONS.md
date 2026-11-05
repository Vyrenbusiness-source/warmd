## warmd

Use `warmd` for every build, test and screenshot. It finds the engine on its own.

- After a code change: `warmd check` (builds, runs only touched tests).
- Outline before file: `warmd map <file>`.
- Messages to the user: at most 2 lines, result first, no preamble.
- Long runs (Unity tests, a run that waits in the queue) start in the background, then wait for the notification. Never start a second run while one runs. A queued run is no failure: never ESCALATE for it.
- Parallel work: `warmd split <file>`. No polling.
- After a split, start `warmd watch` in the background. It exits 3 when an agent was idle for 5 minutes and prints one `WAKE <task>: ...` line per idle agent. Send that line's quoted message to the named agent, then start `warmd watch` again. Exit 0 means the batch is over.
