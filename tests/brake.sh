#!/usr/bin/env bash
# warmd brake / brakes: the machine-wide brake log. warmd note "BRAKE: ..." lands there too, brakes ranks causes by
# minutes lost, report and finish show the batch's brake minutes in one line. No engine.
set -u
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP="$(mktemp -d)"
export XDG_CACHE_HOME="$TMP/cache"
fails=0
ok() { echo "ok   $1"; }
no() { echo "FAIL $1"; fails=$((fails+1)); }
expect() { if echo "$3" | grep -qE "$2"; then ok "$1"; else no "$1: wanted /$2/, got: $(echo "$3" | head -3)"; fi; }
w() { "$HERE/bin/warmd" "$@" 2>&1; }
LOG="$TMP/cache/warmd/brakes.tsv"

mkdir -p "$TMP/proj"; cd "$TMP/proj" || exit 1
git init -q -b main .; git config user.name t; git config user.email t@example.com
echo x > a.txt; git add a.txt; git commit -qm init; git checkout -qb warmd/lint

expect "brake records a row" '^OK brake recorded' "$(w brake "CI wait for godot" 11 "cache the godot download")"
row="$(tail -n 1 "$LOG" 2>/dev/null)"
expect "row holds project, task, cause, minutes, fix" $'^[0-9]+\tproj\tlint\tCI wait for godot\t11\tcache the godot download$' "$row"
w brake "ci wait for Godot!" "~4 min" >/dev/null
expect "brake without a cause is refused" 'warmd brake "<what>"' "$(w brake "")"

# A BRAKE note goes to the brief and the log, once; without a brief it still lands in the log
common="$(git rev-parse --path-format=absolute --git-common-dir)"
printf '# Shared brief\n\n## Findings\n' > "$common/warmd-shared.md"
out="$(w note "BRAKE: PR conflicted with main | ~3 | merge base before push")"
expect "a BRAKE note is noted in the brief" '^OK noted' "$out"
expect "a BRAKE note lands in the log" $'\tPR conflicted with main\t3\tmerge base before push$' "$(tail -n 1 "$LOG")"
w note "BRAKE: PR conflicted with main | ~3 | merge base before push" >/dev/null
expect "a repeated note is not counted twice" '^1$' "$(grep -c 'PR conflicted' "$LOG")"
w note "plain fact lib/x.sh:3" >/dev/null
expect "a plain note stays out of the log" '^0$' "$(grep -c 'plain fact' "$LOG")"
rm -f "$common/warmd-shared.md"
expect "a BRAKE note without a brief is still recorded" '^OK brake recorded' "$(w note "BRAKE: python stub hung | ~2 | doctor flags it")"

# Ranking: same words in any case or punctuation are one group, ranked by total minutes
out="$(w brakes)"
expect "brakes sums all minutes" '^20 min lost in 4 brakes' "$out"
expect "the top cause groups case and punctuation" '^  15 min  2x  CI wait for godot \(lint\)  fix: cache the godot download' "$(echo "$out" | sed -n 2p)"
expect "the next cause follows" '^   3 min  1x  PR conflicted with main' "$(echo "$out" | sed -n 3p)"
printf '946684800\tproj\told\tancient brake\t99\t-\n' >> "$LOG"
expect "--days leaves old rows out" '^20 min lost' "$(w brakes --days 7)"
expect "without --days old rows count" '^119 min lost' "$(w brakes)"
for i in 1 2 3 4 5 6 7 8 9 10 11; do printf '%s\tproj\tt\tcause number %s %s\t1\t-\n' "$(date +%s)" "$i" "$(printf '%*s' "$i" '' | tr ' ' x)" >> "$LOG"; done
expect "brakes prints the top 10 only" '^11$' "$(w brakes | wc -l | tr -d ' ')"
expect "a bad --days is refused" '^FAIL --days takes a number' "$(w brakes --days x)"

# report shows the brake minutes of the batch, in one line
printf '%s\tlint\tmid\tlib\t100\t5\t60\tok\n' "$(date +%s)" > "$common/warmd-ledger.tsv"
: > "$common/warmd-batch"; touch -d "1 hour ago" "$common/warmd-batch"
expect "report shows the batch brake minutes" '^brakes: 31 min in 15 entries this batch' "$(w report | tail -n 1)"
expect "finish shows the task and batch brake minutes" "brakes: lint 20 min, 31 min in 15 entries this batch" "$(WARMD_BASE=1 w finish | grep "^brakes:")"
rm -f "$common/warmd-batch"


# The PreToolUse hook stops python calls that hang on Windows: the Store stub, python reading a stdin nobody closes,
# a Git Bash /tmp path inside python code. Commands are plain JSON strings here, no python needed to build them.
mkdir -p "$TMP/WindowsApps"; printf '#!/bin/sh\nexit 9\n' > "$TMP/WindowsApps/python3"; chmod +x "$TMP/WindowsApps/python3"
hk() { printf '{"session_id":"b1","transcript_path":"%s/none.jsonl","cwd":"%s","hook_event_name":"PreToolUse","tool_name":"Bash","tool_input":{"command":"%s"}}' "$TMP" "$TMP" "$1" \
  | PATH="$TMP/WindowsApps:$PATH" WARMD_TEST_WIN=1 "$HERE/bin/warmd" hook-pre 2>&1; }
