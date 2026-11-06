# Unity: the warm thing is the editor, headless with -nographics. Job logic lives in unity/WarmdDaemon.cs.
UNITY_VER="$(sed -n 's/^m_EditorVersion: //p' "$PROJECT/ProjectSettings/ProjectVersion.txt" | tr -d '\r')"
EDITOR_DIR="$PROJECT/Assets/Editor/Warmd"
export WARMD_IDLE_MIN="${CFG_daemon_idle:-$CFG_idle_min}"

unity_exe() {
  if [ -n "${WARMD_UNITY:-}" ]; then echo "$WARMD_UNITY"; return; fi
  case "$OS" in
    win) echo "/c/Program Files/Unity/Hub/Editor/$UNITY_VER/Editor/Unity.exe";;
    mac) echo "/Applications/Unity/Hub/Editor/$UNITY_VER/Unity.app/Contents/MacOS/Unity";;
    *) echo "$HOME/Unity/Hub/Editor/$UNITY_VER/Editor/Unity";;
  esac
}
project_rx() { native_path "$PROJECT" | sed 's/[]().+*?^$|\\[]/\\&/g'; }
# Import workers run as Unity too, they carry -name AssetImportWorkerN
a_daemon_procs() { procs "Unity.*$(project_rx).*warmd-daemon" 'AssetImportWorker'; }
worker_procs() { procs "AssetImportWorker.*$(project_rx)" '^$'; }
foreign_unity() { procs "Unity.*$(project_rx)" 'AssetImportWorker|warmd-daemon|powershell' | head -1; }

a_kill_daemon() {
  local pid
  for pid in $(a_daemon_procs) $(daemon_pid); do kill_tree "$pid"; done
  nap 2
  for pid in $(worker_procs); do kill_tree "$pid"; done
  rm -f "$RUN/alive.txt" "$RUN/pid.txt"
}

# Another tool's editor on this project in a worktree of the running batch: when it runs in batchmode (no window, no user
# at it) it is ended cleanly and the start goes on. A window, or a worktree outside the batch, is never touched here.
unity_free_batch() {
  local f pid path flags me n=0
  f="$(git -C "$PROJECT" rev-parse --path-format=absolute --git-common-dir 2>/dev/null)/warmd-batch"
  [ -n "$GIT_ROOT" ] && [ -f "$f" ] && grep -qxF -e "$GIT_ROOT" -e "$(native_path "$GIT_ROOT")" "$f" || return 1
  me="$(native_path "$PROJECT")"; me="${me%/}"
  while IFS='	' read -r pid path flags; do
    [ -n "$pid" ] && [ "${path,,}" = "${me,,}" ] || continue
    case "$flags" in *d*) continue;; *b*) ;; *) return 1;; esac
    stop_gently "$pid" "${WARMD_STOP_GRACE:-15}" || return 1
    echo "(ended another tool's batchmode Unity pid $pid on this batch worktree, $STOP_HOW)"; n=$((n+1))
  done < <(unity_procs)
  [ $n -gt 0 ] && [ -z "$(foreign_unity)" ]
}

# warmd init copies the engine side once, a newer warmd brings a newer daemon: before every Unity run the project copy is
# compared with this install and replaced when it differs. A warm editor restarts, so Unity compiles the new code.
# Builtins only (read), no process start per run. A tracked copy shows as changed until it is committed; warmd merge takes it along.
unity_sync() {
  [ -f "$EDITOR_DIR/WarmdDaemon.cs" ] || return 0   # not installed: a_start_daemon says to run warmd init
  local f dst a b changed=""
  for f in "$WARMD_HOME"/unity/*; do
    [ -f "$f" ] || continue
    dst="$EDITOR_DIR/${f##*/}"; a=""; b=""
    IFS= read -r -d '' a < "$f"; [ -f "$dst" ] && IFS= read -r -d '' b < "$dst"
    [ "$a" = "$b" ] && continue
    cp "$f" "$dst" && changed="$changed ${f##*/}"
  done
  [ -n "$changed" ] || return 0
  echo "(daemon updated to $WARMD_VERSION:$changed)"
  if daemon_alive; then echo "(warm editor restarts for the new daemon)"; daemon_stop >/dev/null; fi
  return 0
}

