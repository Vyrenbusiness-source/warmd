# Unity: the warm thing is the editor, headless with -nographics. Job logic lives in unity/WarmdDaemon.cs.
UNITY_VER="$(sed -n 's/^m_EditorVersion: //p' "$PROJECT/ProjectSettings/ProjectVersion.txt" | tr -d '\r')"
EDITOR_DIR="$PROJECT/Assets/Editor/Warmd"
export WARMD_IDLE_MIN="$CFG_idle_min"

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

a_start_daemon() {
  [ -f "$EDITOR_DIR/WarmdDaemon.cs" ] || { echo "FAIL run warmd init first"; exit 2; }
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

csproj_list() { ls "$PROJECT"/*.csproj 2>/dev/null | grep -vE '/(Unity|com\.unity)\.' ; }
# Fresh means every script is listed. Otherwise only Unity can compile.
csproj_fresh() {
  local listed have
  [ -n "$(csproj_list)" ] || return 1
  listed="$(cat $(csproj_list) | grep -o 'Include="Assets[^"]*\.cs"' | sed 's/Include="//; s/"$//; s#\\#/#g' | sort -u)"
  have="$(cd "$PROJECT" && find Assets -name '*.cs' | sort -u)"
  [ -z "$(comm -13 <(echo "$listed") <(echo "$have"))" ]
}
# One parallel msbuild over all projects with warm nodes, Runtime builds once. Unity empties Temp on exit, so restore only when it is gone.
dotnet_errors() {
  local p proj="$RUN/all.proj" restore=""
  {
    echo '<Project DefaultTargets="Build"><ItemGroup>'
    for p in $(csproj_list); do echo "<P Include=\"$(native_path "$p")\" />"; done
    echo '</ItemGroup><Target Name="Build">'
    echo '<MSBuild Condition="'"'"'$(R)'"'"'==1" Projects="@(P)" BuildInParallel="true" Targets="Restore" Properties="Configuration=Debug;WarmdRestore=1" />'
    echo '<MSBuild Projects="@(P)" BuildInParallel="true" Targets="Build" Properties="Configuration=Debug" />'
    echo '</Target></Project>'
  } > "$proj"
  for p in $(csproj_list); do
    [ -f "$PROJECT/Temp/obj/$(basename "$p" .csproj)/project.assets.json" ] || [ -f "$PROJECT/obj/project.assets.json" ] || restore=1
  done
  ( cd "$PROJECT" && timeout 300 $(tune_prefix) dotnet msbuild "$(native_path "$proj")" -p:R="${restore:-0}" -nr:true -m:"$(tune_threads)" -nologo -v q -clp:NoSummary 2>&1 ) | sed 's#[\]#/#g' | grep -E ': error ' | sed -E 's#^.*/(Assets/[^(]*)\(([0-9]+),[0-9]+\): error ([A-Z0-9]+): (.*) \[.*$#\1:\2 \3 \4#' | sort -u
}
a_build() {
  command -v dotnet >/dev/null 2>&1 || { job compile; return; }
  csproj_fresh || { echo "(csproj stale, compiling in Unity)"; job compile; return; }
  local errs n; errs="$(dotnet_errors)"
  if [ -n "$errs" ]; then n="$(echo "$errs" | wc -l | tr -d ' ')"; echo "FAIL $(secs)s dotnet: $n errors"; echo "$errs" | head -13 | cut -c1-200; return 1; fi
  daemon_alive && job_async compile
  echo "OK $(secs)s compile (no Unity needed)"
}

a_test() {
  local filter="" mode="" cat="" speed=""
  while [ $# -gt 0 ]; do case "$1" in --play) mode=Play;; --edit) mode=Edit;; --cat) cat="$2"; shift;; --speed) speed="$2"; shift;; *) filter="$1";; esac; shift; done
  [ -n "$mode" ] || { if [ -n "$filter" ] && grep -rqE "$filter" "$PROJECT/Assets" --include='*.cs' --exclude-dir=Editor 2>/dev/null && find "$PROJECT/Assets" -path '*PlayMode*' -name '*.cs' | xargs -r grep -lqE "$filter" 2>/dev/null; then mode=Play; else mode=Edit; fi; }
  cached "test|$mode|$filter|$cat|$speed" job test "mode=$mode" "filter=$filter" "cat=$cat" "speed=$speed"
}

# Test classes that mention a changed class, per mode
a_check() {
  . "$WARMD_HOME/lib/affected.sh"
  affected_select cs Assets Packages
  case "$AFF_MODE" in
    CLEAN) echo "OK no code changed against $(base_branch)"; return 0;;
    NONE) echo "OK no test depends on this change"; return 0;;
    ALL) echo "(running all tests: $AFF_REASON)"; a_test --edit && a_test --play; return;;
  esac
  local f ed="" pl="" other=0 e p
  for f in $AFF_FILES; do
    case "$f" in *PlayMode*) pl="$pl $f";; *EditMode*) ed="$ed $f";; *) other=1;; esac
  done
  if [ $other = 1 ]; then echo "(a test sits outside EditMode and PlayMode, running all)"; a_test --edit && a_test --play; return; fi
  for f in $ed; do e="${e:+$e|}$(grep -ohE 'class +[A-Za-z_0-9]+' "$PROJECT/$f" | awk '{print $2}' | paste -sd'|' -)"; done
  for f in $pl; do p="${p:+$p|}$(grep -ohE 'class +[A-Za-z_0-9]+' "$PROJECT/$f" | awk '{print $2}' | paste -sd'|' -)"; done
  if [ -n "$e" ]; then echo "(touched Edit: $(echo "$e" | tr '|' ' ' | cut -c1-120))"; a_test "($e)" --edit || return 1; fi
  if [ -n "$p" ]; then echo "(touched Play: $(echo "$p" | tr '|' ' ' | cut -c1-120))"; a_test "($p)" --play || return 1; fi
}

a_call() { [ -n "${1:-}" ] || { echo "warmd call Namespace.Class.StaticMethod"; return 2; }; slot_take; job call "method=$1"; }

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