expect "hook denies the Windows Store python stub" 'deny.*python3 is the Windows Store stub' "$(hk 'python3 x.py')"
expect "hook denies python - with no input" 'deny.*reads stdin' "$(hk 'cd /x && python - 2>/dev/null; ls')"
expect "hook denies a Git Bash /tmp path in python code" 'deny.*does not see the Git Bash /tmp' "$(hk "python -c \\\"open('/tmp/a')\\\"")"
expect "hook leaves python with a script alone" '^$' "$(hk 'python x.py')"
expect "hook leaves python fed by a pipe alone" '^$' "$(hk 'cat a.py | python -')"
expect "doctor flags the Windows Store python stub" "WARN python3 is the Windows Store stub" "$(PATH="$TMP/WindowsApps:$PATH" "$HERE/bin/warmd" doctor)"


# finish merges a clean origin/<base> before its push and names a conflict at once: a conflicting PR runs no CI
cfg() { git config user.name t; git config user.email t@example.com; git config core.autocrlf false; }
git init -q --bare -b main "$TMP/r.git"; git clone -q "$TMP/r.git" "$TMP/c" 2>/dev/null; cd "$TMP/c" || exit 1; cfg
echo a > f.txt; git add f.txt; git commit -qm a; git push -q origin main
git checkout -qb warmd/t; echo t > t.txt; git add t.txt; git commit -qm t
git checkout -q main; echo b > g.txt; git add g.txt; git commit -qm b; git push -q origin main; git checkout -q warmd/t
out="$(w finish)"
expect "finish merges a clean origin/main first" '^\(merged origin/main first' "$out"
git merge-base --is-ancestor origin/main HEAD && ok "the pushed branch holds origin/main" || no "the pushed branch lacks origin/main"
git checkout -q main; echo X > f.txt; git commit -qam x; git push -q origin main; git checkout -q warmd/t
echo Y > f.txt; git commit -qam y
expect "finish names a conflict with main at once" '^CONFLICT with main: CI will not run' "$(w finish)"

# warmd ci: a conflicting PR fails at once instead of waiting for a run that never starts
mkdir -p "$TMP/gh"; cat > "$TMP/gh/gh" <<'GH'
#!/bin/sh
case "$1 $2" in "pr view") echo "CONFLICTING main";; "pr list") echo 5;; esac
GH
chmod +x "$TMP/gh/gh"
out="$(PATH="$TMP/gh:$PATH" WARMD_CI_POLL=0 WARMD_CI_TRIES=2 w ci warmd/t)"
expect "warmd ci names a conflicting PR" '^CONFLICT with main: CI will not run on the PR of warmd/t' "$out"

# ship moves docs/pending/<task>.md entries into docs/COMMANDS.md and removes them
mkdir -p docs/pending; printf '# Commands\n\n### warmd a\nA.\n' > docs/COMMANDS.md; printf '### warmd b\nB.\n' > docs/pending/t.md
git add docs; git commit -qm docs
out="$(bash -c "reg() { :; }; . '$HERE/lib/ship.sh'; ship_docs_pending" 2>&1)"
expect "ship merges a pending docs entry" '^ok   docs: 1 pending entries merged' "$out"
expect "the entry is in COMMANDS.md" '^### warmd b$' "$(grep '^### warmd b' docs/COMMANDS.md)"
[ ! -e docs/pending/t.md ] && [ -z "$(git status --porcelain)" ] && ok "the pending file is gone, committed" || no "pending file left or tree dirty: $(git status --porcelain)"


# affected_select reads the extra edges warmd nightly proved with the engine (warmd-edges.tsv in the common git dir)
d="$TMP/aff"; mkdir -p "$d"; cp -R "$HERE/tests/fixtures/affected/js/." "$d/"
( cd "$d" && git init -q -b main . && git config core.autocrlf false && git config user.name t && git config user.email t@example.com && git add -A && git commit -qm init )
echo '// edit' >> "$d/src/other.ts"
sel() { ( cd "$d" && WARMD_HOME="$HERE" && . "$HERE/lib/platform.sh" && . "$HERE/lib/core.sh" && detect_project && . "$HERE/lib/affected.sh" && WARMD_SELECT=1 affected_select js && echo "$AFF_MODE|$AFF_FILES" ) 2>/dev/null; }
expect "without extra edges other.ts selects its own test only" '^SOME\|test/other\.test\.ts$' "$(sel)"
printf 'E\ttest/top.test.ts\tsrc/other.ts\n' > "$d/.git/warmd-edges.tsv"
expect "an engine-proven edge selects the test that loads the file" '^SOME\|.*test/top\.test\.ts' "$(sel)"


