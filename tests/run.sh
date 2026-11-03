#!/usr/bin/env bash
# Self-test on throwaway projects. No engine needed. Runs on Linux, macOS and Git Bash.
set -u
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WARMD="$HERE/bin/warmd"
TMP="$(mktemp -d)"
export XDG_CACHE_HOME="$TMP/cache"
fails=0
ok() { echo "ok   $1"; }
no() { echo "FAIL $1"; fails=$((fails+1)); }
expect() { # name expected-regex actual
  if echo "$3" | grep -qE "$2"; then ok "$1"; else no "$1: wanted /$2/, got: $(echo "$3" | head -3)"; fi
}

new_repo() {
  mkdir -p "$TMP/$1"; cd "$TMP/$1" || exit 1
  git init -q -b main .; git config user.name t; git config user.email t@example.com
}

# ---- detection ----
for pair in "unity:ProjectSettings/ProjectVersion.txt" "godot:project.godot" "web:index.html" "web:package.json" "rust:Cargo.toml" "go:go.mod" "python:pyproject.toml"; do
  kind="${pair%%:*}"; marker="${pair#*:}"
  d="$TMP/detect-$kind-$(echo "$marker" | tr -c 'a-z' '_')"; mkdir -p "$d/$(dirname "$marker")" "$d/sub"; echo 'm_EditorVersion: 6000.0.0f1' > "$d/$marker"
  expect "detect $kind from $marker" "$kind project" "$(cd "$d" && "$WARMD" status)"
  expect "detect $kind from a subfolder" "$kind project" "$(cd "$d/sub" && "$WARMD" status)"
done
mkdir -p "$TMP/mono/game"; git -C "$TMP/mono" init -q; echo x > "$TMP/mono/game/project.godot"
expect "detect a project one level below the git root" "godot project" "$(cd "$TMP/mono" && "$WARMD" status)"

mkdir -p "$TMP/cs"; echo x > "$TMP/cs/App.csproj"
expect "one csproj alone is a dotnet project" 'dotnet project' "$(cd "$TMP/cs" && "$WARMD" status)"

# ---- build, test, cache ----
new_repo app
cat > package.json <<'EOF'
{ "name": "t", "scripts": { "test": "node test.js", "build": "node build.js" } }
EOF
echo 'console.log("built")' > build.js
echo 'require("fs").appendFileSync("runs.txt","x"); console.log("1 passed")' > test.js
printf 'runs.txt\n.warmd\n' > .gitignore
git add -A; git commit -qm init
expect "build is one line" '^OK [0-9]+s build$' "$("$WARMD" build)"
expect "first test runs" '^OK [0-9]+s test$' "$("$WARMD" test)"
expect "second test comes from the cache" 'cached, code unchanged' "$("$WARMD" test)"
[ "$(wc -c < runs.txt | tr -d ' ')" = 1 ] && ok "cached run did not execute" || no "cached run executed"
echo '// edit' >> test.js
expect "an edit invalidates the cache" '^OK [0-9]+s test$' "$("$WARMD" test)"

for i in $(seq 1 200); do echo "console.log('noise $i')"; done > test.js
echo 'console.error("Error: boom at line 7"); process.exit(1)' >> test.js
out="$("$WARMD" test)"; rc=$?
[ "$rc" != 0 ] && ok "red exits non-zero" || no "red exited zero"
expect "red shows the error line" 'Error: boom at line 7' "$out"
[ "$(echo "$out" | wc -l | tr -d ' ')" -le 15 ] && ok "red output stays under 15 lines" || no "red output has $(echo "$out" | wc -l) lines"
expect "red is not cached" '^FAIL' "$("$WARMD" test)"
git checkout -q test.js

expect "bench reports the three timings" 'cached +[0-9]+ ms' "$("$WARMD" bench)"

out="$("$WARMD" feedback)"
expect "feedback only prints a link" 'issues/new\?title=Feedback' "$out"
expect "feedback shows the text first" 'nothing is sent' "$out"
if echo "$out" | grep -q "$TMP"; then no "feedback leaks a local path"; else ok "feedback holds no local path"; fi