a_start_daemon() {
  [ -f "$EDITOR_DIR/WarmdDaemon.cs" ] || { echo "FAIL run warmd init first"; exit 2; }
  unity_sync
  if [ -n "$(a_daemon_procs)" ]; then echo "(daemon not answering, restarting)"; a_kill_daemon; fi
  local other; other="$(foreign_unity)"
  if [ -n "$other" ] && ! unity_free_batch; then
    # Said on stdout, stderr and in result.txt: an agent that sends the output to a file still sees why the run stopped.
    # BLOCKED, not FAIL, in result.txt: a blocked start is no red test (lib/auto.sh auto_red), nobody escalates for it.
    local m="FAIL another Unity (pid $other) has this project open, nothing touched. In a batch worktree a batchmode editor is ended by itself; this one has a window or the worktree is in no batch: close it, or warmd stop --force"
    echo "$m"; echo "$m" >&2; echo "blocked BLOCKED ${m#FAIL }" > "$RUN/result.txt" 2>/dev/null
    exit 2
  fi
  rm -f "$RUN/alive.txt" "$RUN/state.txt" "$RUN/dialog.txt" "$RUN/screen.txt" "$RUN/spawn.pid"
  local exe gfx=(-nographics) batch=(-batchmode) win="${WARMD_WINDOW:-0}"; exe="$(unity_exe)"
  [ -x "$exe" ] || { echo "FAIL Unity $UNITY_VER not found, set WARMD_UNITY"; exit 2; }
  if [ "$win" = 1 ]; then batch=(); unity_window_prep || exit 2; fi
  [ "${WARMD_GFX:-0}" = 1 ] || [ "$win" = 1 ] && { gfx=(); gfx_take; gfx+=($(tune_unity_gpu_flag)); }
  [ "${WARMD_GFX:-0}" = 1 ] || [ "$win" = 1 ] && echo 1 > "$RUN/gfx.txt" || echo 0 > "$RUN/gfx.txt"   # gfx_tests: a headless daemon makes way
  echo "$win" > "$RUN/window.txt"
  # Each worktree gets a stable port block, so parallel daemons never collide and no agent has to think about it
  if [ -n "$CFG_port_env" ]; then
    export "$CFG_port_env=$(( 7830 + 10 * ( $(printf '%s' "$PROJECT" | cksum | cut -d' ' -f1) % 160 ) ))"
  fi
  export WARMD_DIR WARMD_WINDOW="$win" WARMD_MONITOR="${WARMD_MONITOR:-2}"; WARMD_DIR="$(native_path "$RUN")"
  # -logFile with warmd-daemon in the path is how the daemon is told from a human's editor
  SPAWN_STYLE="$([ "$win" = 1 ] && echo Normal || echo Hidden)" SPAWN_PID="$RUN/spawn.pid" \
    spawn "$RUN/unity_out.log" "$exe" "${batch[@]}" -job-worker-count "$(tune_unity_workers)" "${gfx[@]}" -projectPath "$(native_path "$PROJECT")" -logFile "$(native_path "$RUN/warmd-daemon.log")"
  if [ "$win" = 1 ]; then unity_wait_window 600; else wait_ready 600; fi
}

# warmd test --window (or WARMD_WINDOW=1): a visible editor for tests that need one, PlayMode screenshots for example.
# -monitor is a player argument, an editor ignores it: the daemon moves its own main window to monitor WARMD_MONITOR
# (default 2, monitor 1 is the primary) through Win32 and maximizes it there. A dialog would hold the start until the
# timeout, so the start removes what raises one and names any that still comes up.
unity_window_prep() {
  # Scene backups of an editor that died in PlayMode raise "Recovering Scene Backups" at the next start with a window
  rm -rf "$PROJECT/Temp/__Backupscenes"
  # A local package the manifest names but the disk lacks raises "Packages with Errors"
  local d p
  while IFS= read -r d; do
    [ -n "$d" ] || continue
    case "$d" in /*|[A-Za-z]:*) p="$d";; *) p="$PROJECT/Packages/$d";; esac
    [ -e "$p" ] || { echo "FAIL Packages/manifest.json names a local package that is missing: $d. A window editor would stop at the dialog Packages with Errors"; return 1; }
  done < <(sed -n 's/.*"file:\([^"]*\)".*/\1/p' "$PROJECT/Packages/manifest.json" 2>/dev/null | tr -d '\r')
  return 0
}

