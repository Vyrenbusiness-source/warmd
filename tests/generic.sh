#!/usr/bin/env bash
# Shell projects like warmd itself: warmd check runs only the tests/*.sh that belong to the changed files.
set -u
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WARMD="$HERE/bin/warmd"
TMP="$(mktemp -d)"
export XDG_CACHE_HOME="$TMP/cache" WARMD_NOCACHE=1 WARMD_SELECT=1   # selection under test, the shortcut has its own block
fails=0
ok() { echo "ok   $1"; }
no() { echo "FAIL $1"; fails=$((fails+1)); }
expect() { if echo "$3" | grep -qE "$2"; then ok "$1"; else no "$1: wanted /$2/, got: $(echo "$3" | head -3)"; fi; }

# Every test writes its name to ran.txt, so the test sees which ones warmd started
P="$TMP/shp"; mkdir -p "$P/bin" "$P/lib" "$P/adapters" "$P/tests/e2e" "$P/docs"; cd "$P" || exit 1
git init -q -b main .; git config core.autocrlf false; git config user.name t; git config user.email t@example.com
for t in run alpha web e2e docs; do printf 'echo %s >> "%s/ran.txt"\n' "$t" "$P" > "tests/$t.sh"; done
printf 'echo beta >> "%s/ran.txt"; exit 1\n' "$P" > tests/beta.sh
echo 'echo hi' > bin/tool; echo 'a=1' > lib/alpha.sh; echo 'b=1' > lib/beta.sh; echo 'n=1' > lib/notest.sh
echo 'w=1' > adapters/web.sh; echo 'x' > tests/e2e/case.txt; echo doc > docs/A.md
printf 'test=bash tests/run.sh\n' > warmd.conf
printf '.warmd\nran.txt\n' > .gitignore; git add -A; git commit -qm init
change() { git checkout -q main 2>/dev/null; git checkout -qB "w$RANDOM"; local f; for f in "$@"; do echo "# $RANDOM" >> "$f"; done; git commit -qam c; rm -f ran.txt; }
ran() { [ -f ran.txt ] && sort ran.txt | paste -sd' ' - || echo none; }

change lib/alpha.sh
out="$("$WARMD" check 2>&1)"; rc=$?
expect "lib change runs its own test only" '^alpha$' "$(ran)"
expect "the affected file is named" 'affected: tests/alpha.sh' "$out"
[ $rc = 0 ] && ok "green own test exits zero" || no "green own test exited $rc: $out"

change adapters/web.sh tests/e2e/case.txt docs/A.md
"$WARMD" check >/dev/null 2>&1
expect "adapter, test folder and docs map to their tests" '^docs e2e web$' "$(ran)"

change lib/beta.sh lib/alpha.sh
out="$("$WARMD" check 2>&1)"; rc=$?
expect "every affected test runs, a red one does not stop the next" '^alpha beta$' "$(ran)"
[ $rc != 0 ] && ok "a red affected test makes check red" || no "red test exited zero: $out"

