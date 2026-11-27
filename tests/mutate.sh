#!/usr/bin/env bash
# warmd mutate: changed lines only, each mutant judged by the tests, survivors as file:line, the file always restored.
set -u
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WARMD="$HERE/bin/warmd"
TMP="$(mktemp -d)"
export XDG_CACHE_HOME="$TMP/cache"
fails=0
ok() { echo "ok   $1"; }
no() { echo "FAIL $1"; fails=$((fails+1)); }
expect() { if echo "$3" | grep -qE "$2"; then ok "$1"; else no "$1: wanted /$2/, got: $(echo "$3" | head -6)"; fi; }
refuse() { if echo "$3" | grep -qE "$2"; then no "$1: $(echo "$3" | grep -E "$2" | head -1)"; else ok "$1"; fi; }

# The mutation table, one line in, the first mutant out
reg() { :; }; . "$HERE/lib/mutate.sh"
mut() { printf '%s\n' "$2" | awk -v LANG="$1" "$MUT_AWK" | tr '\037' '|'; }
expect "gd < becomes <="          '^	if a <= b:\|< -> <=$'        "$(mut gd "	if a < b:")"
expect "gd + becomes -"            '^	return a - b\|\+ -> -$'      "$(mut gd "	return a + b")"
expect "gd number plus one"        'var x = 4\|3 -> 4'              "$(mut gd "	var x = 3")"
expect "gd true becomes false"     'ok = false\|true -> false'      "$(mut gd "	ok = true")"
expect "py False becomes True"     'flag = True\|False -> True'     "$(mut py "    flag = False")"
expect "js arrow is no comparison" '=> a >= 2;\|> -> >='            "$(mut js "  const f = (a) => a > 2;")"
expect "sh -gt becomes -ge"        '(^| )-ge 0 \] && x=1\|-gt -> -ge'    "$(mut sh '  [ "$n" -gt 0 ] && x=1')"
expect "sh return 0 becomes 1"     'return 1\|0 -> 1'               "$(mut sh "  return 0")"
expect "a string and a comment are no mutant" '^$'                  "$(mut gd '	print("a < b")  # x < y')"
expect "sh positional and fd numbers stay"    '^$'                  "$(mut sh '  echo "${1:-}" 2>/dev/null')"
expect "warmd: nomutate skips the line"       '^$'                  "$(mut gd "	x = 1 # warmd: nomutate")"

mkdir -p "$TMP/app" && cd "$TMP/app" || exit 1
git init -q -b main .; git config user.name t; git config user.email t@example.com
printf '.warmd\ncache\n' > .gitignore
mkdir tests
cat > calc.sh <<'EOF'
#!/usr/bin/env bash
add() { echo $(( $1 + $2 )); }
big() { [ "$1" -gt 10 ]; }
EOF
cat > tests/t.sh <<'EOF'
. ./calc.sh
[ "$(add 2 3)" = 5 ] || { echo "FAIL add"; exit 1; }
big 11 || { echo "FAIL big 11"; exit 1; }
big 5 && { echo "FAIL big 5"; exit 1; }
exit 0
EOF
git add -A; git commit -qm init
git checkout -qb feature

expect "no change, nothing to mutate" '^OK mutate: no changed line to mutate' "$("$WARMD" mutate --cmd 'bash tests/t.sh')"

# Both lines change on the branch: add is tested exactly, big never at its edge 10
sed -i 's/\$1 + \$2/$2 + $1/; s/-gt 10/-gt 10 /' calc.sh
cp calc.sh "$TMP/calc.want"
head0="$(git rev-parse HEAD)"
out="$("$WARMD" mutate --cmd 'bash tests/t.sh')"; rc=$?
expect "a mutant no test sees is listed as file:line" '^SURVIVED calc\.sh:3  -gt -> -ge$' "$out"
refuse "a mutant a test sees is not listed" 'calc\.sh:2' "$out"
expect "the verdict counts and scores" '^FAIL mutate: 1 of 2 mutants survived, score 50%' "$out"
[ $rc = 1 ] && ok "a survivor is exit 1" || no "a survivor gave exit $rc"
cmp -s calc.sh "$TMP/calc.want" && ok "the file is restored byte for byte" || no "calc.sh differs after mutate: $(diff calc.sh "$TMP/calc.want" | head -3)"
[ "$(git rev-parse HEAD)" = "$head0" ] && [ -z "$(git diff --cached --name-only)" ] && ok "nothing staged or committed" || no "mutate committed or staged"
expect "the score lands in the quality file" '	mutate	[0-9a-f]+	1	2	1$' "$(tail -1 .git/warmd-quality.tsv)"