# ---- queue ----
mkdir -p "$XDG_CACHE_HOME/warmd/slots"
cat > warmd.conf <<'EOF'
slots=1
EOF
mkdir -p "$XDG_CACHE_HOME/warmd/slots/1"; echo 999999 > "$XDG_CACHE_HOME/warmd/slots/1/pid"
echo '// x' >> test.js
expect "a dead slot owner expires" 'OK [0-9]+s test' "$("$WARMD" test)"
[ -z "$(ls "$XDG_CACHE_HOME/warmd/slots" | grep -v '^$')" ] && ok "slot released on exit" || no "slot left behind"
rm warmd.conf; git checkout -q test.js

# ---- guards ----
sleep 60 & holder=$!
mkdir -p .warmd; echo "$holder" > .warmd/merge.owner
out="$("$WARMD" test 2>&1)"; rc=$?
expect "tests are refused during someone else's merge" 'merge is running' "$out"
[ "$rc" = 4 ] && ok "refusal has its own exit code" || no "refusal exited $rc"
expect "the merge's own checks still run" 'OK' "$(WARMD_IN_MERGE=1 "$WARMD" test 2>&1)"
kill "$holder" 2>/dev/null; wait "$holder" 2>/dev/null
expect "a dead merge owner expires" 'OK' "$("$WARMD" test 2>&1)"
[ ! -f .warmd/merge.owner ] && ok "stale merge marker removed" || no "stale merge marker stayed"

