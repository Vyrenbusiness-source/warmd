#!/usr/bin/env bash
# warmd models: one model per role in warmd.conf, --list and --set without a window, the text prompt, floors per role.
set -u
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WARMD="$HERE/bin/warmd"
TMP="$(mktemp -d)"
export XDG_CACHE_HOME="$TMP/cache" WARMD_NO_PREWARM=1
fails=0
ok() { echo "ok   $1"; }
no() { echo "FAIL $1"; fails=$((fails+1)); }
expect() { if echo "$3" | grep -qE "$2"; then ok "$1"; else no "$1: wanted /$2/, got: $(echo "$3" | head -4)"; fi; }

mkdir -p "$TMP/app" && cd "$TMP/app" || exit 1
git init -q -b main .; git config user.name t; git config user.email t@example.com
echo '{ "name": "t", "scripts": { "test": "true" } }' > package.json
printf '.warmd\n' > .gitignore
git add -A; git commit -qm init

out="$("$WARMD" models --list)"
expect "list shows every role" '^producer .*model=.*' "$out"
expect "an unset worker runs on the mid model" '^worker +\(default\) +model=sonnet' "$out"
expect "list shows the cost limit" '^cost_limit_day=none' "$out"
expect "no tty: models prints the list and the non-interactive hint" 'not interactive' "$(WARMD_MODELS_UI= "$WARMD" models < /dev/null)"

expect "set writes a role" '^OK 1 set' "$("$WARMD" models --set worker=opus)"
grep -qx 'role_worker=claude:opus' warmd.conf && ok "a bare model means provider claude" || no "conf: $(cat warmd.conf)"
expect "the worker role sets the split model" 'AGENT w: subagent_type=warmd-worker model=opus' "$(printf 'w | edit | y | src/w.ts\n' > t.txt; "$WARMD" split t.txt)"
"$WARMD" batch-done > /dev/null
"$WARMD" models --set worker=sonnet > /dev/null
[ "$(grep -c '^role_worker=' warmd.conf)" = 1 ] && grep -qx 'role_worker=claude:sonnet' warmd.conf && ok "set again replaces the line" || no "conf: $(cat warmd.conf)"

expect "an unknown role is refused" '^FAIL unknown role boss' "$("$WARMD" models --set boss=opus)"
expect "a bad cost limit is refused" '^FAIL cost_limit_day' "$("$WARMD" models --set cost_limit_day=lots)"
before="$(cat warmd.conf)"; "$WARMD" models --set scout=haiku boss=opus > /dev/null
[ "$before" = "$(cat warmd.conf)" ] && ok "one bad word writes nothing" || no "half written: $(cat warmd.conf)"

expect "a preset sets all six roles" '^OK 6 set' "$("$WARMD" models --set preset=frugal)"
out="$("$WARMD" models --list)"
expect "frugal keeps the worker off the cheap tier" '^worker .*model=sonnet' "$out"
printf 'floor=top\n' >> warmd.conf
out="$("$WARMD" models --list)"
expect "reviewer never below floor" '^reviewer +claude:haiku +model=opus' "$out"
expect "merge never below floor" '^merge +claude:haiku +model=opus' "$out"
: > warmd.conf

# Text prompt: Enter keeps, a typed value sets
out="$(printf '\n\nsonnet\n\nopus\n\n\n12\n' | WARMD_MODELS_UI=text "$WARMD" models)"
expect "the text prompt sets what was typed" 'OK 3 set' "$out"
grep -qx 'role_reviewer=claude:opus' warmd.conf && grep -qx 'cost_limit_day=12' warmd.conf && ok "prompt wrote reviewer and cost limit" || no "conf: $(cat warmd.conf)"
expect "Enter everywhere changes nothing" 'OK nothing changed' "$(printf '\n\n\n\n\n\n\n\n' | WARMD_MODELS_UI=text "$WARMD" models)"

# Success per model from the ledger: the model a task ran on
: > warmd.conf
mkdir -p .warmd/tasks; printf 'Task a.\nFiles you own: src/a.ts\n' > .warmd/tasks/a.md; echo mid > .warmd/tasks/a.tier; echo sonnet > .warmd/tasks/a.model
git checkout -qb warmd/a; "$WARMD" finish --tokens 10 --calls 1 > /dev/null; git checkout -q main
expect "list shows success per model from the ledger" '^worker .*model=sonnet +ok 1/1' "$("$WARMD" models --list)"

# The first init asks only when a person sits at it
mkdir -p "$TMP/p2" && cd "$TMP/p2" || exit 1
git init -q -b main .; git config user.name t; git config user.email t@example.com
echo '{ "name": "t", "scripts": { "test": "true" } }' > package.json; git add -A; git commit -qm init
out="$("$WARMD" init < /dev/null 2>&1)"
echo "$out" | grep -q 'warmd models:' && no "init asked without a tty" || ok "init without a tty does not ask"
out="$(printf '\n\n\n\n\n\n\n\n' | WARMD_MODELS_UI=text "$WARMD" init 2>&1)"
expect "first interactive init asks once" 'warmd models: one model per role' "$out"
out="$(printf '\n\n\n\n\n\n\n\n' | WARMD_MODELS_UI=text "$WARMD" init 2>&1)"
echo "$out" | grep -q 'warmd models:' && no "second init asked again" || ok "second init does not ask again"

cd /; rm -rf "$TMP" 2>/dev/null
[ $fails = 0 ] && echo "models green" || echo "$fails failed"
exit $fails
