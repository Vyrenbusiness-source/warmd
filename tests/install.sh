#!/usr/bin/env bash
# Install from scratch as a fresh user: empty HOME, warmd not on PATH, source is this working tree. No network.
# Never touches the real ~/.warmd, ~/.bashrc or the Windows user PATH (WARMD_NO_WINPATH=1, and the test checks that).
set -u
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
export XDG_CACHE_HOME="$TMP/cache" WARMD_NO_WINPATH=1
unset WARMD_BIN WARMD_DIR_INSTALL WARMD_VERSION_TAG WARMD_GIT_BASH
case "${OSTYPE:-}" in msys*|cygwin*|mingw*) WIN=1;; *) WIN=0;; esac
fails=0
ok() { echo "ok   $1"; }
no() { echo "FAIL $1"; fails=$((fails+1)); }
expect() { if echo "$3" | grep -qE -- "$2"; then ok "$1"; else no "$1: wanted /$2/, got: $(echo "$3" | tail -4)"; fi; }
lacks() { if echo "$3" | grep -qE -- "$2"; then no "$1: did not want /$2/, got: $(echo "$3" | grep -E -- "$2" | head -2)"; else ok "$1"; fi; }

# The source repo: this working tree as one commit, so uncommitted changes are tested too
SRC="$TMP/src"; mkdir -p "$SRC"
(cd "$HERE" && git ls-files -co --exclude-standard -z | tr '\0' '\n' | while IFS= read -r f; do [ -f "$f" ] && printf '%s\0' "$f"; done | tar -cf - --null -T -) | tar -xf - -C "$SRC"
git -C "$SRC" init -q -b main && git -C "$SRC" -c user.name=t -c user.email=t@example.com add -A && git -C "$SRC" -c user.name=t -c user.email=t@example.com commit -qm src
export WARMD_REPO="$SRC"

# A PATH without any warmd, as on a new machine
CLEAN=""; IFS=: read -ra parts <<< "$PATH"
for p in "${parts[@]}"; do [ -x "$p/warmd" ] || [ -f "$p/warmd.cmd" ] || CLEAN="${CLEAN:+$CLEAN:}$p"; done
H="$TMP/home one"; mkdir -p "$H"
fresh() { env -u WARMD_HOME HOME="$H" PATH="$CLEAN" "$@"; }

[ "$WIN" = 1 ] && userpath() { powershell.exe -NoProfile -Command '(Get-Item HKCU:\Environment).GetValue("Path","",[Microsoft.Win32.RegistryValueOptions]::DoNotExpandEnvironmentNames)' 2>/dev/null | tr -d '\r'; }
[ "$WIN" = 1 ] && before="$(userpath)"

# ---- install.sh from Git Bash ----
out="$(fresh bash "$SRC/install.sh" 2>&1)"; rc=$?
expect "install.sh succeeds in an empty HOME (rc=$rc)" '^OK warmd installed' "$out"
[ -x "$H/.local/bin/warmd" ] && [ -f "$H/.warmd/bin/warmd" ] && ok "warmd in ~/.warmd, link in ~/.local/bin" || no "install layout: $(ls -R "$H" | head -5)"
expect "bashrc gets the PATH line" 'local/bin:\$PATH"  # warmd' "$(cat "$H/.bashrc" 2>/dev/null)"
expect "install names the next step" 'next: .*warmd init' "$out"

mkdir -p "$TMP/proj"; echo 'module x' > "$TMP/proj/go.mod"
# A new terminal of the fresh user: only ~/.bashrc puts warmd on PATH
st="$(cd "$TMP/proj" && fresh bash -c '. ~/.bashrc; command -v warmd && warmd status' 2>&1)"
expect "fresh user: new shell finds warmd" '\.local/bin/warmd' "$st"
expect "fresh user: warmd status works" 'go project at' "$st"

doc="$(cd "$TMP/proj" && fresh bash "$H/.local/bin/warmd" doctor 2>&1)"
expect "doctor names warmd missing on PATH with the fix" "MISSING warmd on PATH.*Fix: echo 'export PATH=" "$doc"
expect "doctor names the missing repo with the fix" 'not a git repo.*Fix: git init' "$doc"
expect "doctor checks bash" '^ok bash [0-9]' "$doc"
expect "doctor checks python for hooks" '^(ok python|MISSING python .*Fix: )' "$doc"
doc="$(cd "$TMP/proj" && fresh bash -c '. ~/.bashrc; warmd doctor' 2>&1)"
expect "doctor after install: warmd on PATH" '^ok warmd on PATH' "$doc"
lacks "doctor after install: nothing missing besides python" '^MISSING (warmd|git|bash|powershell)' "$doc"