# Like wait_ready, and a modal dialog of the new editor ends the start at once with its title, text and buttons
unity_wait_window() { # seconds
  local i=0 d
  [ "$OS" = win ] && unity_dialog_watch "$1" >/dev/null 2>&1 &   # never holds the caller's output pipe open
  while :; do
    nap 1; i=$((i+1))
    if [ -f "$RUN/alive.txt" ] && daemon_alive; then break; fi
    if [ -s "$RUN/dialog.txt" ]; then
      d="$(tr -d '\r' < "$RUN/dialog.txt" | head -1 | cut -c1-300)"
      a_kill_daemon
      # Like a blocked start (a_start_daemon): on stdout, stderr and in result.txt, and no red test
      d="FAIL a dialog stops the window editor: $d. Editor ended, nothing answered"
      echo "$d"; echo "$d" >&2; echo "blocked BLOCKED ${d#FAIL }" > "$RUN/result.txt" 2>/dev/null; exit 2
    fi
    [ $i -gt "$1" ] && { echo "FAIL window editor not ready after ${1}s, see $(native_path "$RUN/warmd-daemon.log")"; a_kill_daemon; exit 1; }
  done
  i=0; while [ ! -s "$RUN/screen.txt" ] && [ $i -lt 20 ]; do nap 0.5; i=$((i+1)); done
  [ -s "$RUN/screen.txt" ] && echo "($(tr -d '\r' < "$RUN/screen.txt" | head -1))"
  return 0
}

# One PowerShell for the whole start: every second the visible dialogs (class #32770) of the editor pid. One with a known
# title or with two buttons or more is a question nobody answers; a progress window has one button at most.
unity_dialog_watch() { # seconds
  cat > "$RUN/dialog.ps1" <<'PS'
param([string]$PidFile, [string]$Alive, [string]$Out, [int]$Seconds)
Add-Type -TypeDefinition @'
using System; using System.Text; using System.Collections.Generic; using System.Runtime.InteropServices;
public static class WarmdDialog {
  delegate bool Cb(IntPtr h, IntPtr l);
  [DllImport("user32.dll")] static extern bool EnumWindows(Cb cb, IntPtr l);
  [DllImport("user32.dll")] static extern bool EnumChildWindows(IntPtr p, Cb cb, IntPtr l);
  [DllImport("user32.dll")] static extern uint GetWindowThreadProcessId(IntPtr h, out uint p);
  [DllImport("user32.dll")] static extern bool IsWindowVisible(IntPtr h);
  [DllImport("user32.dll", CharSet = CharSet.Unicode)] static extern int GetClassName(IntPtr h, StringBuilder s, int n);
  [DllImport("user32.dll", CharSet = CharSet.Unicode)] static extern int GetWindowText(IntPtr h, StringBuilder s, int n);
  static string Cls(IntPtr h) { var s = new StringBuilder(256); GetClassName(h, s, 256); return s.ToString(); }
  static string Txt(IntPtr h) { var s = new StringBuilder(2048); GetWindowText(h, s, 2048); return s.ToString(); }
  public static string Find(uint pid, string known) {
    string found = null;
    EnumWindows((h, l) => {
      uint p; GetWindowThreadProcessId(h, out p);
      if (p != pid || !IsWindowVisible(h) || Cls(h) != "#32770") return true;
      var text = new List<string>(); var buttons = new List<string>();
      EnumChildWindows(h, (c, l2) => { string k = Cls(c), t = Txt(c).Replace("&", "").Trim(); if (t != "") { if (k == "Button") buttons.Add(t); else if (k == "Static") text.Add(t); } return true; }, IntPtr.Zero);
      string title = Txt(h);
      if (buttons.Count < 2 && !System.Text.RegularExpressions.Regex.IsMatch(title, known)) return true;
      found = title + (text.Count > 0 ? ": " + string.Join(" ", text) : "") + (buttons.Count > 0 ? " [" + string.Join("/", buttons) + "]" : "");
      return false;
    }, IntPtr.Zero);
    return found == null ? null : found.Replace("\r", " ").Replace("\n", " ");
  }
}
'@
$end = (Get-Date).AddSeconds($Seconds)
while ((Get-Date) -lt $end) {
  Start-Sleep -Seconds 1
  if (Test-Path $Alive) { exit 0 }
  if (-not (Test-Path $PidFile)) { continue }
  $id = [uint32]((Get-Content $PidFile -TotalCount 1).Trim())
  if (-not (Get-Process -Id $id -ErrorAction SilentlyContinue)) { exit 0 }
  $d = [WarmdDialog]::Find($id, 'Packages with Errors|Scene Backups|Safe Mode|already open|another Unity')
  if ($d) { [IO.File]::WriteAllText($Out, $d); exit 0 }
}
PS
  powershell.exe -NoProfile -NonInteractive -ExecutionPolicy Bypass -File "$(native_path "$RUN/dialog.ps1")" \
    -PidFile "$(native_path "$RUN/spawn.pid")" -Alive "$(native_path "$RUN/alive.txt")" -Out "$(native_path "$RUN/dialog.txt")" -Seconds "$1" >/dev/null 2>&1
}

