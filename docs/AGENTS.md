# Cheap models first

Back to the [README](../README.md).


Most agent tasks do not need your best model. warmd starts each one on the cheapest tier that fits and moves up only after a real failure.

```text
# tasks.txt: name | goal | done check | files
footer | add a footer to the landing page | warmd check passes | src/footer.css
sync   | find the root cause of the desync | test Net_Sync green | src/net/sync.ts
unused | list unused CSS classes | list of file:line | none
```

```console
$ warmd split tasks.txt
AGENT footer: subagent_type=warmd-worker model=sonnet prompt="Read .warmd/tasks/footer.md and do it."
AGENT sync: subagent_type=warmd-worker model=opus prompt="Read .warmd/tasks/sync.md and do it."
AGENT unused: subagent_type=warmd-scout model=haiku prompt="Read .warmd/tasks/unused.md and do it."
OK 3 tasks split
```

- **Clean split.** Each editing task gets its own git worktree. A finished worktree is reused, so its `Library`, `.godot` or `node_modules` stays warm, otherwise they are seeded. If two tasks claim one file, the batch is refused before anything is created.
- **Stays current by itself.** Tiers map to the aliases `haiku`, `sonnet` and `opus`, which always point to the newest release. When a new model ships there is nothing to change.
- **Cheap first, then up.** An agent stops after two failed fixes. `warmd escalate <name>` hands the same task to the next tier, with the earlier commits as context.
- **It learns.** An area that needed escalation twice starts one tier higher next time.
- **Wake loop.** `warmd watch` runs in the background after a split. An agent counts as active when a file or commit changed, a warmd run (test, check, build, merge) holds its worktree, or a process runs inside it. After 5 idle minutes (`warmd watch <minutes>` changes it) it prints one line per idle agent, `WAKE <task>: idle N min in <path>. Send to the <task> agent: "..."`, and exits 3. The session sends that message (state and next step, or `warmd handoff`) and starts the watch again. A fresh batch never alarms in its first minutes.
- **A shared brief.** `warmd split` writes one short file that all agents of a batch read: who owns which file, plus findings. An agent adds a fact with `warmd note "price lives in src/price.ts:3"`, and the next one skips that search. It lives in the git directory, so every worktree sees the same copy and it is never committed. It keeps the newest 40 findings.
- **Cancel one task.** `warmd drop <task> "reason" [--delete]` takes a task the user no longer wants out of the batch: watch stops waking it, automerge stops waiting for it, it is recorded as dropped, not failed. `--delete` also removes its worktree and branch, but refuses while it has unmerged commits or uncommitted files.
- **One-line reports.** `warmd finish` pushes and prints facts from git and the last run, so a final report costs almost nothing.

Any other model name works too, including other vendors. Tiers are config:

```ini
# warmd.conf
cheap=haiku
mid=sonnet
top=opus
top_paths=src/net/|physics/
```

