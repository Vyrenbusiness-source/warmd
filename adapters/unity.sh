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
  sleep 2
  for pid in $(worker_procs); do kill_tree "$pid"; done
  rm -f "$RUN/alive.txt" "$RUN/pid.txt"
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
  [ -n "$other" ] && { echo "FAIL another Unity (pid $other) has this project open, nothing touched"; exit 2; }
  rm -f "$RUN/alive.txt" "$RUN/state.txt"
  local exe gfx=(-nographics); exe="$(unity_exe)"
  [ -x "$exe" ] || { echo "FAIL Unity $UNITY_VER not found, set WARMD_UNITY"; exit 2; }
  [ "${WARMD_GFX:-0}" = 1 ] && { gfx=(); gfx_take; gfx+=($(tune_unity_gpu_flag)); }
  # Each worktree gets a stable port block, so parallel daemons never collide and no agent has to think about it
  if [ -n "$CFG_port_env" ]; then
    export "$CFG_port_env=$(( 7830 + 10 * ( $(printf '%s' "$PROJECT" | cksum | cut -d' ' -f1) % 160 ) ))"
  fi
  export WARMD_DIR; WARMD_DIR="$(native_path "$RUN")"
  # -logFile with warmd-daemon in the path is how the daemon is told from a human's editor
  spawn "$RUN/unity_out.log" "$exe" -batchmode -job-worker-count "$(tune_unity_workers)" "${gfx[@]}" -projectPath "$(native_path "$PROJECT")" -logFile "$(native_path "$RUN/warmd-daemon.log")"
  wait_ready 600
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

a_test() {
  unity_world || return 1
  local filter="" mode="" cat="" speed=""
  while [ $# -gt 0 ]; do case "$1" in --play) mode=Play;; --edit) mode=Edit;; --cat) cat="$2"; shift;; --speed) speed="$2"; shift;; *) filter="$1";; esac; shift; done
  [ -n "$mode" ] || { if [ -n "$filter" ] && grep -rqE "$filter" "$PROJECT/Assets" --include='*.cs' --exclude-dir=Editor 2>/dev/null && find "$PROJECT/Assets" -path '*PlayMode*' -name '*.cs' | xargs -r grep -lqE "$filter" 2>/dev/null; then mode=Play; else mode=Edit; fi; }
  unity_sync
  # test_timeout in warmd.conf: seconds one test may run before it counts as hung and red
  cached "test|$mode|$filter|$cat|$speed" job test "mode=$mode" "filter=$filter" "cat=$cat" "speed=$speed" "test_timeout=${CFG_test_timeout:-}"
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

a_stop() { daemon_stop; }
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
