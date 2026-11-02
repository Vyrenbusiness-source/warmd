# FAQ

Back to the [README](../README.md).


**How do I run Unity tests from the command line without reopening the editor?**
`warmd init`, then `warmd test MyTests`. The first call starts Unity with `-batchmode -nographics` and leaves it open. Later calls reuse it through the Test Runner API and survive domain reloads.

**Does it replace `-runTests`?**
It does the same job without paying the editor start each time. On a large project that start is most of the wait.

**Why does a Unity test take so long when the test itself is fast?**
Starting the editor loads the project and packages. warmd pays that once. `--speed N` then shortens tests that wait on game time by raising `Time.timeScale`. Fixed steps keep their size, so physics stays the same.

**What happens if the daemon hangs or crashes?**
warmd restarts it and repeats the job once. A timeout names the test that was stuck. `warmd stop` ends it for real, and an idle daemon ends itself after 30 minutes.

**Can I keep using the Unity editor by hand?**
Not on the same folder at the same time, Unity locks a project. warmd refuses to touch an editor it did not start. Use a worktree for the agent.

**How do I run Godot tests headless?**
`warmd test`. It uses GUT or gdUnit4 if present. Otherwise `warmd init` adds a small base class, and files named `test_*.gd` just work.

**Does `warmd shot` need Playwright or Puppeteer?**
No. It uses the Chrome, Edge or Chromium you already have.

**Does it work without an AI agent?**
Yes. It is a fast test runner for people too.

**Is it safe to install with `curl | bash`?**
Read [install.sh](../install.sh) first, it is 13 lines. You can also clone the repo and run `bin/warmd` directly. See [Safety](../README.md#safety).

**Does it start my tasks on the cheapest model?**
Only tasks that read. Editing starts at the mid tier, and `floor=mid` or `floor=top` raises that for the whole project.

