#!/usr/bin/env bash
# Unity dotnet stage without Unity: a project csproj references an embedded package whose sources only compile inside Unity.
# warmd must take the package from Library/ScriptAssemblies, report only errors in Assets, and hand over to Unity when the Library lacks a referenced assembly.
# Needs dotnet, skips without it. Usage: bash tests/fixtures/unity/check.sh
set -u
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
WARMD="$HERE/bin/warmd"
command -v dotnet >/dev/null 2>&1 || { echo "SKIP unity dotnet stage: no dotnet"; exit 0; }
TMP="$(mktemp -d)"; export XDG_CACHE_HOME="$TMP/cache"
trap 'rm -rf "$TMP"' EXIT
fails=0
expect() { if echo "$3" | grep -qE "$2"; then echo "ok   $1"; else echo "FAIL $1: wanted /$2/, got: $(echo "$3" | head -3)"; fails=$((fails+1)); fi; }
refuse() { if echo "$3" | grep -qE "$2"; then echo "FAIL $1: $(echo "$3" | grep -E "$2" | head -2)"; fails=$((fails+1)); else echo "ok   $1"; fi; }

# What Unity would have compiled into the Library
mkdir -p "$TMP/pkg"; cp "$HERE/tests/fixtures/unity/pkgsrc/Util.cs" "$TMP/pkg/"
printf '<Project Sdk="Microsoft.NET.Sdk"><PropertyGroup><TargetFramework>net$(BundledNETCoreAppTargetFrameworkVersion)</TargetFramework><AssemblyName>Vendor.Pkg</AssemblyName></PropertyGroup></Project>\n' > "$TMP/pkg/Pkg.csproj"
( cd "$TMP/pkg" && dotnet build -nologo -v q -o out >/dev/null 2>&1 ) || { echo "FAIL could not build the package dll"; exit 1; }

P="$TMP/game"; mkdir -p "$P"
cp -R "$HERE/tests/fixtures/unity/." "$P/"; rm -rf "$P/pkgsrc" "$P/check.sh"
mkdir -p "$P/Library/ScriptAssemblies"; cp "$TMP/pkg/out/Vendor.Pkg.dll" "$P/Library/ScriptAssemblies/"
cd "$P" || exit 1
git init -q -b main .; git config core.autocrlf false; git config user.name t; git config user.email t@example.com
printf 'Library/\nTemp/\n.warmd/\n' > .gitignore; git add -A; git commit -qm init

out="$("$WARMD" build 2>&1)"
expect "an embedded package comes from Library/ScriptAssemblies" 'OK .*compile' "$out"
refuse "package sources are never compiled" 'Packages/|UnityOnly' "$out"

sed -i.bak 's/Vendor.Pkg.Util.Double(a)/Vendor.Pkg.Util.Double(b)/' Assets/Game.cs; rm -f Assets/Game.cs.bak
out="$("$WARMD" build 2>&1)"
expect "a real error in Assets is named" 'Assets/Game.cs:5 CS0103' "$out"
refuse "only the real error is named" 'Packages/|UnityOnly' "$out"
git checkout -q Assets/Game.cs

rm "$P/Library/ScriptAssemblies/Vendor.Pkg.dll"
out="$("$WARMD" build 2>&1)"
expect "a Library without the package dll hands over to Unity" 'Library lacks 1 referenced assemblies.*Vendor.Pkg.dll.*compiling in Unity' "$out"
refuse "no false errors without the dll" 'CS0234|CS0246|CS0103' "$out"

# A newer warmd renews the daemon copy in the project before a Unity run, init only made it once
mkdir -p "$P/Assets/Editor/Warmd"; echo "// old daemon" > "$P/Assets/Editor/Warmd/WarmdDaemon.cs"; cp "$HERE/unity/Warmd.Editor.asmdef" "$P/Assets/Editor/Warmd/"
out="$(WARMD_UNITY=/nonexistent/Unity "$WARMD" build 2>&1)"
expect "an old daemon copy is renewed and named" '^\(daemon updated to [0-9.]+: WarmdDaemon.cs\)$' "$out"
cmp -s "$HERE/unity/WarmdDaemon.cs" "$P/Assets/Editor/Warmd/WarmdDaemon.cs" && echo "ok   the project copy equals the installed daemon" || { echo "FAIL project daemon copy not renewed"; fails=$((fails+1)); }
refuse "a current copy is left alone" 'daemon updated' "$(WARMD_UNITY=/nonexistent/Unity "$WARMD" build 2>&1)"

# check never runs the whole PlayMode suite outside the merge gate
pa() { ( cd "$P" && WARMD_HOME="$HERE" && . "$HERE/lib/platform.sh" && . "$HERE/lib/core.sh" && detect_project >/dev/null 2>&1 && . "$HERE/adapters/unity.sh" && a_test() { echo "a_test $*"; } && unity_play_all ); }
out="$(pa)"; expect "check skips the full PlayMode suite" '^\(PlayMode: no affected test class to pick, the full PlayMode suite runs in the merge gate or with WARMD_FULL=1\)$' "$out"
refuse "no PlayMode run without WARMD_FULL" 'a_test' "$out"
expect "WARMD_FULL=1 runs it" '^a_test --play$' "$(WARMD_FULL=1 pa)"
expect "the merge gate runs it" '^a_test --play$' "$(WARMD_IN_MERGE=1 pa)"

[ $fails = 0 ] && echo "unity dotnet stage green" || echo "unity dotnet stage: $fails failed"
exit $fails
