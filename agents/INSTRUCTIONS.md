## warmd

Use `warmd` for every build, test and screenshot. It finds the engine on its own.

- After a code change: `warmd check` (builds, runs only touched tests).
- Outline before file: `warmd map <file>`.
- Short replies: result first, no preamble.
- Parallel work: `warmd split <file>`. Long runs in the background, no polling.
- After a split, start `warmd watch` in the background. It exits 3 when an agent was idle for 5 minutes and prints one `WAKE <task>: ...` line per idle agent. Send that line's quoted message to the named agent, then start `warmd watch` again. Exit 0 means the batch is over.