# Project code compiles from Assets. A csproj without Assets sources is a package (cache, embedded or linked): Unity built it into Library/ScriptAssemblies already, and its sources do not compile outside Unity.
csproj_list() { grep -l 'Compile Include="Assets[\/]' "$PROJECT"/*.csproj 2>/dev/null; }
pkg_projects() { local p; for p in "$PROJECT"/*.csproj; do [ -f "$p" ] && ! grep -q 'Compile Include="Assets[\/]' "$p" && basename "$p" .csproj; done; }
# Fresh means every script is listed. Otherwise only Unity can compile.
csproj_fresh() {
  local listed have
  [ -n "$(csproj_list)" ] || return 1
  listed="$(cat $(csproj_list) | grep -o 'Include="Assets[^"]*\.cs"' | sed 's/Include="//; s/"$//; s#[\]#/#g' | sort -u)"
  have="$(cd "$PROJECT" && find Assets -name '*.cs' | sort -u)"
  [ -z "$(comm -13 <(echo "$listed") <(echo "$have"))" ]
}
# Assemblies the project csprojs reference but the Library lacks: dotnet would report every use as an error, so Unity has to compile once
refs_missing() {
  local p h pkgs; pkgs="$(pkg_projects)"
  {
    for p in $(csproj_list); do
      grep -o '<HintPath>[^<]*' "$p" | sed 's/<HintPath>//; s#[\]#/#g'
      for h in $(grep -o 'ProjectReference Include="[^"]*"' "$p" | sed 's/.*Include="//; s/"$//; s/\.csproj$//'); do
        grep -qxF "$h" <<< "$pkgs" && echo "Library/ScriptAssemblies/$h.dll"
      done
    done
  } | sort -u | while IFS= read -r h; do (cd "$PROJECT" && [ -f "$h" ]) || echo "$h"; done
}
# Package projects stay unbuilt: a reference to one points at its dll in Library/ScriptAssemblies
pkg_targets() {
  cat <<'X'
<Project>
  <Target Name="WarmdPackageDlls" BeforeTargets="_GenerateRestoreProjectReferencePaths;AssignProjectConfiguration" Condition="'$(WarmdPkgs)'!=''">
    <ItemGroup>
      <_WarmdPkg Include="@(ProjectReference)" Condition="$(WarmdPkgs.Contains('|%(Filename)|'))" />
      <ProjectReference Remove="@(_WarmdPkg)" />
      <Reference Include="@(_WarmdPkg->'%(Filename)')" HintPath="$(MSBuildProjectDirectory)/Library/ScriptAssemblies/%(Filename).dll" Private="false" />
    </ItemGroup>
  </Target>
</Project>
X
}
# One parallel msbuild over all projects with warm nodes, Runtime builds once. Unity empties Temp on exit, so restore only when it is gone, one project after another: parallel restores of a shared graph collide on its files.
dotnet_errors() {
  local p proj="$RUN/all.proj" restore="" pkgs
  pkgs="|$(pkg_projects | paste -sd'|' -)|"
  pkg_targets > "$RUN/pkg.targets"
  {
    echo '<Project DefaultTargets="Build"><ItemGroup>'
    for p in $(csproj_list); do echo "<P Include=\"$(native_path "$p")\" />"; done
    echo '</ItemGroup><Target Name="Build">'
    echo '<MSBuild Condition="'"'"'$(R)'"'"'==1" Projects="@(P)" BuildInParallel="false" Targets="Restore" Properties="Configuration=Debug;WarmdRestore=1" />'
    echo '<MSBuild Projects="@(P)" BuildInParallel="true" Targets="Build" Properties="Configuration=Debug" />'
    echo '</Target></Project>'
  } > "$proj"
  for p in $(csproj_list); do
    [ -f "$PROJECT/Temp/obj/$(basename "$p" .csproj)/project.assets.json" ] || [ -f "$PROJECT/obj/project.assets.json" ] || restore=1
  done
  ( cd "$PROJECT" && timeout 300 $(tune_prefix) dotnet msbuild "$(native_path "$proj")" -p:R="${restore:-0}" "-p:WarmdPkgs=$pkgs" "-p:CustomAfterMicrosoftCommonTargets=$(native_path "$RUN/pkg.targets")" -p:DisableTransitiveProjectReferences=true -nr:true -m:"$(tune_threads)" -nologo -v q -clp:NoSummary 2>&1 ) | sed 's#[\]#/#g' | grep -E ': error ' | sed -E 's#^.*/(Assets/[^(]*)\(([0-9]+),[0-9]+\): error ([A-Z0-9]+): (.*) \[.*$#\1:\2 \3 \4#' | sort -u
}
a_build() {
  unity_sync
  command -v dotnet >/dev/null 2>&1 || { job compile; return; }
  csproj_fresh || { echo "(csproj stale, compiling in Unity)"; job compile; return; }
  local errs n miss; miss="$(refs_missing)"
  if [ -n "$miss" ]; then echo "(Library lacks $(echo "$miss" | wc -l | tr -d ' ') referenced assemblies, e.g. $(echo "$miss" | head -1), compiling in Unity)"; job compile; return; fi
  errs="$(dotnet_errors)"
  if [ -n "$errs" ]; then n="$(echo "$errs" | wc -l | tr -d ' ')"; echo "FAIL $(secs)s dotnet: $n errors"; echo "$errs" | head -13 | cut -c1-200; return 1; fi
  daemon_alive && job_async compile
  echo "OK $(secs)s compile (no Unity needed)"
}

# world_method in warmd.conf: the project's step that builds generated parts (a static method, run in the warm editor).
# It runs before tests whenever its sources changed since its last run: after a merge or a pull nothing generated is missing,
# and nobody reaches for another tool. world_sources: paths in the project, comma separated (default Assets);
# world_outputs: what the step writes, left out of the sources and out of automatic commits (lib/auto.sh auto_unjunk).
world_key() {
  local s ex=() src=()
  for s in ${CFG_world_sources//,/ }; do src+=("$s"); done; [ ${#src[@]} -gt 0 ] || src=(Assets)
  for s in ${CFG_world_outputs//,/ }; do ex+=(":(exclude)$s"); done
  { git -C "$PROJECT" ls-files -s -- "${src[@]}" "${ex[@]}"; git -C "$PROJECT" diff -- "${src[@]}" "${ex[@]}"; git -C "$PROJECT" ls-files -o --exclude-standard -- "${src[@]}" "${ex[@]}"; } 2>/dev/null | { sha1sum 2>/dev/null || shasum; } | cut -c1-20
}
unity_world() {
  [ -n "${CFG_world_method:-}" ] && [ "${WORLD_DONE:-0}" = 0 ] || return 0
  WORLD_DONE=1
  local key old=""; key="$(world_key)"; read -r old 2>/dev/null < "$STATE/world.key"
  [ "$key" = "$old" ] && return 0
  echo "(world: its sources changed, running $CFG_world_method)"
  a_call "$CFG_world_method" || { echo "FAIL world_method $CFG_world_method, tests not run"; return 1; }
  echo "$key" > "$STATE/world.key"
}

# A filter that names no test class but a test file (DamageJobTests.cs holding class DamageFlowTests) means that file:
# it becomes the classes declared in it, and says so. A filter that is a class name, or any regex, stays as it is.
unity_filter_file() { # filter -> REPLY = filter to run
  REPLY="$1"; UF_GREP=""
  [[ $1 =~ ^[A-Za-z_][A-Za-z0-9_]*$ ]] || return 0
  grep -rqE "class +$1([^A-Za-z0-9_]|$)" "$PROJECT/Assets" --include='*.cs' 2>/dev/null && return 0
  local f cls; f="$(find "$PROJECT/Assets" -name "$1.cs" -not -path '*/Library/*' 2>/dev/null | head -1)"
  [ -n "$f" ] || return 0
  cls="$(grep -ohE 'class +[A-Za-z_][A-Za-z0-9_]*' "$f" | awk '{print $2}' | sort -u | paste -sd'|' -)"
  [ -n "$cls" ] || return 0
  echo "(filter $1 is a file, not a class: running its classes ${cls//|/ })"
  REPLY="^(.*\.)?($cls)(\.|$)"; UF_GREP="class +($cls)"
}

# A test that needs a graphics device fails in the headless daemon. gfx_tests=<filter regex> in warmd.conf runs matching
# filters with graphics (WARMD_GFX=1, a headless daemon makes way); any other graphics failure gets a line that says so.
UNITY_GFX_ERR='RenderTexture\.Create failed|[Nn]o graphics device|graphics device is null|GraphicsDeviceType\.Null|Kernel .* not found|Shader.* not supported on this GPU|-nographics'
unity_gfx_hint() { # output -> the hint line when a failure looks like missing graphics
  [ "${WARMD_GFX:-0}" = 1 ] && return 0
  printf '%s\n' "$1" | grep -qE "$UNITY_GFX_ERR" && echo "HINT needs graphics: run it with WARMD_GFX=1, or set gfx_tests=<filter> in warmd.conf so warmd does it by itself"
  return 0
}

# A HUNG test ends the editor (lib/daemon.sh job), the tests after it would never run. So the run goes on: a fresh daemon
# runs the same filter again without every test that already ran and without the hung one (skip= in the job, the daemon
# narrows the filter to the rest). Up to hung_resume rounds (warmd.conf, default 10, 0 = stop at the first HUNG).
# At the end tests.txt and result.txt hold every round as one list, a hung test is an H row.
unity_test_rounds() { # job test arguments
  local max="${CFG_hung_resume:-10}" round=0 rc cur why first="" all="$STATE/tests.rounds" skip="$STATE/tests.skip"
  rm -f "$all" "$skip"
  while :; do
    if [ $round = 0 ]; then job test "$@"; else job test "$@" "skip=$(native_path "$skip")"; fi; rc=$?
    [ $rc != 0 ] && [ "$max" -gt 0 ] && grep -q '^HUNG ' "$RUN/result.txt" 2>/dev/null || break
    cur=""; { IFS= read -r cur < "$RUN/current.full"; } 2>/dev/null; cur="${cur%$'\r'}"
    why="$(grep -m1 '^HUNG ' "$RUN/result.txt" | tr -d '\r' | sed 's/^HUNG [^:]*: //')"
    [ -n "$first" ] || first="$(head -1 "$RUN/result.txt" | cut -d' ' -f1)"
    { tr -d '\r' < "$RUN/tests.txt"; } 2>/dev/null >> "$all"
    printf 'H\t%s\t%s\n' "${cur:-outside any test in round $((round + 1))}" "$why" >> "$all"
    round=$((round + 1))
    # Hung outside a test (fixture setup, before the first one), or the same test once more: nothing left to step over
    [ -n "$cur" ] && ! grep -qxF "$cur" "$skip" 2>/dev/null || break
    { { tr -d '\r' < "$RUN/tests.txt"; } 2>/dev/null | cut -f2; echo "$cur"; } >> "$skip"
    [ $round -le "$max" ] || { echo "(hung_resume: $max rounds reached, the rest stays unrun)"; break; }
    echo "(goes on after HUNG ${cur##*.}: fresh editor, round $((round + 1)), $(grep -c . "$skip") tests done or hung)"
  done
  [ $round = 0 ] && return $rc
  unity_rounds_list "$rc" "$first"
}

# Every round in one list: counts, then each hung test, then each red one
unity_rounds_list() { # rc of the last round, id of the first round
  local all="$STATE/tests.rounds" p f s h body ok=FAIL
  grep -q '^HUNG ' "$RUN/result.txt" 2>/dev/null || { tr -d '\r' < "$RUN/tests.txt"; } 2>/dev/null >> "$all"
  p="$(grep -c $'^P\t' "$all")"; f="$(grep -c $'^F\t' "$all")"; s="$(grep -c $'^S\t' "$all")"; h="$(grep -c $'^H\t' "$all")"
  body="$(echo "all rounds: $p passed, $f failed, $s skipped, $h hung"
    awk -F'\t' '$1=="H" { n=split($2, a, "."); print "HUNG " a[n] ": " $3 }' "$all"
    awk -F'\t' '$1=="F" { n=split($2, a, "."); print "RED " a[n] ": " $3 }' "$all")"
  [ $((f + h)) = 0 ] && [ "$1" = 0 ] && ok=OK
  cp "$all" "$RUN/tests.txt"
  { echo "${2:-r$(now_ms)} $ok $(secs)s test"; echo "$body" | head -14; } > "$RUN/result.txt"
  echo "$body" | head -14
  [ $ok = OK ]
}

a_test() {
  unity_world || return 1
  local filter="" mode="" cat="" speed="" rc
  while [ $# -gt 0 ]; do case "$1" in --play) mode=Play;; --edit) mode=Edit;; --cat) cat="$2"; shift;; --speed) speed="$2"; shift;; --window) export WARMD_WINDOW=1;; *) filter="$1";; esac; shift; done
  [ -n "$filter" ] && { unity_filter_file "$filter"; filter="$REPLY"; }
  [ -n "$mode" ] || { if [ -n "$filter" ] && grep -rqE "${UF_GREP:-$filter}" "$PROJECT/Assets" --include='*.cs' --exclude-dir=Editor 2>/dev/null && find "$PROJECT/Assets" -path '*PlayMode*' -name '*.cs' | xargs -r grep -lqE "${UF_GREP:-$filter}" 2>/dev/null; then mode=Play; else mode=Edit; fi; }
  if [ -n "${CFG_gfx_tests:-}" ] && [ -n "$filter" ] && [ "${WARMD_GFX:-0}" != 1 ] && printf '%s\n' "$filter" | grep -qE "$CFG_gfx_tests"; then
    echo "(gfx_tests: $filter runs with graphics)"; export WARMD_GFX=1
    if daemon_alive && [ "$(cat "$RUN/gfx.txt" 2>/dev/null)" != 1 ]; then daemon_stop >/dev/null; fi
  fi
  # --window: a headless daemon makes way for a visible editor, which closes again after the run
  local win="${WARMD_WINDOW:-0}" wkey=""
  if [ "$win" = 1 ]; then
    wkey="|window"
    if daemon_alive && [ "$(cat "$RUN/window.txt" 2>/dev/null)" != 1 ]; then daemon_stop >/dev/null; fi
  fi
  unity_sync
  # test_timeout in warmd.conf: seconds one test may run before it counts as hung and red
  cached "test|$mode|$filter|$cat|$speed|gfx${WARMD_GFX:-0}$wkey" unity_test_rounds "mode=$mode" "filter=$filter" "cat=$cat" "speed=$speed" "test_timeout=${CFG_test_timeout:-}"; rc=$?
  [ $rc = 0 ] || unity_gfx_hint "$(cat "$RUN/result.txt" "$RUN/tests.txt" 2>/dev/null)"
  if [ "$win" = 1 ] && daemon_alive; then daemon_stop >/dev/null; echo "(window editor closed)"; fi
  return $rc
}

# The whole PlayMode suite runs long (minutes per test is common): warmd check runs it only in the merge gate or with WARMD_FULL=1
unity_play_all() {
  if [ "${WARMD_FULL:-0}" = 1 ] || [ "${WARMD_IN_MERGE:-0}" = 1 ]; then a_test --play; return; fi
  echo "(PlayMode: no affected test class to pick, the full PlayMode suite runs in the merge gate or with WARMD_FULL=1)"
}

# Test classes that mention a changed class, per mode
a_check() {
  unity_world || return 1
  . "$WARMD_HOME/lib/affected.sh"
  affected_select cs Assets Packages
  case "$AFF_MODE" in
    CLEAN) echo "OK no code changed against $(base_branch)"; return 0;;
    NONE) echo "OK no test depends on this change"; return 0;;
    ALL) echo "(running all tests: $AFF_REASON)"; a_test --edit && unity_play_all; return;;
  esac
  local f ed="" pl="" other=0 e p
  for f in $AFF_FILES; do
    case "$f" in *PlayMode*) pl="$pl $f";; *EditMode*) ed="$ed $f";; *) other=1;; esac
  done
  if [ $other = 1 ]; then echo "(a test sits outside EditMode and PlayMode, running all)"; a_test --edit && unity_play_all; return; fi
  for f in $ed; do e="${e:+$e|}$(grep -ohE 'class +[A-Za-z_0-9]+' "$PROJECT/$f" | awk '{print $2}' | paste -sd'|' -)"; done
  for f in $pl; do p="${p:+$p|}$(grep -ohE 'class +[A-Za-z_0-9]+' "$PROJECT/$f" | awk '{print $2}' | paste -sd'|' -)"; done
  if [ -n "$e" ]; then echo "(touched Edit: $(echo "$e" | tr '|' ' ' | cut -c1-120))"; a_test "($e)" --edit || return 1; fi
  if [ -n "$p" ]; then echo "(touched Play: $(echo "$p" | tr '|' ' ' | cut -c1-120))"; a_test "($p)" --play || return 1; fi
}

