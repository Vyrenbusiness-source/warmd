#!/usr/bin/env bash
# Output audit: the lines status, doctor, board, finish, route, report and audit print must be right and not mislead.
set -u
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WARMD="$HERE/bin/warmd"
TMP="$(mktemp -d)"
# One path form on Windows: long names. A runner TEMP like RUNNER~1 otherwise differs from what git reports
command -v cygpath >/dev/null 2>&1 && TMP="$(cygpath -u "$(cygpath -l -m "$TMP")")"
export XDG_CACHE_HOME="$TMP/cache" WARMD_TRANSCRIPTS="$TMP/transcripts"
fails=0
ok() { echo "ok   $1"; }
no() { echo "FAIL $1"; fails=$((fails+1)); }
expect() { if echo "$3" | grep -qE "$2"; then ok "$1"; else no "$1: wanted /$2/, got: $(echo "$3" | head -4)"; fi; }
refuse() { if echo "$3" | grep -qE "$2"; then no "$1: did not want /$2/, got: $(echo "$3" | grep -E "$2" | head -2)"; else ok "$1"; fi; }

# ---- no known project type: plain words, not "none project" ----
mkdir -p "$TMP/plain" && cd "$TMP/plain" || exit 1
git init -q -b main .; git config user.name t; git config user.email t@example.com
echo a > a.txt; git add a.txt; git commit -qm init
out="$("$WARMD" status)"
expect "status names an unknown project type in words" 'no known project type at' "$out"
refuse "status never says none project" 'none project' "$out"
expect "doctor names an unknown project type in words" '^detected: no known project type at' "$("$WARMD" doctor 2>&1 | head -1)"

# ---- route without a goal prints its usage ----
out="$("$WARMD" route)"; rc=$?
expect "route without a goal prints usage" '^warmd route <goal>' "$out"
[ "$rc" = 2 ] && ok "route without a goal exits 2" || no "route without a goal exits $rc"

# ---- board: every worktree, a gone folder does not end the list, new files count as dirty ----
mkdir -p "$TMP/b" && cd "$TMP/b" || exit 1
git init -q -b main r; cd r || exit 1; git config user.name t; git config user.email t@example.com
echo a > a.txt; git add a.txt; git commit -qm init
git worktree add -q ../gone -b gone; git worktree add -q --detach ../loose; git worktree add -q ../last -b last
rm -rf ../gone
echo new > new.txt
out="$("$WARMD" board 2>&1)"; rc=$?
refuse "board has no shell error for a gone folder" 'syntax error|fatal:' "$out"
[ "$rc" = 0 ] && ok "board exits 0 with a gone folder" || no "board exits $rc with a gone folder"
expect "board names the gone folder and the fix" '^gone +gone +folder missing, drop it: git worktree prune' "$out"
expect "board lists a detached worktree" '^loose +\(detached\) +[0-9]+m' "$out"
expect "board goes on after a gone folder" '^last +last +[0-9]+m' "$out"
expect "board counts a new file as dirty" '^r +main +[0-9]+m +1 +0$' "$out"

# ---- finish: a file never added counts as uncommitted ----
git checkout -q -b warmd/x
out="$("$WARMD" finish 2>&1)"
expect "finish counts a file never added as uncommitted" '^DONE warmd/x .*, 1 uncommitted' "$out"
rm -f new.txt

# ---- report: tok/task averages only tasks with a count, and says so ----
mkdir -p "$TMP/led"
printf 'x\tt1\tmid\tsrc\t60000\t10\t5\tok\n' > "$TMP/led/l.tsv"
for i in 2 3 4; do printf 'x\tt%s\tmid\tsrc\t-\t-\t5\tok\n' "$i" >> "$TMP/led/l.tsv"; done
out="$(cd "$TMP/plain" && bash -c ". '$HERE/lib/platform.sh'; . '$HERE/lib/ledger.sh'; ledger_report '$TMP/led/l.tsv'")"
expect "report row keeps its numbers" '^mid +4 +4 +0 +60000 +60000 ' "$out"
expect "report says how many tasks carry a token count" 'tokens known for mid 1 of 4 tasks' "$out"
printf 'x\tt1\tmid\tsrc\t100\t1\t5\tok\n' > "$TMP/led/full.tsv"
refuse "report adds no note when every task has a count" 'tokens known for' "$(bash -c ". '$HERE/lib/platform.sh'; . '$HERE/lib/ledger.sh'; ledger_report '$TMP/led/full.tsv'")"