# warmd merge with mutate=merge: a changed line no test notices turns the merge red and rolls it back
mkdir -p "$TMP/mg"; cd "$TMP/mg" || exit 1; git init -q -b main .; cfg
printf 'gate=true\nmutate=merge\nmutate_cmd=true\nmutate_limit=60\n' > warmd.conf; printf '.warmd\n' > .gitignore
mkdir -p lib; printf 'f() {\n  echo start\n}\n' > lib/a.sh; git add -A; git commit -qm init
git checkout -qb warmd/m; printf 'f() {\n  [ 1 -lt 2 ] && echo yes\n}\n' > lib/a.sh; git commit -qam m; git checkout -q main
before="$(git rev-parse HEAD)"
out="$(WARMD_BASE=1 w merge warmd/m)"
expect "the mutation gate turns a merge red" '^FAIL merge warmd/m: mutation gate' "$out"
[ "$(git rev-parse HEAD)" = "$before" ] && ok "the red merge is rolled back" || no "the red merge stayed: $(git log --oneline -1)"


# A restart's AGENT line takes role_worker / role_scout from warmd.conf like split does, not only cheap/mid/top
mkdir -p "$TMP/ral/tasks" "$TMP/ral/common"; : > "$TMP/ral/tasks/x.md"; echo mid > "$TMP/ral/tasks/x.tier"
al() { printf '%s\n' "$@" > "$TMP/ral/warmd.conf"; ( WARMD_HOME="$HERE"; . "$HERE/lib/platform.sh"; . "$HERE/lib/auto.sh"; . "$HERE/lib/hook.sh"; HOOK_PROJ="$TMP/ral"; hook_agent_line "$TMP/ral/common" "$TMP/ral/tasks/x.md" ) 2>&1; }
expect "restart line uses role_worker" 'model=opus ' "$(al 'role_worker=claude:opus')"
expect "restart line keeps the tier model over a weaker role" 'model=sonnet ' "$(al 'role_worker=haiku')"
expect "restart line still reads the tier key" 'model=claude-x ' "$(al 'mid=claude-x')"


# cost_limit_day is enforced: warmd split refuses new tasks once today's ledger estimate reached it
mkdir -p "$TMP/cl"; cd "$TMP/cl" || exit 1; git init -q -b main .; cfg
printf 'mid=sonnet\ncost_limit_day=1\n' > warmd.conf; printf '.warmd\n' > .gitignore; git add -A; git commit -qm init
printf '%s\tt\tmid\tlib\t1000000\t5\t60\tok\n' "$(date +%s)" > .git/warmd-ledger.tsv
printf '# nothing\n' > tasks.txt
expect "split stops at the daily cost limit" '^FAIL daily cost limit reached: about \$2\.00 spent today' "$(w split tasks.txt)"
expect "WARMD_COST_LIMIT=off lets one split through" '^$' "$(WARMD_COST_LIMIT=off w split tasks.txt | grep 'daily cost limit')"


# ship joins two branches' new suite steps in one ci.yml job instead of stopping at the conflict
printf '    steps:\n<<<<<<< HEAD\n      - run: bash tests/nightly.sh\n=======\n      - run: bash tests/godot_lint.sh\n>>>>>>> b\n' > "$TMP/ci.yml"
bash -c "reg() { :; }; . '$HERE/lib/ship.sh'; ship_union '$TMP/ci.yml'" && ok "ship_union resolves two ci.yml suite steps" || no "ship_union refused two ci.yml suite steps"
expect "both steps are kept, ours first" '^nightly godot_lint$' "$(grep -o 'tests/[a-z_]*' "$TMP/ci.yml" | sed 's#tests/##' | paste -sd' ' -)"
printf '<<<<<<< HEAD\n          - a b\n=======\n          - a c\n>>>>>>> b\n' > "$TMP/ci2.yml"
bash -c "reg() { :; }; . '$HERE/lib/ship.sh'; ship_union '$TMP/ci2.yml'" && no "ship_union joined matrix group lines" || ok "ship_union leaves matrix group lines to a person"


# split never hands a worktree of an unfinished task to another task (the brakes task got godot-sim's worktree)
mkdir -p "$TMP/sp/p"; cd "$TMP/sp/p" || exit 1; git init -q -b main .; cfg
printf '.warmd\n' > .gitignore; echo x > x.txt; git add -A; git commit -qm init
mkdir -p .warmd/tasks; : > .warmd/tasks/a.md
git worktree add -q -b warmd/a "$TMP/sp/.warmd-worktrees/p/b" HEAD; echo wip > "$TMP/sp/.warmd-worktrees/p/b/new.txt"
printf 'b | goal b | check | y.txt\n' > tasks.txt
out="$(w split tasks.txt)"
expect "the owned worktree keeps its task's branch" '^warmd/a$' "$(git -C "$TMP/sp/.warmd-worktrees/p/b" branch --show-current)"
expect "the new task gets a folder of its own" 'still owned: using b-[0-9]+' "$out"
w batch-done >/dev/null

rm -rf "$TMP" 2>/dev/null
echo; [ $fails = 0 ] && echo "brake: all green" || echo "brake: $fails failed"
exit $fails
