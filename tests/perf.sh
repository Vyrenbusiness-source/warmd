#!/usr/bin/env bash
# warmd perf on a real Vite project: equal result passes, a slowdown is refused. Needs node, npm access and Chrome.
set -u
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WARMD="$HERE/bin/warmd"
TMP="$(mktemp -d)"
export XDG_CACHE_HOME="$TMP/cache"
fails=0
ok() { echo "ok   $1"; }
no() { echo "FAIL $1"; fails=$((fails+1)); }
expect() { if echo "$3" | grep -qE "$2"; then ok "$1"; else no "$1: wanted /$2/, got: $(echo "$3" | head -3)"; fi; }

mkdir -p "$TMP/app/src"; cd "$TMP/app" || exit 1
git init -q -b main .; git config user.name t; git config user.email t@example.com
cat > package.json <<'EOF'
{ "name": "perfapp", "private": true, "type": "module", "scripts": { "build": "vite build" } }
EOF
cat > index.html <<'EOF'
<!doctype html><html><body><div id="app"></div><script type="module" src="/src/main.js"></script></body></html>
EOF
# SPIN_MS is the busy wait at load, padding keeps the byte size equal when only the wait changes
write_app() { # spin-ms padding-bytes
  printf 'const t=performance.now();while(performance.now()-t<%s){}\ndocument.getElementById("app").textContent="hi";\nconsole.log("%s");\n' "$1" "$(head -c "$2" /dev/zero | tr '\0' x)" > src/main.js
}
write_app 100 10
printf 'node_modules\ndist\n.warmd\n' > .gitignore
if ! npm install --no-audit --no-fund --silent vite >"$TMP/npm.log" 2>&1; then no "npm install vite: $(tail -2 "$TMP/npm.log")"; echo "$fails failed"; exit 1; fi
git add -A; git commit -qm init

expect "detected as web" "web project" "$("$WARMD" status)"
expect "no baseline is refused" '^FAIL perf: no baseline' "$("$WARMD" perf)"
out="$("$WARMD" perf --save)"; expect "baseline saved" '^OK [0-9]+s perf baseline saved: .*load_ms10 [0-9]+ .*size_bytes [0-9]+' "$out"
[ -f warmd.perf ] && ok "baseline lives in the repo" || no "warmd.perf missing"
expect "baseline holds the machine reference" '^load_ref_ms10 [0-9]+$' "$(cat warmd.perf)"
r="$("$WARMD" perf)"; echo "     baseline: $(tr '\n' ' ' < warmd.perf) now: $r"
expect "equal result passes" '^OK [0-9]+s perf within 5%' "$r"
# A machine that is slower now slows the reference page as much: that part is no regression of the product
cp warmd.perf "$TMP/perf.keep"
awk '$1 ~ /^load_(ref_)?ms10$/ { $2 -= 3000 } { print }' "$TMP/perf.keep" > warmd.perf
expect "slower machine is no regression" '^OK ' "$("$WARMD" perf)"
cp "$TMP/perf.keep" warmd.perf

write_app 100 4000
expect "bigger bundle is refused" '^FAIL perf regression: size_bytes' "$("$WARMD" perf)"
write_app 100 10
expect "back to equal passes again" '^OK ' "$("$WARMD" perf)"

write_app 600 10
r="$("$WARMD" perf)"; expect "slower load is refused" '^FAIL perf regression: load_ms10' "$r"
echo "$r" | grep -q size_bytes && no "load slowdown must not blame the size" || ok "size untouched by the load slowdown"
write_app 100 10

# Faster is never a regression
write_app 20 10
expect "faster load passes" '^OK ' "$("$WARMD" perf)"
write_app 100 10

# Tolerance comes from warmd.conf
printf 'perf_tolerance=1000\n' > warmd.conf
write_app 100 4000
expect "tolerance from warmd.conf" '^OK ' "$("$WARMD" perf)"
rm warmd.conf; write_app 100 10

# Programs: median of 3 timed runs of perf_cmd
mkdir -p "$TMP/prog"; cd "$TMP/prog" || exit 1
git init -q -b main .; git config user.name t; git config user.email t@example.com
printf '.warmd\n' > .gitignore
printf '[ -f slow ] && sleep 1.5 || sleep 0.5\n' > work.sh
printf 'perf_cmd=sh work.sh\n' > warmd.conf
git add -A; git commit -qm init
expect "program baseline" '^OK [0-9]+s perf baseline saved: cmd_ms [0-9]+' "$("$WARMD" perf --save)"
expect "program equal passes" '^OK ' "$("$WARMD" perf)"
touch slow
expect "program slowdown is refused" '^FAIL perf regression: cmd_ms' "$("$WARMD" perf)"
rm slow

# warmd merge runs it when configured (perf=1) and rolls back on a regression
printf 'perf_cmd=sh work.sh
perf=1
' > warmd.conf; git add warmd.conf warmd.perf; git commit -qm perf-on
git checkout -q -b feat2; printf 'sleep 1.5
' > work.sh; git add -A; git commit -qm slower; git checkout -q main
expect "merge refuses the slowdown" '^FAIL merge feat2: .*perf regression: cmd_ms' "$("$WARMD" merge feat2)"
grep -q '^sleep 1.5' work.sh && no "merge left the slow change" || ok "merge rolled back"

# warmd leak: kernel pool and free RAM around N process starts, Windows only
. "$HERE/lib/platform.sh"
out="$(WARMD_NO_RAM_WAIT=1 "$WARMD" leak 5 2>&1)"; rc=$?
if [ "$OS" = win ]; then
  expect "leak names the starts" '^warmd leak: 5 starts of ' "$out"
  expect "leak: nonpaged pool per start" '^nonpaged pool [+-][0-9]+ KB \([+-][0-9]+\.[0-9]{2} KB per start\), now [0-9]+ MB$' "$out"
  expect "leak: paged pool per start" '^paged pool +[+-][0-9]+ KB \([+-][0-9]+\.[0-9]{2} KB per start\)' "$out"
  expect "leak: free RAM" '^free RAM +[+-][0-9]+ MB, now [0-9]+ MB$' "$out"
  expect "leak ends with a verdict" '^(OK no kernel pool growth|LEAK kernel pool grows)' "$(echo "$out" | tail -1)"
else
  [ $rc = 2 ] && echo "$out" | grep -q '^FAIL warmd leak measures the Windows kernel pool' && ok "leak outside Windows says so" || no "leak outside Windows: $out"
fi
expect "leak with a bad count is usage" '^warmd leak \[N\]' "$("$WARMD" leak abc 2>&1)"

cd "$HERE" || exit 1; rm -rf "$TMP" 2>/dev/null
[ $fails = 0 ] && echo "all perf tests passed" || { echo "$fails failed"; exit 1; }
