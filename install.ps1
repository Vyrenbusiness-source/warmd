# Installs warmd on Windows from PowerShell. One line:
#   irm https://raw.githubusercontent.com/Vyrenbusiness-source/warmd-fewer-tokens-faster-agents/main/install.ps1 | iex
# Finds Git for Windows (installs it with winget if missing), then runs install.sh in Git Bash:
# warmd goes to ~/.warmd, warmd and warmd.cmd to ~/.local/bin, that folder onto PATH for Git Bash and PowerShell.
# Run it again to update. Options as environment variables:
#   WARMD_NO_GIT_INSTALL=1  never run winget, only report what is missing
#   WARMD_GIT_BASH=<path>   use this bash.exe from Git for Windows
#   WARMD_INSTALL_SH=<path> run this install.sh instead of downloading it
#   WARMD_NO_WINPATH=1, WARMD_NO_PROFILE=1, WARMD_REPO, WARMD_VERSION_TAG: passed on to install.sh

function Find-GitBash {
  if ($env:WARMD_GIT_BASH) { if (Test-Path -LiteralPath $env:WARMD_GIT_BASH) { return $env:WARMD_GIT_BASH } else { return $null } }
  $roots = @()
  $git = Get-Command git.exe -ErrorAction SilentlyContinue | Select-Object -First 1
  if ($git) { $roots += (Split-Path (Split-Path $git.Source)) }
  foreach ($key in 'HKLM:\SOFTWARE\GitForWindows', 'HKCU:\SOFTWARE\GitForWindows') {
    $p = (Get-ItemProperty -Path $key -Name InstallPath -ErrorAction SilentlyContinue).InstallPath
    if ($p) { $roots += $p }
  }
  $roots += (Join-Path $env:ProgramFiles 'Git')
  if ($env:LOCALAPPDATA) { $roots += (Join-Path $env:LOCALAPPDATA 'Programs\Git') }
  # Never bash from PATH: C:\Windows\System32\bash.exe is WSL, not Git Bash.
  foreach ($r in $roots) {
    $b = Join-Path $r 'bin\bash.exe'
    if (Test-Path -LiteralPath $b) { return $b }
  }
  return $null
}

function Install-Warmd {
  $bash = Find-GitBash
  if (-not $bash -and $env:WARMD_NO_GIT_INSTALL -ne '1' -and -not $env:WARMD_GIT_BASH) {
    if (Get-Command winget.exe -ErrorAction SilentlyContinue) {
      Write-Host 'Git for Windows is missing, installing it with winget'
      winget install --id Git.Git -e --source winget --accept-package-agreements --accept-source-agreements --silent | Out-Host
      $bash = Find-GitBash
    }
  }
  if (-not $bash) {
    Write-Host 'FAIL Git for Windows (Git Bash) not found. Fix: winget install --id Git.Git -e, or get it from https://git-scm.com/download/win, then run this again'
    return 1
  }
  Write-Host "OK Git Bash: $bash"

  $script = $null
  if ($env:WARMD_INSTALL_SH) { $script = $env:WARMD_INSTALL_SH }
  elseif ($PSScriptRoot -and (Test-Path -LiteralPath (Join-Path $PSScriptRoot 'install.sh'))) { $script = Join-Path $PSScriptRoot 'install.sh' }
  else {
    [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor 3072
    $url = 'https://raw.githubusercontent.com/Vyrenbusiness-source/warmd-fewer-tokens-faster-agents/main/install.sh'
    $script = Join-Path ([IO.Path]::GetTempPath()) ('warmd-install-' + [guid]::NewGuid().ToString('N') + '.sh')
    try { Invoke-RestMethod -Uri $url -OutFile $script -UseBasicParsing }
    catch { Write-Host "FAIL could not download $url ($($_.Exception.Message)). Fix: check the connection, or run in Git Bash: curl -fsSL $url | bash"; return 1 }
  }
  & $bash $script.Replace('\', '/') | Out-Host
  if ($LASTEXITCODE -ne 0) { Write-Host "FAIL install.sh ended with $LASTEXITCODE, the line above names the cause"; return $LASTEXITCODE }

  # This window finds warmd at once, new windows through the user PATH.
  # No double quotes in arguments: Windows PowerShell 5.1 passes them to native programs unescaped. IFS= keeps spaces whole.
  $winbin = (& $bash -c 'IFS=; cygpath -w ${WARMD_BIN:-$HOME/.local/bin}' | Out-String).Trim()
  if ($winbin -and (($env:Path -split ';') -notcontains $winbin)) { $env:Path = "$winbin;$env:Path" }
  if (-not (Get-Command warmd -ErrorAction SilentlyContinue)) { Write-Host "FAIL warmd.cmd not found in $winbin. Fix: run this again, or warmd doctor in Git Bash"; return 1 }
  Write-Host 'OK warmd works in this window: warmd status'
  return 0
}

$rc = Install-Warmd
# A script file reports its result. Under irm | iex there is no file, and exit would close the user's window.
if ($PSCommandPath) { exit $rc }