# A test at the edge kills it: every mutant red, score 100
printf 'big 10 && { echo "FAIL big 10"; exit 1; }\nexit 0\n' >> tests/t.sh; sed -i '0,/^exit 0$/{/^exit 0$/d}' tests/t.sh
out="$("$WARMD" mutate --cmd 'bash tests/t.sh')"; rc=$?
expect "every mutant killed" '^OK mutate: 2 of 2 mutants killed, score 100%' "$out"
[ $rc = 0 ] && ok "all killed is exit 0" || no "all killed gave exit $rc"

# Red before mutation: nothing to measure
expect "red tests before mutation measure nothing" '^FAIL mutate: the tests are red before any mutation' "$("$WARMD" mutate --cmd 'exit 3')"

# Through warmd check without cache (the default judge), test= from warmd.conf
printf 'test=bash tests/t.sh\n' > warmd.conf
expect "the default judge is warmd check" '^OK mutate: 2 of 2 mutants killed' "$("$WARMD" mutate)"
rm warmd.conf

# The time limit: a limit below one run measures nothing and says so
expect "a time limit below one run says so" '^WARN mutate: the time limit of 0s ends before the first of 2 mutants' "$("$WARMD" mutate --limit 0 --cmd 'bash tests/t.sh')"

# A kill in the middle of a mutant still restores the file
"$WARMD" mutate --cmd '[ "$WARMD_NOCACHE" = 1 ] && sleep 20; bash tests/t.sh' > "$TMP/kill.out" 2>&1 & mp=$!
for _ in $(seq 1 100); do cmp -s calc.sh "$TMP/calc.want" || break; sleep 0.1; done
cmp -s calc.sh "$TMP/calc.want" && no "the mutant never appeared" || ok "the mutant is in place while its test runs"
kill -TERM "$mp" 2>/dev/null; wait "$mp" 2>/dev/null
cmp -s calc.sh "$TMP/calc.want" && ok "a kill restores the file" || no "calc.sh still mutated after a kill: $(diff calc.sh "$TMP/calc.want" | head -3)"

# GDScript: tab indentation survives, the mutant is what the judge sees
git add -A; git commit -qm calc
printf 'extends RefCounted\n\nfunc add(a: int, b: int) -> int:\n\treturn a + b\n' > score.gd
git add score.gd; git commit -qm gd
git checkout -q main; git merge -q --no-edit feature; git checkout -qb gd
printf 'extends RefCounted\n\nfunc add(a: int, b: int) -> int:\n\tvar s := 0\n\treturn a + b + s\n' > score.gd
cp score.gd "$TMP/score.want"
out="$("$WARMD" mutate --cmd "cat score.gd >> '$TMP/seen'; grep -q 'return a + b + s' score.gd && grep -q ':= 0' score.gd")"
expect "gd lines are mutated and judged" '^OK mutate: 2 of 2 mutants killed' "$out"
expect "the mutant keeps its tab" '^	var s := 1$' "$(cat "$TMP/seen")"
expect "the second mutant is the + of its own line" '^	return a - b \+ s$' "$(cat "$TMP/seen")"
cmp -s score.gd "$TMP/score.want" && ok "the gd file is restored" || no "score.gd differs after mutate"

cd / && rm -rf "$TMP"
[ $fails = 0 ] && echo "mutate: all ok" || echo "mutate: $fails failed"
exit $fails
