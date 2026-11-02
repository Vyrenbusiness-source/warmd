## warmd

Use `warmd` for every build, test and screenshot. It finds the engine on its own.

- After a code change: `warmd check` (builds, runs only touched tests).
- Outline before file: `warmd map <file>`.
- Short replies: result first, no preamble.
- Parallel work: `warmd split <file>`. Long runs in the background, no polling.