# ---- audit: shares round, 1.98 % is 2 %, not 1 % ----
mkdir -p "$TMP/au" && cd "$TMP/au" || exit 1
git init -q -b main .; git config user.name t; git config user.email t@example.com
head -c 792 /dev/zero | tr '\0' 'x' > CLAUDE.md
git add CLAUDE.md; git commit -qm init
slug="$(bash -c ". '$HERE/lib/platform.sh'; native_path '$TMP/au'" | sed 's/[^A-Za-z0-9]/-/g')"
mkdir -p "$TMP/home/.claude/projects/$slug/s1/subagents"
echo '{"message":{"usage":{"input_tokens":10000,"cache_creation_input_tokens":0,"cache_read_input_tokens":0}}}' > "$TMP/home/.claude/projects/$slug/s1/subagents/a.jsonl"
out="$(HOME="$TMP/home" "$WARMD" audit 2>&1)"
expect "audit rounds a share of 1.98 % to 2 %" '~198 tokens +2%  CLAUDE.md' "$out"
expect "audit rounds the rest too" '~9802 tokens +98%  rest' "$out"

# ---- godot: a project path with a space still finds a new class_name ----
G="$TMP/my game"; mkdir -p "$G/.godot"; echo 'x' > "$G/.godot/global_script_class_cache.cfg"
touch -d '2020-01-01' "$G/.godot/global_script_class_cache.cfg" 2>/dev/null || touch -t 202001010000 "$G/.godot/global_script_class_cache.cfg"
printf 'class_name Brandnew\nextends Node\n' > "$G/new.gd"
fresh() { bash -c "CFG_idle_min=5; . '$HERE/adapters/godot.sh'; PROJECT='$G'; class_cache_fresh" && echo fresh || echo stale; }
expect "a new class_name under a path with a space marks the cache stale" '^stale$' "$(fresh)"
printf 'list=[{\n"base": &"Node",\n"class": &"Brandnew",\n"icon": "",\n"path": "res://new.gd"\n}]\n' > "$G/.godot/global_script_class_cache.cfg"
expect "a known class_name keeps the cache fresh" '^fresh$' "$(fresh)"
mkdir -p "$G/raw" "$G/.hidden"; touch "$G/raw/.gdignore"; printf 'class_name Vendored\n' > "$G/raw/v.gd"; printf 'class_name Hidden\n' > "$G/.hidden/h.gd"
expect "a class_name in a .gdignore or hidden folder is not expected in the cache" '^fresh$' "$(fresh)"
mkdir -p "$G/sub"; mv "$G/new.gd" "$G/sub/new.gd"
expect "a moved class_name script marks the cache stale" '^stale$' "$(fresh)"

