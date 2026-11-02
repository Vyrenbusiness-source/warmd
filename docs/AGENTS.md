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
- **A shared brief.** `warmd split` writes one short file that all agents of a batch read: who owns which file, plus findings. An agent adds a fact with `warmd note "price lives in src/price.ts:3"`, and the next one skips that search. It lives in the git directory, so every worktree sees the same copy and it is never committed. It keeps the newest 40 findings.
- **One-line reports.** `warmd finish` pushes and prints facts from git and the last run, so a final report costs almost nothing.

Any other model name works too, including other vendors. Tiers are config:

```ini
# warmd.conf
cheap=haiku
mid=sonnet
top=opus
top_paths=src/net/|physics/
```

