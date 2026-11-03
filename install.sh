#!/usr/bin/env bash
# Installs warmd to ~/.warmd and links it into ~/.local/bin. Run it again to update.
# On Windows (Git Bash) it also writes warmd.cmd and puts that folder on the user PATH, so PowerShell and cmd find warmd too.
# Opt out: WARMD_NO_PROFILE=1 (no ~/.bashrc line), WARMD_NO_WINPATH=1 (no user PATH change). WARMD_REPO picks another source.
set -eu
DIR="${WARMD_DIR_INSTALL:-$HOME/.warmd}"
BIN="${WARMD_BIN:-$HOME/.local/bin}"
REPO="${WARMD_REPO:-https://github.com/Vyrenbusiness-source/warmd-fewer-tokens-faster-agents.git}"
STAR="https://github.com/Vyrenbusiness-source/warmd-fewer-tokens-faster-agents"
case "${OSTYPE:-$(uname -s)}" in msys*|cygwin*|mingw*|MINGW*|MSYS*|CYGWIN*) WIN=1;; *) WIN=0;; esac
command -v git >/dev/null 2>&1 || {
  if [ "$WIN" = 1 ]; then echo "FAIL git missing. Fix: winget install --id Git.Git -e, then open Git Bash and run this again"
  else echo "FAIL git missing. Fix: install git with your package manager, then run this again"; fi
  exit 1
}
if [ -d "$DIR/.git" ]; then git -C "$DIR" pull -q --ff-only || { echo "FAIL could not update $DIR (local changes?). Fix: git -C \"$DIR\" status"; exit 1; }
elif [ -e "$DIR" ] && [ -n "$(ls -A "$DIR" 2>/dev/null)" ]; then echo "FAIL $DIR exists and is not a warmd install. Fix: move it away or set WARMD_DIR_INSTALL"; exit 1
else git clone -q --depth 1 ${WARMD_VERSION_TAG:+--branch "$WARMD_VERSION_TAG"} "$REPO" "$DIR"; fi
mkdir -p "$BIN"
printf '#!/usr/bin/env bash\nexec bash "%s/bin/warmd" "$@"\n' "$DIR" > "$BIN/warmd"
chmod +x "$BIN/warmd" "$DIR/bin/warmd"
echo "OK warmd installed to $BIN/warmd"

# Git Bash: a new shell finds warmd through ~/.bashrc. Git Bash reads ~/.bash_profile first, which must source ~/.bashrc.
line="export PATH=\"$BIN:\$PATH\"  # warmd"
case ":$PATH:" in *":$BIN:"*) onpath=1;; *) onpath=0;; esac
if [ "${WARMD_NO_PROFILE:-0}" != 1 ] && ! grep -qsF "$line" "$HOME/.bashrc"; then
  [ "$onpath" = 1 ] || { printf '%s\n' "$line" >> "$HOME/.bashrc"; echo "OK PATH line added to ~/.bashrc"; }
fi
if [ "$WIN" = 1 ] && [ "${WARMD_NO_PROFILE:-0}" != 1 ] && [ -f "$HOME/.bash_profile" ] && ! grep -qs 'bashrc' "$HOME/.bash_profile"; then
  printf '[ -f ~/.bashrc ] && . ~/.bashrc  # warmd\n' >> "$HOME/.bash_profile"
fi

if [ "$WIN" = 1 ]; then
  # PowerShell and cmd: warmd.cmd starts Git Bash's launcher, which brings its own tools onto PATH.
  root="$(cygpath -w /)"; bash_exe="${root%\\}\\bin\\bash.exe"
  [ -f "$(cygpath -u "$bash_exe")" ] || bash_exe="$(cygpath -w /usr/bin/bash.exe)"
  printf '@echo off\r\n"%s" "%s/bin/warmd" %%*\r\n' "$bash_exe" "$(cygpath -m "$DIR")" > "$BIN/warmd.cmd"
  winbin="$(cygpath -w "$BIN")"
  echo "OK warmd.cmd for PowerShell and cmd in $winbin"
  if [ "${WARMD_NO_WINPATH:-0}" != 1 ]; then
    # Read and write the raw registry value: [Environment]::SetEnvironmentVariable would expand %VARS% in the user PATH for good.
    if WARMD_WINBIN="$winbin" powershell.exe -NoProfile -NonInteractive -Command '
      $k = Get-Item -Path "HKCU:\Environment"; $d = $env:WARMD_WINBIN
      $p = [string]$k.GetValue("Path", "", [Microsoft.Win32.RegistryValueOptions]::DoNotExpandEnvironmentNames)
      if (($p -split ";") -contains $d) { "present"; exit 0 }
      $n = (($p.TrimEnd(";") + ";" + $d).TrimStart(";"))
      New-ItemProperty -Path "HKCU:\Environment" -Name Path -Value $n -PropertyType ExpandString -Force | Out-Null
      [Environment]::SetEnvironmentVariable("WARMD_PATH_SET", "1", "User"); [Environment]::SetEnvironmentVariable("WARMD_PATH_SET", $null, "User")
      "added"' 2>/dev/null | tr -d '\r' | grep -qx added; then echo "OK $winbin added to your user PATH, open a new PowerShell window"
    fi
  fi
fi
if [ "$onpath" = 1 ]; then echo "next: in your project run: warmd init"
else echo "next: open a new terminal (or run: export PATH=\"$BIN:\$PATH\"), then in your project: warmd init"; fi
echo "Saves you tokens or time? Star it: $STAR"
