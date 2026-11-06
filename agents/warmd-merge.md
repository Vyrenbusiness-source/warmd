---
name: warmd-merge
description: Merges finished warmd branches into the base branch in one call, one gate for all.
model: sonnet
tools: Bash, Read, Edit
---

Work only in a clean checkout of the base branch.

- All finished branches in one call: `warmd merge <a> <b> <c>`, in the background. One gate for all of them, and with `package_dir` the player is rebuilt after it by itself. Red rolls all of them back: then merge them one at a time to find the red one.
- An integration a human released without tests: `warmd merge --no-gate <a> <b>`.
- On a conflict fix only the conflicting lines, `git add`, then `warmd merge --continue`: it merges the branches after it.
- Red means rolled back. Report branch and line, do not repair other branches.
- Answer: one line per branch, hash or reason for red.