change bin/tool
"$WARMD" check >/dev/null 2>&1
expect "bin change runs the full suite" '^run$' "$(ran)"
change tests/run.sh
"$WARMD" check >/dev/null 2>&1
expect "tests/run.sh change runs the full suite" '^run$' "$(ran)"
# full=ci: the full suite never runs here, check says where it runs instead.
git checkout -q main; printf 'test=bash tests/run.sh\nfull=ci\n' > warmd.conf; git commit -qam "full on ci"
change bin/tool
out="$("$WARMD" check 2>&1)"; rc=$?
expect "full=ci runs nothing locally" '^none$' "$(ran)"
expect "full=ci says where the full suite runs" '^PUSH the full suite runs on CI only \(bin/tool changed, full=ci in warmd.conf\): push, then warmd ci$' "$out"
[ $rc = 0 ] && ok "full=ci exits zero" || no "full=ci exited $rc"
change lib/alpha.sh
"$WARMD" check >/dev/null 2>&1
expect "full=ci still runs the own test of a lib file" '^alpha$' "$(ran)"
git checkout -q main; printf 'test=bash tests/run.sh\n' > warmd.conf; git commit -qam "full local again"
# A scene Unity leaves behind after a dead PlayMode run is generated, not a change.
git checkout -qB "w$RANDOM"; mkdir -p Assets; : > Assets/InitTestScene2c6c14d8-bf74-4640-a858-d42fdaa3300d.unity; : > Assets/InitTestScene2c6c14d8-bf74-4640-a858-d42fdaa3300d.unity.meta; rm -f ran.txt
out="$("$WARMD" check 2>&1)"
expect "InitTestScene leftovers are no change" 'OK no code changed' "$out"
expect "InitTestScene leftovers start no test" '^none$' "$(ran)"
rm -rf Assets
change lib/notest.sh
out="$("$WARMD" check 2>&1)"
expect "a lib file without its own test falls back to the full suite" '^run$' "$(ran)"
expect "the reason is named" 'lib/notest.sh has no tests/notest.sh' "$out"
expect "a check that ran tests ends with one result line" '^OK [0-9]+s check: compiled, tests green$' "$(echo "$out" | tail -1)"
expect "a cache hit ends with a result line too" '^OK [0-9]+s check: compiled, .*green from the cache$' "$(WARMD_NOCACHE=0 "$WARMD" check 2>&1 | tail -1)"
change warmd.conf
out="$("$WARMD" check 2>&1)"
expect "a change no test belongs to runs nothing" '^none$' "$(ran)"
expect "a check with no test touched still ends with a result line" '^OK [0-9]+s check: compiled, no tests affected$' "$(echo "$out" | tail -1)"
# caches and editor droppings never count as a change
refuse() { if echo "$3" | grep -qE "$2"; then no "$1: $(echo "$3" | grep -E "$2" | head -2)"; else ok "$1"; fi; }
git checkout -qB "w$RANDOM"; mkdir -p Art/__pycache__; : > Art/__pycache__/x.cpython-312.pyc; : > .DS_Store; rm -f ran.txt
out="$("$WARMD" check 2>&1)"; expect "pycache and .DS_Store start no test" '^none$' "$(ran)"
refuse "pycache and .DS_Store are no change" 'pycache|DS_Store|running all' "$out"
rm -rf Art .DS_Store


# ---- small suite: when the full run is cheaper than build plus selection, check runs the full suite ----
S="$TMP/small"; mkdir -p "$S/src" "$S/tests"; cd "$S" || exit 1
git init -q -b main .; git config core.autocrlf false; git config user.name t; git config user.email t@example.com
echo 'v=1' > src/a.py; echo 'pass' > tests/test_a.py
printf 'build=sleep 4\ntest=true\n' > warmd.conf; printf '.warmd\n' > .gitignore; git add -A; git commit -qm init
git checkout -qb w1; echo 'v=2' > src/a.py; git commit -qam c
ms() { local s e; s="$(date +%s%N)"; "$@" >/dev/null 2>&1; e="$(date +%s%N)"; echo $(( (e - s) / 1000000 )); }
WARMD_SELECT=0 "$WARMD" test >/dev/null 2>&1
[ -s .warmd/full.ms ] && ok "a full warmd test records its time" || no "full.ms missing"
WARMD_SELECT=0 "$WARMD" check >/dev/null 2>&1
[ -s .warmd/check.ms ] && [ "$(cat .warmd/check.ms)" -ge 4000 ] && ok "a selective check records build plus selection" || no "check.ms: $(cat .warmd/check.ms 2>&1)"
out="$(WARMD_SELECT=0 "$WARMD" check 2>&1)"; t="$(ms env WARMD_SELECT=0 "$WARMD" check)"; sel="$(ms env WARMD_SELECT=1 "$WARMD" check)"
expect "small suite: check runs the full suite instead" '^\(running all tests: the full suite took' "$out"
# Same clock on both sides: a slow runner's warmd start-up counts for both
[ "$t" -lt "$sel" ] && ok "small suite: check ${t}ms stays under build plus selection ${sel}ms" || no "small suite: check took ${t}ms, build plus selection ${sel}ms"
WARMD_SELECT=1 "$WARMD" check 2>&1 | grep -q 'running all tests: the full suite' && no "WARMD_SELECT=1 still took the shortcut" || ok "WARMD_SELECT=1 keeps the selection"
echo 9999999 > .warmd/full.ms
WARMD_SELECT=0 "$WARMD" check 2>&1 | grep -q 'running all tests: the full suite' && no "a slow full suite still took the shortcut" || ok "a slow full suite keeps build plus selection"
cd "$HERE" || exit 1

echo
[ $fails = 0 ] && echo "all green" || echo "$fails failed"
cd "$HERE" || exit 1; rm -rf "$TMP" 2>/dev/null
exit $fails
