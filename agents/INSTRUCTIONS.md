## warmd

Use `warmd` for every build, test and screenshot in this project. It finds the engine or stack on its own.

- After a code change run `warmd check`. It builds and runs only the tests your change touches.
- Read outlines before files: `warmd map <file>`, then only the lines you need.
- Keep replies short: result first, no preamble, no recap. Code, paths, numbers and errors stay exact.
- Parallel work: put tasks in a file, run `warmd split <file>`, start each `AGENT` line as printed.
- Long runs go to the background. Do not poll.
