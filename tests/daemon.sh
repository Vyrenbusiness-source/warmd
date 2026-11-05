#!/usr/bin/env bash
# Unity daemon rounds without Unity: after a HUNG test the run goes on in a fresh editor without the tests that ran and the
# hung one, and every round ends up in one list. The daemon is a stub that answers like WarmdDaemon.cs. No engine needed.
set -u
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP="$(mktemp -d)"; export XDG_CACHE_HOME="$TMP/cache"
trap 'rm -rf "$TMP"' EXIT
fails=0
expect() { if echo "$3" | grep -qE "$2"; then echo "ok   $1"; else echo "FAIL $1: wanted /$2/, got: $(echo "$3" | head -4)"; fails=$((fails+1)); fi; }
refuse() { if echo "$3" | grep -qE "$2"; then echo "FAIL $1: $(echo "$3" | grep -E "$2" | head -2)"; fails=$((fails+1)); else echo "ok   $1"; fi; }

P="$TMP/game"; mkdir -p "$P/ProjectSettings" "$P/Assets"; printf 'm_EditorVersion: 6000.0.0f1\n' > "$P/ProjectSettings/ProjectVersion.txt"
( cd "$P" && git init -q -b main . && git config user.name t && git config user.email t@example.com && printf '.warmd\n' > .gitignore && git add -A && git commit -qm init )

# The stub plays one round per call from $SCRIPT: round N reads rounds/N.tests (tests.txt rows), rounds/N.hung (full name of
# the hung test, empty file = hung outside a test) and logs its arguments. A round without .hung ends green.
rounds() { # hung_resume -> output of unity_test_rounds, then "rc=N"
  ( cd "$P" && WARMD_HOME="$HERE" && . "$HERE/lib/platform.sh" && . "$HERE/lib/core.sh" && detect_project >/dev/null 2>&1 && . "$HERE/adapters/unity.sh" \
    && CFG_hung_resume="$1" && mkdir -p "$RUN" && rm -f "$TMP/calls" \
    && job() {
      local n; n=$(( $(cat "$TMP/calls" 2>/dev/null | wc -l) + 1 )); echo "$*" >> "$TMP/calls"
      case "$*" in *skip=*) cp "$(printf '%s\n' "$@" | sed -n 's/^skip=//p')" "$TMP/skip.$n";; esac
      rm -f "$RUN/tests.txt" "$RUN/current.full"
      [ -f "$TMP/rounds/$n.tests" ] && cp "$TMP/rounds/$n.tests" "$RUN/tests.txt"
      if [ -f "$TMP/rounds/$n.hung" ]; then
        [ -s "$TMP/rounds/$n.hung" ] && cp "$TMP/rounds/$n.hung" "$RUN/current.full"
        printf 'j%s FAIL 9s test\nHUNG %s: hung after 5s (test_timeout)\nbefore it: 1 passed\n' "$n" "$(sed 's/.*\.//' "$TMP/rounds/$n.hung")" > "$RUN/result.txt"
        sed '1s/^[^ ]* //' "$RUN/result.txt"; return 1
      fi
      printf 'j%s OK 3s test\n%s passed, 0 failed, 0 skipped\n' "$n" "$(grep -c . "$RUN/tests.txt")" > "$RUN/result.txt"
      sed '1s/^[^ ]* //' "$RUN/result.txt"; return 0
    } && unity_test_rounds mode=Play filter=Ship cat= speed= test_timeout=5; echo "rc=$?" )
}
mkdir -p "$TMP/rounds"
printf 'P\tGame.Tests.ShipTests.Floats\t\nF\tGame.Tests.ShipTests.Steers\tShipTests.cs:12 Expected 1 but was 2\n' > "$TMP/rounds/1.tests"
echo "Game.Tests.ShipTests.Docks" > "$TMP/rounds/1.hung"
printf 'P\tGame.Tests.ShipTests.Sinks\t\nP\tGame.Tests.ShipTests.Turns\t\n' > "$TMP/rounds/2.tests"

out="$(rounds 10)"
expect "after a HUNG the run goes on in a fresh editor" '^\(goes on after HUNG Docks: fresh editor, round 2, 3 tests done or hung\)$' "$out"
expect "two rounds ran" '^2$' "$(wc -l < "$TMP/calls" | tr -d ' ')"
refuse "the first round has no skip list" 'skip=' "$(sed -n 1p "$TMP/calls")"
expect "the second round runs the same filter" 'mode=Play filter=Ship .*test_timeout=5 skip=' "$(sed -n 2p "$TMP/calls")"
expect "its skip list holds the finished tests and the hung one" '^Game.Tests.ShipTests.Floats,Game.Tests.ShipTests.Steers,Game.Tests.ShipTests.Docks$' "$(paste -sd, "$TMP/skip.2")"
expect "one list over all rounds" '^all rounds: 3 passed, 1 failed, 0 skipped, 1 hung$' "$out"
expect "the hung test is named with its reason" '^HUNG Docks: hung after 5s \(test_timeout\)$' "$out"
expect "the red test is named" '^RED Steers: ShipTests.cs:12 Expected 1 but was 2$' "$out"
expect "a hung test keeps the run red" '^rc=1$' "$out"
expect "tests.txt holds every round, the hung test as an H row" '^P,F,H,P,P$' "$(cut -f1 "$P/.warmd/run/tests.txt" | paste -sd, -)"
expect "result.txt holds the list too" '^j1 FAIL [0-9]+s test$' "$(head -1 "$P/.warmd/run/result.txt")"
expect "and its counts" '^all rounds: 3 passed, 1 failed, 0 skipped, 1 hung$' "$(sed -n 2p "$P/.warmd/run/result.txt")"

out="$(rounds 0)"
expect "hung_resume=0 stops at the first HUNG" '^1$' "$(wc -l < "$TMP/calls" | tr -d ' ')"
refuse "and prints no list of rounds" 'all rounds' "$out"
expect "and stays red" '^rc=1$' "$out"

: > "$TMP/rounds/1.hung"
out="$(rounds 10)"
expect "a hang outside any test is not stepped over" '^1$' "$(wc -l < "$TMP/calls" | tr -d ' ')"
expect "and says where it hung" '^HUNG outside any test in round 1: hung after 5s' "$out"

echo "Game.Tests.ShipTests.Docks" > "$TMP/rounds/1.hung"; echo "Game.Tests.ShipTests.Sinks" > "$TMP/rounds/2.hung"; echo "Game.Tests.ShipTests.Rolls" > "$TMP/rounds/3.hung"
out="$(rounds 2)"
expect "hung_resume caps the rounds" '^\(hung_resume: 2 rounds reached, the rest stays unrun\)$' "$out"
expect "every hung test is in the list" '^all rounds: 3 passed, 1 failed, 0 skipped, 3 hung$' "$out"

rm -f "$TMP/rounds/"*.hung
out="$(rounds 10)"
expect "a green run stays one round" '^1$' "$(wc -l < "$TMP/calls" | tr -d ' ')"
refuse "without a list of rounds" 'all rounds|goes on' "$out"

[ $fails = 0 ] && echo "ALL OK" || { echo "$fails failed"; exit 1; }