out="$(fresh bash "$SRC/install.sh" 2>&1)"
expect "second run updates in place" '^OK warmd installed' "$out"
[ "$(grep -c '# warmd' "$H/.bashrc")" = 1 ] && ok "second run adds no second PATH line" || no "bashrc: $(cat "$H/.bashrc")"
out="$(cd "$TMP/proj" && fresh bash -c '. ~/.bashrc; bash "$WARMD_REPO/install.sh"' 2>&1)"
expect "on PATH already: next step is warmd init" '^next: in your project run: warmd init' "$out"

mkdir -p "$TMP/junk"; echo x > "$TMP/junk/f"
out="$(fresh env WARMD_DIR_INSTALL="$TMP/junk" bash "$SRC/install.sh" 2>&1)"; rc=$?
[ $rc != 0 ] && expect "a foreign folder is not overwritten" 'FAIL .*not a warmd install.*Fix:' "$out" || no "foreign folder: rc=$rc $out"

if [ "$WIN" = 1 ]; then
  # Git Bash keeps git in /mingw64/bin and /cmd, /usr/bin alone has none
  out="$(env HOME="$TMP/nogit" PATH=/usr/bin /usr/bin/bash "$SRC/install.sh" 2>&1)"; rc=$?
  [ $rc != 0 ] && expect "no git: exact fix" 'FAIL git missing. Fix: winget install --id Git.Git -e' "$out" || no "no git: rc=$rc $out"

  [ -f "$H/.local/bin/warmd.cmd" ] && ok "warmd.cmd written" || no "warmd.cmd missing"
  winbin="$(cygpath -w "$H/.local/bin")"
  st="$(cd "$TMP/proj" && fresh cmd.exe //c "$winbin\\warmd.cmd" status 2>&1 | tr -d '\r')"
  expect "cmd: warmd.cmd status" 'go project at' "$st"
  # PowerShell resolves warmd through PATHEXT to warmd.cmd, the extensionless bash link next to it must not get in the way
  st="$(cd "$TMP/proj" && fresh env T_BIN="$winbin" powershell.exe -NoProfile -Command '$env:Path = $env:T_BIN + ";" + $env:Path; warmd status' 2>&1 | tr -d '\r')"
  expect "PowerShell: warmd status" 'go project at' "$st"
  doc="$(cd "$TMP/proj" && fresh bash -c '. ~/.bashrc; warmd doctor' 2>&1)"
  expect "doctor: warmd.cmd reachable" '^ok warmd.cmd for PowerShell and cmd' "$doc"

  # ---- install.ps1, the one line for PowerShell ----
  H2="$TMP/home two"; mkdir -p "$H2"
  ps() { env -u WARMD_HOME HOME="$(cygpath -w "$H2")" USERPROFILE="$(cygpath -w "$H2")" PATH="$CLEAN" "$@" powershell.exe -NoProfile -ExecutionPolicy Bypass -File "$(cygpath -w "$SRC/install.ps1")" 2>&1 | tr -d '\r'; }
  out="$(ps)"
  expect "install.ps1 finds Git Bash" '^OK Git Bash: .*bash\.exe' "$out"
  expect "install.ps1 installs and warmd runs in that window" '^OK warmd works in this window' "$out"
  [ -f "$H2/.warmd/bin/warmd" ] && [ -f "$H2/.local/bin/warmd.cmd" ] && ok "install.ps1 layout" || no "install.ps1 layout: $(ls -R "$H2" | head -5)"
  out="$(ps WARMD_GIT_BASH='C:\nowhere\bash.exe')"
  expect "install.ps1 without Git: exact fix, no winget" 'FAIL Git for Windows \(Git Bash\) not found. Fix: winget install --id Git.Git -e' "$out"
  lacks "install.ps1 without Git: no winget run" 'installing it with winget' "$out"

  # The one line itself: irm | iex has no script file and must not close the window
  H2="$TMP/home iex"; mkdir -p "$H2"
  out="$(env -u WARMD_HOME HOME="$(cygpath -w "$H2")" USERPROFILE="$(cygpath -w "$H2")" PATH="$CLEAN" WARMD_INSTALL_SH="$(cygpath -m "$SRC/install.sh")" T_PS1="$(cygpath -w "$SRC/install.ps1")"     powershell.exe -NoProfile -Command 'Get-Content -Raw -LiteralPath $env:T_PS1 | Invoke-Expression; "window still open"; warmd status' 2>&1 | tr -d '')"
  expect "irm | iex: installs" '^OK warmd works in this window' "$out"
  expect "irm | iex: window stays open" '^window still open' "$out"
  expect "irm | iex: warmd runs in the same window" 'warmd [0-9.]+: ' "$out"

  [ "$(userpath)" = "$before" ] && ok "real user PATH untouched" || no "user PATH changed during the test"
fi

echo "$fails failed"
[ "$fails" = 0 ]
