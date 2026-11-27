#!/usr/bin/env bash
# Unity without Unity: warmd's own files in a project (Assets/Editor/Warmd, copied from unity/ by warmd init) follow a newer
# warmd on every build, test and check. No editor, no dotnet: the adapter is sourced and the Unity runs are stubbed.
# Usage: bash tests/unity.sh
set -u
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP="$(mktemp -d)"; export XDG_CACHE_HOME="$TMP/cache"
trap 'rm -rf "$TMP"' EXIT
fails=0
expect() { if echo "$3" | grep -qE "$2"; then echo "ok   $1"; else echo "FAIL $1: wanted /$2/, got: $(echo "$3" | head -3)"; fails=$((fails+1)); fi; }
refuse() { if echo "$3" | grep -qE "$2"; then echo "FAIL $1: $(echo "$3" | grep -E "$2" | head -2)"; fails=$((fails+1)); else echo "ok   $1"; fi; }
same() { if cmp -s "$2" "$3"; then echo "ok   $1"; else echo "FAIL $1"; fails=$((fails+1)); fi; }

P="$TMP/game"; W="$P/Assets/Editor/Warmd"
mkdir -p "$P/ProjectSettings" "$P/Packages" "$W"
cp "$HERE/tests/fixtures/unity/ProjectSettings/ProjectVersion.txt" "$P/ProjectSettings/"
printf '{\n  "dependencies": {\n    "com.unity.test-framework": "1.6.0"\n  }\n}\n' > "$P/Packages/manifest.json"
cp "$HERE"/unity/* "$W/"
# The .meta files Unity wrote at import: their GUIDs are what other assets reference
printf 'fileFormatVersion: 2\nguid: 0123456789abcdef0123456789abcdef\n' > "$W/WarmdDaemon.cs.meta"
printf 'fileFormatVersion: 2\nguid: fedcba9876543210fedcba9876543210\n' > "$W/Warmd.Editor.asmdef.meta"
printf 'class MyTool {}\n' > "$W/MyTool.cs"   # the project's own file next to warmd's
cp "$W"/*.meta "$W/MyTool.cs" "$TMP/"
cd "$P" || exit 1
git init -q -b main .; git config core.autocrlf false; git config user.name t; git config user.email t@example.com
printf 'Library/\nTemp/\n.warmd/\n' > .gitignore; git add -A; git commit -qm init

# One adapter entry point with the Unity side stubbed: a job, a cached run and the warm editor never start an engine
run() { ( cd "$P" && WARMD_HOME="$HERE" && WARMD_VERSION=9.9.9 && . "$HERE/lib/platform.sh" && . "$HERE/lib/core.sh" && detect_project >/dev/null 2>&1 && . "$HERE/adapters/unity.sh" \
  && job() { echo "job $*"; } && cached() { echo "cached $1"; } && daemon_alive() { return 1; } && csproj_fresh() { return 1; } && "$@" 2>&1 ); }
old() { echo "// old daemon" > "$W/WarmdDaemon.cs"; printf '{ "name": "Warmd.Editor" }\n' > "$W/Warmd.Editor.asmdef"; }
kept() {
  same "$1: WarmdDaemon.cs equals warmd's" "$HERE/unity/WarmdDaemon.cs" "$W/WarmdDaemon.cs"
  same "$1: Warmd.Editor.asmdef equals warmd's" "$HERE/unity/Warmd.Editor.asmdef" "$W/Warmd.Editor.asmdef"
  same "$1: the daemon's .meta and GUID stay" "$TMP/WarmdDaemon.cs.meta" "$W/WarmdDaemon.cs.meta"
  same "$1: the asmdef's .meta and GUID stay" "$TMP/Warmd.Editor.asmdef.meta" "$W/Warmd.Editor.asmdef.meta"
  same "$1: the project's own file stays" "$TMP/MyTool.cs" "$W/MyTool.cs"
}

for cmd in a_build a_test a_check; do
  old; out="$(run "$cmd")"
  expect "$cmd renews an old copy in one line" '^\(daemon updated to 9\.9\.9: Warmd\.Editor\.asmdef WarmdDaemon\.cs\)$' "$out"
  kept "$cmd"
  refuse "$cmd leaves a current copy alone" 'daemon updated' "$(run "$cmd")"
done
expect "check renews before its early OK on unchanged code" 'OK no code changed' "$(old; run a_check)"
git checkout -q -- Assets

# A checkout with CRLF line ends (core.autocrlf) is the same copy: not rewritten, not named on every run
sed 's/$/\r/' "$HERE/unity/WarmdDaemon.cs" > "$W/WarmdDaemon.cs"; cp "$W/WarmdDaemon.cs" "$TMP/crlf.cs"
refuse "a CRLF copy of the current daemon counts as current" 'daemon updated' "$(run a_build)"
same "and stays as it is" "$TMP/crlf.cs" "$W/WarmdDaemon.cs"
git checkout -q -- Assets

# Not installed (no warmd init yet): nothing is copied into the project
rm -rf "$W"
refuse "a project without the daemon gets nothing" 'daemon updated' "$(run a_build)"
[ -e "$W" ] && { echo "FAIL a project without the daemon got Assets/Editor/Warmd"; fails=$((fails+1)); } || echo "ok   no Assets/Editor/Warmd made without warmd init"

[ $fails = 0 ]