mkdir -p "$XDG_CACHE_HOME/warmd/slots/1" "$XDG_CACHE_HOME/warmd/slots/2"
sleep 30 & h1=$!; sleep 30 & h2=$!
echo "$h1" > "$XDG_CACHE_HOME/warmd/slots/1/pid"; echo "$h2" > "$XDG_CACHE_HOME/warmd/slots/2/pid"
printf 'slots=2\n' > warmd.conf; echo '// orphan' >> test.js
# The caller dies while the run waits for a slot: it has to end by itself and free nothing it does not own
( bash "$WARMD" test > "$XDG_CACHE_HOME/orphan.out" 2>&1 & echo $! > "$XDG_CACHE_HOME/orphan.pid"; sleep 2 ) &
sub=$!; wait "$sub" 2>/dev/null
i=0; while kill -0 "$(cat "$XDG_CACHE_HOME/orphan.pid")" 2>/dev/null && [ $i -lt 20 ]; do sleep 1; i=$((i+1)); done
expect "a run without caller ends by itself" 'caller is gone' "$(cat "$XDG_CACHE_HOME/orphan.out")"
kill "$h1" "$h2" 2>/dev/null; wait "$h1" "$h2" 2>/dev/null
rm -rf "$XDG_CACHE_HOME/warmd/slots"/* warmd.conf; git checkout -q test.js

# ---- routing ----
expect "no files means the cheap tier" '^cheap model=haiku' "$("$WARMD" route 'list all TODOs')"
expect "plain edit means the mid tier" '^mid model=sonnet' "$("$WARMD" route 'add a footer' src/footer.css)"
expect "hard words mean the top tier" '^top model=opus' "$("$WARMD" route 'find root cause of the crash' src/a.ts)"
printf 'mid=sonnet-next\ntop_paths=src/net/\n' > warmd.conf
expect "new models are one config line" '^mid model=sonnet-next' "$("$WARMD" route 'add a footer' src/footer.css)"
expect "paths can force the top tier" '^top' "$("$WARMD" route 'tidy' src/net/sync.ts)"
rm warmd.conf

printf 'floor=mid\n' > warmd.conf
expect "floor keeps read-only work off the cheap tier" '^mid' "$("$WARMD" route 'list all TODOs')"
printf 'floor=top\n' > warmd.conf
expect "floor top sends everything to the top tier" '^top' "$("$WARMD" route 'add a footer' src/footer.css)"
rm warmd.conf

# ---- split, escalate, finish ----
cat > tasks.txt <<'EOF'
# name | goal | done check | files
footer | add a footer | warmd test passes | src/footer.css
search | list unused css | list of 5 | none
EOF
out="$("$WARMD" split tasks.txt)"
expect "split routes the edit to the mid tier" 'AGENT footer: subagent_type=warmd-worker model=sonnet' "$out"
expect "split routes the search to the scout" 'AGENT search: subagent_type=warmd-scout model=haiku' "$out"
expect "split makes a worktree" 'warmd/footer' "$(git worktree list)"
expect "watch sees moving worktrees" 'OK all worktrees moved' "$("$WARMD" watch --once 15)"
wtw="$(dirname "$PWD")/.warmd-worktrees/app/footer"
find "$wtw" -type f -not -path '*/.git/*' -exec touch -d '2 hours ago' {} +
GIT_COMMITTER_DATE='2020-01-01T00:00:00' git -C "$wtw" commit -q --allow-empty --date='2020-01-01T00:00:00' -m old
expect "watch gives a fresh batch time" 'OK all worktrees moved' "$("$WARMD" watch --once 15)"
touch -d '2 hours ago' "$(git rev-parse --path-format=absolute --git-common-dir)/warmd-batch"
out="$("$WARMD" watch --once 15)"; rc=$?
expect "watch reports a stalled agent" 'STALLED .*footer' "$out"
[ "$rc" = 3 ] && ok "a stall ends watch with its own exit code" || no "stall exited $rc"
out="$("$WARMD" test 2>&1)"; rc=$?
expect "the shared checkout refuses runs during a batch" 'batch runs' "$out"
[ "$rc" = 5 ] && ok "batch refusal has its own exit code" || no "batch refusal exited $rc"
expect "a deliberate run in the base passes" 'OK' "$(WARMD_BASE=1 "$WARMD" test 2>&1)"
expect "a worktree of the batch passes" 'OK' "$(cd "$(dirname "$PWD")/.warmd-worktrees/app/footer" && "$WARMD" test 2>&1)"
expect "batch-done opens the checkout" 'OK batch ended' "$("$WARMD" batch-done)"
shared="$(git rev-parse --path-format=absolute --git-common-dir)/warmd-shared.md"
expect "the shared brief lists owners" 'footer: src/footer.css' "$(cat "$shared")"
expect "a task starts with its own worktree" 'First run: cd' "$(cat .warmd/tasks/footer.md)"
expect "a task points to the shared brief" 'Shared brief:' "$(cat .warmd/tasks/footer.md)"
expect "a note goes into the brief" 'OK noted' "$("$WARMD" note 'price lives in src/price.ts:3')"
expect "the same note is not added twice" 'already noted' "$("$WARMD" note 'price lives in src/price.ts:3')"
expect "a worktree sees the same brief" 'price lives' "$(cat "$(git -C "$(git worktree list --porcelain | sed -n 's/^worktree //p' | grep footer)" rev-parse --path-format=absolute --git-common-dir)/warmd-shared.md")"
for i in $(seq 1 45); do "$WARMD" note "fact $i" > /dev/null; done
[ "$(sed -n '/^## Findings/,$p' "$shared" | wc -l | tr -d ' ')" -le 41 ] && ok "the brief keeps 40 findings" || no "the brief keeps growing"
expect "long notes are refused" 'over 160' "$("$WARMD" note "$(printf 'x%.0s' $(seq 1 170))")"
expect "escalate moves up one tier" 'AGENT footer: subagent_type=warmd-worker model=opus' "$("$WARMD" escalate footer)"
expect "top tier cannot escalate" 'needs a human' "$("$WARMD" escalate footer)"
printf 'p1 | x | y | src/p1.ts\np2 | x | y | src/p2.ts\np3 | x | y | src/p3.ts\n' > three.txt
"$WARMD" split three.txt > /dev/null
n="$(sed -n 's/^Task [a-z0-9]*\. First run: cd "\([^"]*\)".*/\1/p' .warmd/tasks/p1.md .warmd/tasks/p2.md .warmd/tasks/p3.md | sort -u | wc -l | tr -d ' ')"
[ "$n" = 3 ] && ok "a batch gets one worktree per task" || no "three tasks share $n worktrees"
printf 'a | x | y | src/same.ts\nb | x | y | src/same.ts\n' > clash.txt
out="$("$WARMD" split clash.txt)"
expect "split refuses two owners of a file" 'already owned' "$out"
[ ! -d "$(dirname "$PWD")/.warmd-worktrees/app/a" ] && ok "a refused batch creates nothing" || no "refused batch created a worktree"
expect "a task names the handoff rule" 'warmd handoff footer' "$(cat .warmd/tasks/footer.md)"
wtf="$(dirname "$PWD")/.warmd-worktrees/app/footer"
echo x > "$wtf/open.txt"; git -C "$wtf" add open.txt
expect "handoff refuses uncommitted work" 'commit your work first' "$(cd "$wtf" && "$WARMD" handoff footer 'parser done' 'write tests')"
git -C "$wtf" commit -qm wip
out="$(cd "$wtf" && "$WARMD" handoff footer 'parser done' 'write tests')"
expect "handoff prints the line for a fresh agent" 'AGENT footer:.*continue from there' "$out"
note="$(git rev-parse --path-format=absolute --git-common-dir)/warmd-handoff/footer.md"
expect "the note holds done and next" 'Next: write tests' "$(cat "$note")"
expect "the note lists the commits" 'wip' "$(cat "$note")"
(cd "$wtf" && "$WARMD" handoff footer a b && "$WARMD" handoff footer c d) > /dev/null
expect "a fourth handoff asks for a split instead" 'handed off 3 times' "$(cd "$wtf" && "$WARMD" handoff footer e f)"
expect "finish reports facts in one line" '^DONE main [0-9a-f]+' "$("$WARMD" finish)"
expect "board lists worktrees" 'warmd/footer' "$("$WARMD" board)"

