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

# ---- routing ----
expect "no files means the cheap tier" '^cheap model=haiku' "$("$WARMD" route 'list all TODOs')"
expect "plain edit means the mid tier" '^mid model=sonnet' "$("$WARMD" route 'add a footer' src/footer.css)"
expect "hard words mean the top tier" '^top model=opus' "$("$WARMD" route 'find root cause of the crash' src/a.ts)"
printf 'mid=sonnet-next\ntop_paths=src/net/\n' > warmd.conf
expect "new models are one config line" '^mid model=sonnet-next' "$("$WARMD" route 'add a footer' src/footer.css)"
expect "paths can force the top tier" '^top' "$("$WARMD" route 'tidy' src/net/sync.ts)"
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
shared="$(git rev-parse --path-format=absolute --git-common-dir)/warmd-shared.md"
expect "the shared brief lists owners" 'footer: src/footer.css' "$(cat "$shared")"
expect "a task points to the shared brief" 'Shared brief:' "$(cat .warmd/tasks/footer.md)"
expect "a note goes into the brief" 'OK noted' "$("$WARMD" note 'price lives in src/price.ts:3')"
expect "the same note is not added twice" 'already noted' "$("$WARMD" note 'price lives in src/price.ts:3')"
expect "a worktree sees the same brief" 'price lives' "$(cat "$(git -C "$(git worktree list --porcelain | sed -n 's/^worktree //p' | grep footer)" rev-parse --path-format=absolute --git-common-dir)/warmd-shared.md")"
for i in $(seq 1 45); do "$WARMD" note "fact $i" > /dev/null; done
[ "$(sed -n '/^## Findings/,$p' "$shared" | wc -l | tr -d ' ')" -le 41 ] && ok "the brief keeps 40 findings" || no "the brief keeps growing"
expect "long notes are refused" 'over 160' "$("$WARMD" note "$(printf 'x%.0s' $(seq 1 170))")"
expect "escalate moves up one tier" 'AGENT footer: subagent_type=warmd-worker model=opus' "$("$WARMD" escalate footer)"
expect "top tier cannot escalate" 'needs a human' "$("$WARMD" escalate footer)"
printf 'a | x | y | src/same.ts\nb | x | y | src/same.ts\n' > clash.txt
out="$("$WARMD" split clash.txt)"
expect "split refuses two owners of a file" 'already owned' "$out"
[ ! -d "$(dirname "$PWD")/.warmd-worktrees/app/a" ] && ok "a refused batch creates nothing" || no "refused batch created a worktree"
expect "finish reports facts in one line" '^DONE main [0-9a-f]+' "$("$WARMD" finish)"
expect "board lists worktrees" 'warmd/footer' "$("$WARMD" board)"

# ---- map ----
cat > app.ts <<'EOF'
export function alpha() {}
const beta = 1;
EOF
expect "map shows line numbers" '^1 export function alpha' "$("$WARMD" map app.ts | sed -n 2p)"

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

echo
[ $fails = 0 ] && echo "all green" || echo "$fails failed"
rm -rf "$TMP" 2>/dev/null
exit $fails
