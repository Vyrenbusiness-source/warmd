#!/usr/bin/env bash
# warmd layout self-test: a fixture page with exactly one clipped text and one overlap, plus a clean page. Needs node and Chrome.
set -u
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WARMD="$HERE/bin/warmd"
TMP="$(mktemp -d)"
export XDG_CACHE_HOME="$TMP/cache"
fails=0
ok() { echo "ok   $1"; }
no() { echo "FAIL $1"; fails=$((fails+1)); }
expect() { if echo "$3" | grep -qE "$2"; then ok "$1"; else no "$1: wanted /$2/, got: $(echo "$3" | head -3)"; fi; }

mkdir -p "$TMP/site"; cd "$TMP/site" || exit 1
git init -q -b main .; git config user.name t; git config user.email t@example.com
cp "$HERE/tests/fixtures/layout/index.html" .
printf '.warmd\n' > .gitignore; git add -A; git commit -qm init

out="$("$WARMD" layout index.html 2>&1)"; rc=$?
echo "$out" | sed 's/^/     /'
[ "$rc" != 0 ] && ok "problems exit non-zero" || no "problems exited zero"
expect "clipped text is named with selector and size" 'div#clip 120x24 text clipped by overflow hidden' "$out"
expect "overlap names both boxes" 'p#a x p#b .* text boxes overlap' "$out"
expect "problem is the same at both widths" '^both ' "$out"
[ "$(echo "$out" | grep -c 'clipped')" = 1 ] && ok "exactly one overflow" || no "overflow count $(echo "$out" | grep -c 'clipped')"
[ "$(echo "$out" | grep -c 'overlap')" = 1 ] && ok "exactly one overlap" || no "overlap count $(echo "$out" | grep -c 'overlap')"
if echo "$out" | grep -q 'p#ok'; then no "clean paragraph reported"; else ok "clean paragraph not reported"; fi
[ "$(echo "$out" | wc -l | tr -d ' ')" -le 15 ] && ok "output stays under 15 lines" || no "output too long"

# phone only: a fixed 600 px box is wider than 390 and scrolls the page
cat > wide.html <<'HTML'
<!doctype html><body style="margin:0"><div id="box" style="width:600px">fixed width box</div></body>
HTML
out="$("$WARMD" layout wide.html 2>&1)"
expect "phone-only width problem" '^phone div#box 600x[0-9]+ wider than the viewport' "$out"
expect "horizontal scroll is reported" 'phone html .* page scrolls horizontally' "$out"

cat > clean.html <<'HTML'
<!doctype html><body style="margin:0"><p>Nothing wrong here.</p></body>
HTML
out="$("$WARMD" layout clean.html 2>&1)"; rc=$?
expect "clean page is one OK line" '^OK [0-9]+s layout' "$out"
[ "$rc" = 0 ] && ok "clean page exits zero" || no "clean page exited $rc"

echo
[ $fails = 0 ] && echo "all green" || echo "$fails failed"
cd "$HERE"; rm -rf "$TMP" 2>/dev/null
exit $fails