git worktree add -q -b warmd/done "$(dirname "$PWD")/wt-done" HEAD 2>/dev/null
mkdir "$(dirname "$PWD")/wt-done/node_modules"
printf 'again | second task | warmd test passes | src/two.css\n' > again.txt
git add -A; git commit -qm tasks
git -C "$(dirname "$PWD")/wt-done" merge -q --ff-only main 2>/dev/null
out="$("$WARMD" split again.txt)"
expect "a finished worktree is reused instead of copied" 'wt-done' "$(cat .warmd/tasks/again.md)"

# ---- map ----
cat > app.ts <<'EOF'
export function alpha() {}
const beta = 1;
EOF
expect "map shows line numbers" '^1 export function alpha' "$("$WARMD" map app.ts | sed -n 2p)"

cat > Ship.cs <<'EOF'
public class Ship
{
    public void Sail(int speed)
    {
    }

    int[] Crew() { return null; }
}
EOF
out="$("$WARMD" map Ship)"
expect "map finds C# methods" '3 public void Sail' "$out"
expect "map finds array return types" 'int\[\] Crew' "$out"
expect "map skips meta files" '^== Ship.cs$' "$(echo "$out" | head -1)"
rm Ship.cs
printf 'x%.0s' $(seq 1 9000) > CLAUDE.md
expect "audit names what is loaded on every turn" 'every turn.*CLAUDE.md' "$("$WARMD" audit)"
rm CLAUDE.md

# ---- merge rolls back on red ----
git add -A; git commit -qm more
git checkout -qb bad
echo 'process.exit(1)' > test.js; git commit -qam bad
git checkout -q main
echo 'console.log("ok")' > test.js; git commit -qam good
sed -i.bak 's/node build.js/node test.js/' package.json; rm package.json.bak; git commit -qam gate
out="$("$WARMD" merge bad 2>&1)"
head_sha="$(git log -1 --format=%s)"
if echo "$out" | grep -qE 'FAIL'; then ok "red merge is refused"; else no "red merge passed: $out"; fi
[ "$head_sha" = gate ] && ok "red merge left the base untouched" || no "base moved to $head_sha"

for t in ledger digest affected perf tune layout docs; do
  # The perf test needs a headless Chrome run that does not work on the hosted Windows runner yet
  if { [ "$t" = perf ] || [ "$t" = layout ]; } && [ "${CI:-}" = true ] && [ "${RUNNER_OS:-}" = Windows ]; then continue; fi
  bash "$HERE/tests/$t.sh" || fails=$((fails+1))
done
bash "$HERE/tests/bars.sh" >/dev/null 2>&1 && ok "chart bars are proportional" || no "chart bars are not proportional"

echo
[ $fails = 0 ] && echo "all green" || echo "$fails failed"
rm -rf "$TMP" 2>/dev/null
exit $fails
