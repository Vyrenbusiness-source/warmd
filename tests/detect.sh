#!/usr/bin/env bash
# Project detection: a git root with its own warmd.conf (or warmd state) is the project, a package.json in a tooling
# subfolder (warmd's own vscode/) never takes over, an engine project in a subfolder is still found, WARMD_PROJECT wins.
set -u
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WARMD="$HERE/bin/warmd"
TMP="$(mktemp -d)"
export XDG_CACHE_HOME="$TMP/cache"
fails=0
ok() { echo "ok   $1"; }
no() { echo "FAIL $1"; fails=$((fails+1)); }
# head names the project: "warmd <v>: <kind> project at <path>" or "no known project type at <path>"
head_of() { ( cd "$1" && bash "$WARMD" status 2>&1 | head -1 ); }
expect() { # name dir kind-regex path-suffix [env]
  local got; got="$(head_of "$2")"
  if printf '%s\n' "$got" | grep -qE -- "$3" && printf '%s\n' "$got" | grep -qE -- "$4\$"; then ok "$1"; else no "$1: wanted /$3/ at */$4, got: $got"; fi
}
repo() { mkdir -p "$1"; ( cd "$1" && git init -q -b main . && git config user.name t && git config user.email t@example.com ); }

# The warmd repo itself: warmd.conf at the root, an editor extension with package.json in vscode/
R="$TMP/tool"; repo "$R"; printf 'test=true\nfloor=top\n' > "$R/warmd.conf"
mkdir -p "$R/vscode"; echo '{}' > "$R/vscode/package.json"
expect "root with warmd.conf beats vscode/package.json" "$R" "no known project type" "tool"
expect "started inside vscode/, still the root" "$R/vscode" "no known project type" "tool"
[ ! -d "$R/vscode/.warmd" ] && ok "no state written into vscode/" || no "state written into vscode/"

# No warmd.conf: a tooling folder alone still never wins
T="$TMP/plain"; repo "$T"; mkdir -p "$T/vscode" "$T/docs"; echo '{}' > "$T/vscode/package.json"; echo '<html>' > "$T/docs/index.html"
expect "tooling folders without warmd.conf: root" "$T" "no known project type" "plain"

# WARMD_PROJECT always wins, even on a root without warmd.conf next to a real web app
W="$TMP/env"; repo "$W"; mkdir -p "$W/app"; echo '{}' > "$W/app/package.json"
# first: the WARMD_PROJECT run below writes state at the root, which then anchors it
expect "no conf, web app in a subfolder: the subfolder" "$W" "web project" "env/app"
got="$(cd "$TMP" && WARMD_PROJECT="$W" bash "$WARMD" status 2>&1 | head -1)"
case "$got" in *"no known project type at "*env) ok "WARMD_PROJECT wins over a subfolder marker";; *) no "WARMD_PROJECT: got $got";; esac

# .warmd/ci.wait from warmd ship alone does not anchor the root
S="$TMP/shipped"; repo "$S"; mkdir -p "$S/.warmd" "$S/app"; : > "$S/.warmd/ci.wait"; echo '{}' > "$S/app/package.json"
expect "ci.wait alone does not anchor the root" "$S" "web project" "shipped/app"

# Engines in a subfolder: found without warmd.conf, and still found with one
U="$TMP/u"; repo "$U"; mkdir -p "$U/Game/ProjectSettings"; echo 'm_EditorVersion: 2022.3.0f1' > "$U/Game/ProjectSettings/ProjectVersion.txt"
expect "unity in a subfolder of a repo without warmd.conf" "$U" "unity project" "u/Game"
G="$TMP/g"; repo "$G"; mkdir -p "$G/game" "$G/vscode"; echo 'config_version=5' > "$G/game/project.godot"; echo '{}' > "$G/vscode/package.json"
printf 'agents=2\n' > "$G/warmd.conf"
expect "godot in a subfolder beats an anchored root" "$G" "godot project" "g/game"

rm -rf "$TMP"
echo "detect: $fails failed"
exit $fails