a_call() { [ -n "${1:-}" ] || { echo "warmd call Namespace.Class.StaticMethod"; return 2; }; unity_sync; slot_take; job call "method=$1"; }

a_shot() { # needs graphics, so one start of its own
  local out="${1:-$RUN/shots/game.png}"; mkdir -p "$(dirname "$out")"
  [ -n "${CFG_shot_method:-}" ] || { echo "FAIL set shot_method=Namespace.Class.Method in warmd.conf, it reads -shotPath"; return 2; }
  slot_take; gfx_take; a_stop >/dev/null
  local clean; clean="$(git -C "$PROJECT" status --porcelain -uno | grep -vE '\.sln[x]?$')"
  timeout "$TIMEOUT" $(tune_prefix) "$(unity_exe)" -batchmode -job-worker-count "$(tune_unity_workers)" $(tune_unity_gpu_flag) -projectPath "$(native_path "$PROJECT")" -executeMethod "$CFG_shot_method" -shotPath "$(native_path "$out")" -quit -logFile "$(native_path "$RUN/shot.log")"
  local rc=$?
  [ -z "$clean" ] && git -C "$PROJECT" checkout -q -- .   # Unity reserializes materials, the base must stay clean for the next merge
  [ $rc = 0 ] && echo "image $(native_path "$out")" && echo "OK $(secs)s shot" || { echo "FAIL $(secs)s shot"; grep -m3 -i error "$RUN/shot.log" | cut -c1-200; }
  return $rc
}