# ---- godot: a class cache that still names a moved script is renewed before the compile, "hides a global script class" is red only when it stays ----
GB="$TMP/godot-moved"; GS="$TMP/godot-moved-stub"; mkdir -p "$GB/scripts/ui" "$GS"; cd "$GB" || exit 1
git init -q -b main .; git config user.name t; git config user.email t@example.com
printf 'config_version=5\n[application]\nconfig/name="m"\n' > project.godot; printf '.warmd\n.godot\n' > .gitignore
printf 'class_name OrbitPreview\nextends Node\n' > scripts/ui/orbit_preview.gd
git add -A; git commit -qm init
# Stub engine: --import rebuilds the class cache from the scripts on disk and counts itself; the compile job fails with
# Godot's line while the cache names a script that is gone, while $GS/needs_import exists or while STUB_HIDES is set
cat > "$GS/godot" <<'STUB'
#!/usr/bin/env bash
S="$(dirname "$0")"; P=""; imp=0
while [ $# -gt 0 ]; do case "$1" in --path) P="$2"; shift;; --import) imp=1;; esac; shift; done
C="$P/.godot/global_script_class_cache.cfg"
if [ $imp = 1 ]; then
  echo x >> "$S/imports"; rm -f "$S/needs_import"; mkdir -p "$P/.godot"
  { echo 'list=[{'; grep -r -m1 -H --include='*.gd' --exclude-dir='.?*' '^class_name ' "$P" | while IFS= read -r l; do r="${l#"$P"/}"; printf '"class": &"%s",\n"path": "res://%s"\n' "${l##*class_name }" "${r%%:*}"; done; echo '}]'; } > "$C"
  exit 0
fi
id="$(sed -n 's/^id=//p' "$WARMD_DIR/job.txt" | tr -d '\r')"; stale=0
while IFS= read -r p; do [ -f "$P/${p#res://}" ] || stale=1; done < <(sed -n 's/^"path": "\(.*\)"$/\1/p' "$C" 2>/dev/null)
if [ $stale = 1 ] || [ -f "$S/needs_import" ] || [ -n "${STUB_HIDES:-}" ]; then
  echo 'SCRIPT ERROR: Parse Error: Class "OrbitPreview" hides a global script class.'
  printf '%s FAIL\nscripts/orbit/orbit_preview.gd does not parse\n' "$id" > "$WARMD_DIR/result.txt"; exit 0
fi
printf '%s OK\n1 scripts parse\n' "$id" > "$WARMD_DIR/result.txt"
STUB
chmod +x "$GS/godot"
WARMD_GODOT="$GS/godot" "$WARMD" build >/dev/null 2>&1; rm -f "$GS/imports"
expect "the stub engine built a class cache with the old path" 'res://scripts/ui/orbit_preview.gd' "$(cat .godot/global_script_class_cache.cfg 2>&1)"
mkdir -p scripts/orbit; git mv scripts/ui/orbit_preview.gd scripts/orbit/orbit_preview.gd; git commit -qm move
imports() { if [ -f "$GS/imports" ]; then wc -l < "$GS/imports" | tr -d ' '; else echo 0; fi; }
out="$(WARMD_GODOT="$GS/godot" "$WARMD" build 2>&1)"
expect "a cache that names the moved script is renewed, the compile is green" 'scripts parse' "$out"
refuse "no hides error reaches the build" 'hides a global script class|FAIL' "$out"
expect "it took one import" '^1$' "$(imports)"
WARMD_GODOT="$GS/godot" "$WARMD" build >/dev/null 2>&1
expect "a fresh cache costs no import" '^1$' "$(imports)"
touch "$GS/needs_import"
out="$(WARMD_GODOT="$GS/godot" "$WARMD" build 2>&1)"
expect "a hides error the check did not foresee: one import, then green" 'scripts parse' "$out"
expect "that retry says why" 'class cache named a script twice' "$out"
expect "the retry took one import" '^2$' "$(imports)"
out="$(STUB_HIDES=1 WARMD_GODOT="$GS/godot" "$WARMD" build 2>&1)"; rc=$?
expect "a hides error that stays after the import is red" 'does not parse' "$out"
[ "$rc" != 0 ] && ok "its build exits non-zero" || no "its build exits 0"
expect "it is retried once, not in a loop" '^3$' "$(imports)"

# ---- godot: a runner that does not parse or compile is red, also when the engine ends with exit 0 ----
GR="$TMP/godot-runners"; mkdir -p "$GR/tests"; printf 'extends SceneTree\n' > "$GR/tests/run_login.gd"
# Stub engine: exit 0 always, prints what Godot 4 prints for a broken script when GODOT_STUB_OUT says so
printf '#!/usr/bin/env bash\nprintf "Godot Engine v4.7.stable\\n%%b" "${GODOT_STUB_OUT:-}"\nexit 0\n' > "$TMP/godot-stub"; chmod +x "$TMP/godot-stub"
runners() { GODOT_STUB_OUT="$1" bash -c "CFG_idle_min=5; . '$HERE/lib/platform.sh'; . '$HERE/adapters/godot.sh'; PROJECT='$GR'; TIMEOUT=30; run_runners '$TMP/godot-stub' '$GR/tests/run_login.gd'; echo rc=\$?"; }
out="$(runners 'SCRIPT ERROR: Parse Error: Expected end of statement\n   at: GDScript::reload (res://tests/run_login.gd:12)\nERROR: Failed to load script "res://tests/run_login.gd" with error "Parse error".\n')"
expect "a runner with a parse error is red although Godot exits 0" 'FAIL runner tests/run_login.gd does not load: SCRIPT ERROR: Parse Error' "$out"
expect "its run returns non-zero, so no green is cached" '^rc=1$' "$out"
out="$(runners 'SCRIPT ERROR: Compile Error: Identifier not found: SyncClock\nERROR: Failed to load script "res://tests/run_login.gd" with error "Compilation failed".\n=== 27 ok, 0 fehlgeschlagen ===\n')"
expect "a runner that does not compile is red although it printed its ok line" 'FAIL runner tests/run_login.gd does not load: SCRIPT ERROR: Compile Error' "$out"
out="$(runners '=== Ergebnis: 3 bestanden, 0 fehlgeschlagen ===\n')"
expect "a clean runner stays green" '1 runners passed' "$out"
expect "a clean runner returns 0" '^rc=0$' "$out"

# ---- split: files split by spaces stay separate entries, "lib bin" is not the path "libbin" ----
mkdir -p "$TMP/sp" && cd "$TMP/sp" || exit 1
git init -q -b main .; git config user.name t; git config user.email t@example.com
printf '.warmd\n' > .gitignore; git add .gitignore; git commit -qm init
printf 'sp | tidy | y | lib bin, adapters/a.sh\n' > "$TMP/sp.txt"
WARMD_NO_PREWARM=1 "$WARMD" split "$TMP/sp.txt" >/dev/null 2>&1
expect "a task lists files split by spaces as separate entries" '^Files you own: lib,bin,adapters/a.sh$' "$(cat .warmd/tasks/sp.md 2>&1)"
expect "the shared brief lists them the same way" '^- sp: lib,bin,adapters/a.sh$' "$(cat "$(git rev-parse --path-format=absolute --git-common-dir)/warmd-shared.md" 2>&1)"
"$WARMD" batch-done >/dev/null 2>&1

echo
[ $fails = 0 ] && echo "all green" || echo "$fails failed"
cd "$HERE" || exit 1; rm -rf "$TMP" 2>/dev/null
exit $fails
