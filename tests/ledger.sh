#!/usr/bin/env bash
# Ledger: finish records measured cost, report shows it per tier, routing learns from it.
set -u
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WARMD="$HERE/bin/warmd"
TMP="$(mktemp -d)"
export XDG_CACHE_HOME="$TMP/cache"
fails=0
ok() { echo "ok   $1"; }
no() { echo "FAIL $1"; fails=$((fails+1)); }
expect() { if echo "$3" | grep -qE "$2"; then ok "$1"; else no "$1: wanted /$2/, got: $(echo "$3" | head -4)"; fi; }

mkdir -p "$TMP/app" && cd "$TMP/app" || exit 1
git init -q -b main .; git config user.name t; git config user.email t@example.com
echo '{ "name": "t", "scripts": { "test": "true" } }' > package.json
printf '.warmd\n' > .gitignore
git add -A; git commit -qm init

task() { # name tier files
  mkdir -p .warmd/tasks
  printf 'Task %s.\nFiles you own: %s\n' "$1" "$3" > ".warmd/tasks/$1.md"
  echo "$2" > ".warmd/tasks/$1.tier"
}

expect "report without data says so" 'no ledger yet' "$("$WARMD" report)"

task a mid src/x.js; git checkout -qb warmd/a
expect "finish records and still reports" '^DONE warmd/a' "$("$WARMD" finish --tokens 1000 --calls 10 --outcome escalated)"
task a top src/x.js
expect "second attempt on the next tier" '^DONE warmd/a' "$("$WARMD" finish --tokens 3000 --calls 20)"
expect "same attempt twice is one row" '^DONE' "$("$WARMD" finish --tokens 3000 --calls 20)"
out="$("$WARMD" report)"
expect "report has mid tokens" '^mid +1 +0 +1 +1000 ' "$out"
expect "report has top tokens" '^top +1 +1 +0 +3000 ' "$out"
expect "report names the waste" 'escalation wasted: 1000 tokens in 1 attempts' "$out"
expect "bad number is refused" 'FAIL' "$("$WARMD" finish --tokens abc)"

# The agent ends while its background test still runs: finish ends that run and frees its slot at once
sleep 60 & bgp=$!
mkdir -p .warmd/run/active "$TMP/cache/warmd/slots/2"; echo "- test" > ".warmd/run/active/$bgp"; echo "$bgp" > "$TMP/cache/warmd/slots/2/pid"
out="$("$WARMD" finish --tokens 3000 --calls 20)"
expect "finish stops a run the agent left behind" "^\(stopped warmd test pid $bgp that was still running here, its slot is free\)$" "$out"
kill -0 "$bgp" 2>/dev/null && no "the left run still lives" || ok "the left run is gone"
[ -d "$TMP/cache/warmd/slots/2" ] && no "its slot is still held" || ok "its slot is free"
git checkout -q main
expect "finish refuses the base checkout" '^FAIL warmd finish runs in the base checkout \(main\), nothing recorded, nothing pushed' "$("$WARMD" finish)"
git checkout -q warmd/a

# routing: one escalated mid task is not enough, two are
git checkout -q main
expect "one failure keeps mid" '^mid ' "$("$WARMD" route 'fix a bug' src/y.js)"
task b mid src/z.js; git checkout -qb warmd/b
"$WARMD" finish --tokens 500 --calls 5 --outcome escalated >/dev/null
git checkout -q main
expect "two failures in the area send it to top" '^top ' "$("$WARMD" route 'fix a bug' src/y.js)"
expect "other areas stay mid" '^mid ' "$("$WARMD" route 'fix a bug' lib/y.js)"

cd /; rm -rf "$TMP" 2>/dev/null
[ $fails = 0 ] && echo "ledger green" || echo "$fails failed"
exit $fails