# Player build through your own method: package_method and package_args in warmd.conf. Needs graphics, so one start of its own.
a_package() {
  [ -n "$CFG_package_method" ] || { echo "FAIL set package_method=Namespace.Class.Method in warmd.conf"; return 2; }
  slot_take; a_stop > /dev/null
  [ -z "$(foreign_unity)" ] || { echo "FAIL another Unity has this project open"; return 2; }
  local clean; clean="$(git -C "$PROJECT" status --porcelain -uno | grep -vE '\.sln[x]?$')"
  timeout "${WARMD_BUILD_TIMEOUT:-2400}" $(tune_prefix) "$(unity_exe)" -batchmode -job-worker-count "$(tune_unity_workers)" -projectPath "$(native_path "$PROJECT")" -executeMethod "$CFG_package_method" $CFG_package_args -quit -logFile "$(native_path "$RUN/package.log")"
  local rc=$?
  [ -z "$clean" ] && git -C "$PROJECT" checkout -q -- .
  if [ $rc = 0 ]; then echo "OK $(secs)s package"; else echo "FAIL $(secs)s package"; grep -m6 -E 'error CS|rror:|Failed' "$RUN/package.log" | cut -c1-200; fi
  return $rc
}

# The own daemon first, then every other Unity with exactly this -projectPath (another tool's editor blocks the next start).
# A batchmode editor is asked to end, then ended hard. An editor with a window may hold unsaved work: asked only, --force ends it hard.
a_stop() {
  local rc pid path flags me n=0 force=0; [ "${1:-}" = --force ] && force=1
  daemon_stop; rc=$?
  me="$(native_path "$PROJECT")"; me="${me%/}"
  while IFS='	' read -r pid path flags; do
    [ -n "$pid" ] && [ "${path,,}" = "${me,,}" ] || continue
    case "$flags" in *d*) continue;; esac   # a warmd daemon: daemon_stop handled it
    n=$((n+1))
    if [[ $flags == *b* ]] || [ $force = 1 ]; then
      if stop_gently "$pid" "${WARMD_STOP_GRACE:-15}"; then echo "OK stopped other Unity pid $pid on this project ($STOP_HOW$([[ $flags == *b* ]] && echo ", batchmode"))"
      else echo "FAIL other Unity pid $pid on this project still alive after kill"; rc=1; fi
    else
      if [ "$OS" = win ]; then taskkill //PID "$pid" >/dev/null 2>&1; else kill -TERM "$pid" 2>/dev/null; fi
      nap 3
      if pid_alive "$pid"; then echo "WARN Unity pid $pid has this project open in a window, maybe unsaved work: left open. Close it, or: warmd stop --force"
      else echo "OK closed Unity window pid $pid on this project"; fi
    fi
  done < <(unity_procs)
  return $rc
}
a_has_cache() { [ -d "$1/Library" ]; }
a_status() { if daemon_alive; then echo "Unity $UNITY_VER warm, pid $(daemon_pid)"; else echo "Unity $UNITY_VER cold"; fi; }
a_seed() { # Library is the slow part: a worktree without it reimports everything
  [ -d "$1/Library" ] || return 0
  if [ "$OS" = win ]; then robocopy "$(cygpath -w "$1/Library")" "$(cygpath -w "$2/Library")" //E //MT:16 //R:1 //W:1 //NFL //NDL //NJH //NJS //NP >/dev/null; true
  else cp -R "$1/Library" "$2/Library"; fi
}
a_init() {
  mkdir -p "$EDITOR_DIR"
  cp "$WARMD_HOME"/unity/* "$EDITOR_DIR/"
  # New projects can ship without it, the daemon cannot compile then
  if ! grep -q test-framework "$PROJECT/Packages/manifest.json"; then
    sed -i.bak 's/"dependencies": {/&\
    "com.unity.test-framework": "1.6.0",/' "$PROJECT/Packages/manifest.json"; rm -f "$PROJECT/Packages/manifest.json.bak"
    echo "OK added com.unity.test-framework"
  fi
  echo "OK daemon installed to Assets/Editor/Warmd"
}
a_doctor() {
  [ -x "$(unity_exe)" ] && echo "ok Unity $UNITY_VER" || echo "MISSING Unity $UNITY_VER, set WARMD_UNITY"
  [ -f "$EDITOR_DIR/WarmdDaemon.cs" ] && echo "ok daemon installed" || echo "MISSING daemon, run warmd init"
  command -v dotnet >/dev/null 2>&1 && echo "ok dotnet, compile runs without Unity" || echo "note: no dotnet, compile goes through Unity"
  grep -q test-framework "$PROJECT/Packages/manifest.json" && echo "ok test framework" || echo "MISSING com.unity.test-framework in manifest.json"
}
