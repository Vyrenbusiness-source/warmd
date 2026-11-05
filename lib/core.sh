# Project detection, config, bounded output, green cache, machine-wide queue, affected tests, code map.
printf -v T0 '%(%s)T' -1
secs() { local n; printf -v n '%(%s)T' -1; echo $(( n - T0 )); }
TIMEOUT="${WARMD_TIMEOUT:-900}"
CACHE_ROOT="${XDG_CACHE_HOME:-$HOME/.cache}/warmd"
LOCK=""; SLOT=""; JOBLOCK=""; MERGELOCK=""; RUNMARK=""
PARENT_PID="$PPID"
on_exit() {
  local rc=$?
  # An exit deep inside a cached run (a refusal in the engine start) skipped the cat of its output: say it now, with reason and log
  if [ -n "${CACHED_OUT:-}" ] && [ -f "$CACHED_OUT" ]; then
    {   # fd 8 is the caller's stdout, saved by cached(): the exit happened while stdout went to the file
      cat "$CACHED_OUT"
      if [ "$rc" != 0 ]; then
        local lg="" c; for c in "$RUN/warmd-daemon.log" "$RUN/daemon.log" "$RUN/last.log"; do [ -f "$c" ] && { [ -z "$lg" ] || [ "$c" -nt "$lg" ]; } && lg="$c"; done
        echo "FAIL warmd ${CMD:-run} ended with exit $rc$( [ -n "$lg" ] && echo ", log: $(native_path "$lg")")"
      fi
    } >&8 2>/dev/null
    rm -f "$CACHED_OUT"
  fi
  # Exit code of the last warmd test or check, for every adapter: auto_stop reads it to see a red run behind an ok text
  case "${CMD:-}" in test|check) [ -n "${RUN:-}" ] && mkdir -p "$RUN" 2>/dev/null && echo "$rc $CMD" > "$RUN/last.rc" 2>/dev/null;; esac
  [ -n "$LOCK" ] && rmdir "$LOCK" 2>/dev/null
  [ -n "$SLOT" ] && rm -rf "$SLOT"
  [ -n "${GFXSLOT:-}" ] && rm -rf "$GFXSLOT"
  [ -n "$JOBLOCK" ] && rm -rf "$JOBLOCK"
  [ -n "$MERGELOCK" ] && rm -f "$MERGELOCK" "$MERGELOCK.win"
  [ -n "$RUNMARK" ] && rm -f "$RUNMARK"
  return 0
}
# A heavy run marks itself in .warmd/run/active/<pid> (content: Windows pid or -, command) while it lives.
# An agent that ends its turn while its own warmd test runs in the background keeps its engine (warmd stop --idle),
# and warmd watch counts its worktree as working.
run_mark() {
  mkdir -p "$RUN/active" 2>/dev/null || return 0
  local w=""; [ -r "/proc/$$/winpid" ] && read -r w < "/proc/$$/winpid"
  echo "${w:--} $CMD" > "$RUN/active/$$" 2>/dev/null && RUNMARK="$RUN/active/$$"
  queue_done
}
# run_active <state dir>: prints "<pid> <command>" of a live run there, returns 1 when none. Marks of dead runs go.
# A job started through Win32_Process.Create may not see this shell's msys pids: the Windows pid decides then.
run_active() {
  local f pid w c
  for f in "$1"/run/active/*; do
    [ -f "$f" ] || continue
    pid="${f##*/}"; w=""; c=""; read -r w c < "$f" 2>/dev/null
    [ "$pid" = "$$" ] && continue
    if shell_alive "$pid" || { [ -n "$w" ] && [ "$w" != - ] && pid_alive "$w"; }; then echo "$pid ${c:-run}"; return 0; fi
    rm -f "$f"
  done
  return 1
}
# If the agent or shell that called us is gone, nobody reads the result: end and free the queue. WARMD_DETACHED=1 is for deliberate background use.
orphan_check() {
  [ "${WARMD_DETACHED:-0}" = 1 ] && return 0
  [ "$PARENT_PID" -le 1 ] && return 0   # started by a non-shell program, its pid is not visible from here
  shell_alive "$PARENT_PID" && return 0
  echo "FAIL caller is gone, stopping"; exit 3
}
# While a batch runs, agents belong in their worktrees. A run in the shared checkout collides with merges and costs a slot.
# The marker holds the worktrees of the batch, so a call from one of them passes. WARMD_BASE=1 is the deliberate way in.
batch_guard() {
  [ "${WARMD_BASE:-0}" = 1 ] || [ "${WARMD_IN_MERGE:-0}" = 1 ] && return 0
  [ -n "$GIT_ROOT" ] || return 0
  local f; f="$(git -C "$PROJECT" rev-parse --path-format=absolute --git-common-dir)/warmd-batch"
  [ -f "$f" ] || return 0
  # Stale after 240 minutes, unless warmd watch saw agents work in that time: it touches warmd-batch-alive, never the marker,
  # whose mtime stays the batch start for wt_idle.
  if [ -n "$(find "$f" -mmin +240 2>/dev/null)" ] && { [ ! -f "$f-alive" ] || [ -n "$(find "$f-alive" -mmin +240 2>/dev/null)" ]; }; then
    rm -f "$f" "$f-alive"; return 0
  fi
  # Both spellings of the same folder pass (/c/x and C:/x), a marker written by hand or by a Windows tool must not lock out its own worktrees.
  grep -qxF -e "$GIT_ROOT" -e "$(native_path "$GIT_ROOT")" "$f" && return 0
  echo "FAIL a batch runs, this is the shared checkout. Work in the worktree from your task file. Ending the batch: warmd batch-done, on purpose here: WARMD_BASE=1"; exit 5
}

# Changes during a merge end up in the merge. Only the merge's own checks may run here, everyone else gets a clear refusal.
merge_guard() {
  [ "${WARMD_IN_MERGE:-0}" = 1 ] && return 0
  local f="$STATE/merge.owner" owner
  if [ -f "$f" ]; then
    owner="$(cat "$f" 2>/dev/null)"
    # A merge started through Win32_Process.Create (hook_detach) may sit outside this shell's msys pid table: its Windows pid counts too
    if shell_alive "$owner" || { [ -s "$f.win" ] && pid_alive "$(cat "$f.win" 2>/dev/null)"; }; then echo "FAIL a merge is running in this checkout, work in your own worktree"; exit 4; fi
    rm -f "$f" "$f.win"
  fi
  batch_guard
}
trap on_exit EXIT
trap 'exit 130' INT TERM

kind_of() {
  local d="$1"
  if [ -f "$d/ProjectSettings/ProjectVersion.txt" ]; then echo unity
  elif [ -f "$d/project.godot" ]; then echo godot
  elif [ -f "$d/package.json" ] || [ -f "$d/index.html" ]; then echo web
  elif [ -f "$d/Cargo.toml" ]; then echo rust
  elif [ -f "$d/go.mod" ]; then echo go
  elif [ -f "$d/pyproject.toml" ] || [ -f "$d/setup.py" ] || [ -f "$d/requirements.txt" ]; then echo python
  elif compgen -G "$d/*.sln" >/dev/null || compgen -G "$d/*.slnx" >/dev/null || compgen -G "$d/*.csproj" >/dev/null; then echo dotnet
  fi
}

# Walks up to the git root, then one level down, so a Unity project in a subfolder of the repo is found too.
detect_project() {
  local d k sub
  d="${WARMD_PROJECT:-$PWD}"; d="$(cd "$d" && pwd)"
  GIT_ROOT="$(git -C "$d" rev-parse --show-toplevel 2>/dev/null || true)"
  [ -n "$GIT_ROOT" ] && GIT_ROOT="$(cd "$GIT_ROOT" && pwd)"
  PROJECT=""; KIND=""
  local start="$d" stop="${GIT_ROOT:-}"
  while :; do
    k="$(kind_of "$d")"
    if [ -n "$k" ]; then PROJECT="$d"; KIND="$k"; break; fi
    [ "$d" = "$stop" ] && break
    [ "$d" = "$(dirname "$d")" ] && break
    d="$(dirname "$d")"
  done
  stop="${stop:-$start}"
  if [ -z "$PROJECT" ]; then
    for sub in "$stop"/*/; do
      k="$(kind_of "${sub%/}")"
      if [ -n "$k" ]; then PROJECT="${sub%/}"; KIND="$k"; break; fi
    done
  fi
  if [ -z "$PROJECT" ]; then PROJECT="$stop"; KIND=none; fi
  case "$KIND" in unity|godot|web) ADAPTER="$KIND";; *) ADAPTER=generic;; esac
  STATE="$PROJECT/.warmd"
  RUN="$STATE/run"
  mkdir -p "$RUN"
  [ -f "$STATE/.gitignore" ] || echo '*' > "$STATE/.gitignore"
  load_config
}

CFG_build=""; CFG_test=""; CFG_lint=""; CFG_dev=""; CFG_url=""; CFG_base=""; CFG_slots=""; CFG_idle_min=10
CFG_port_env=""; CFG_seed_links=""; CFG_gate=""; CFG_package_method=""; CFG_package_args=""; CFG_shot_method=""
CFG_floor=""; CFG_full=""; CFG_warm=0; CFG_cheap=haiku; CFG_mid=sonnet; CFG_top=opus
CFG_top_paths=''; CFG_top_words='architecture|race condition|concurrency|physics|netcode|security|root cause|crash'
CFG_budget_cheap=40; CFG_budget_mid=100; CFG_budget_top=160
CFG_world_method=""; CFG_world_sources=""; CFG_world_outputs=""; CFG_gfx_tests=""
load_config() {
  local f="$PROJECT/warmd.conf" k v
  [ -f "$f" ] || return 0
  while IFS='=' read -r k v || [ -n "$k" ]; do
    k="${k//[[:space:]]/}"
    case "$k" in ''|\#*) continue;; esac
    case "$k" in *[!a-z_]*) continue;; esac
    v="${v%$'\r'}"; v="${v#\"}"; v="${v%\"}"
    printf -v "CFG_$k" '%s' "$v"
  done < "$f"
}

base_branch() {
  # WARMD_BASE_BRANCH: the automatic merge names the base of the shared checkout, a base worktree without its own warmd.conf agrees
  if [ -n "${WARMD_BASE_BRANCH:-}" ]; then echo "$WARMD_BASE_BRANCH"; return; fi
  if [ -n "$CFG_base" ]; then echo "$CFG_base"; return; fi
  local b; b="$(git -C "$PROJECT" symbolic-ref -q --short refs/remotes/origin/HEAD 2>/dev/null)"
  b="${b#origin/}"
  [ -n "$b" ] && { echo "$b"; return; }
  git -C "$PROJECT" rev-parse -q --verify main >/dev/null 2>&1 && { echo main; return; }
  echo master
}

# run_bounded <label> <cmd...>: agents see one line on success, the error lines on failure, the rest stays in .warmd/last.log
run_bounded() {
  local label="$1" rc t; shift
  t="$(now_ms)"
  "$@" > "$RUN/last.log" 2>&1; rc=$?
  # Real (uncached) full suite: its time lets warmd check pick the full suite when that is cheaper than build plus selection
  [ "$label" = test ] && [ "${FULL_RUN:-0}" = 1 ] && echo $(( $(now_ms) - t )) > "$STATE/full.ms" 2>/dev/null
  if [ $rc = 0 ]; then echo "OK $(secs)s $label"; return 0; fi
  echo "FAIL $(secs)s $label (full log: $(native_path "$RUN/last.log"))"
  summarize_errors "$RUN/last.log"
  return "$rc"
}
summarize_errors() {
  [ -n "$(type -t digest_log)" ] || . "$WARMD_HOME/lib/digest.sh"
  digest_log "$1" && return 0
  sed 's/\x1b\[[0-9;]*[A-Za-z]//g' "$1" | grep -iE 'error|fail|panic|traceback|assert|expected|✗|×|exception' | awk '!seen[$0]++' | cut -c1-200 | head -13 | grep . \
    || { tail -13 "$1" | cut -c1-200; }
}

# Two git calls (tree, file list) and two sha1sum calls (all changed files in chunks, then the lot). Names are part of the key, so a deleted or renamed file changes it too.
code_key() {
  local top="${GIT_ROOT:-}" tree list f k i
  local -a files=() have=()
  [ -n "$top" ] || return 1
  tree="$(git -C "$top" rev-parse 'HEAD^{tree}' 2>/dev/null)"
  list="$(git -C "$top" ls-files -mo --exclude-standard)"
  list="${list//$'\r'/}"
  [ -z "$list" ] || mapfile -t files <<< "$list"
  for f in "${files[@]}"; do [ -f "$top/$f" ] && have+=("$f"); done
  k="$(cd "$top" && {
    echo "$tree"; echo "$list"
    for (( i = 0; i < ${#have[@]}; i += 100 )); do
      { sha1sum -- "${have[@]:i:100}" 2>/dev/null || shasum -- "${have[@]:i:100}"; }
    done
  } | { sha1sum 2>/dev/null || shasum; })"
  echo "${k:0:20}"
}
sha_of() { local k; k="$(printf '%s' "$1" | { sha1sum 2>/dev/null || shasum; })"; echo "${k:0:12}"; }

# A green run stays green until the code changes, across all worktrees. Red is never cached.
cached() {
  local what="$1" key f tmp rc line; shift
  key="$(code_key)" || { slot_now; "$@"; return $?; }
  f="$CACHE_ROOT/green/${key}_$(sha_of "$KIND|$what")"
  if [ "${WARMD_NOCACHE:-0}" != 1 ] && [ -f "$f" ]; then read -r line < "$f"; echo "OK cached, code unchanged: $line"; return 0; fi
  slot_now
  tmp="$(mktemp)"; exec 8>&1; CACHED_OUT="$tmp"; "$@" > "$tmp"; rc=$?; CACHED_OUT=""; exec 8>&-; cat "$tmp"
  if [ $rc = 0 ]; then
    mkdir -p "$CACHE_ROOT/green"; tail -1 "$tmp" | cut -c1-120 > "$f"
    find "$CACHE_ROOT/green" -type f -mtime +7 -delete 2>/dev/null
  fi
  rm -f "$tmp"; return $rc
}

# Queue: at most <slots> heavy runs per machine across all projects. A slot is a directory (mkdir is atomic) holding the owner pid, dead owners expire.
slots_max() { tune_slots; }
slot_try() {
  [ -n "$SLOT" ] && return 0
  local i n holder dir="$CACHE_ROOT/slots"
  n="$(slots_max)"
  for (( i = 1; i <= n; i++ )); do
    if mkdir "$dir/$i" 2>/dev/null; then echo "$$" > "$dir/$i/pid"; SLOT="$dir/$i"; return 0; fi
    [ -d "$dir" ] || { mkdir -p "$dir"; i=$((i - 1)); continue; }
    holder=""; read -r holder 2>/dev/null < "$dir/$i/pid"
    if [ -n "$holder" ]; then shell_alive "$holder" || rm -rf "${dir:?}/$i"
    elif [ -n "$(find "$dir/$i" -maxdepth 0 -mmin +1 2>/dev/null)" ]; then rm -rf "${dir:?}/$i"; fi
  done
  return 1
}
# While SLOT_LAZY=1 (warmd test) the slot is only taken when the test really runs, a cache hit never queues. cached() ends the lazy mode.
SLOT_LAZY=0
slot_now() { SLOT_LAZY=0; slot_take; }
slot_take() {
  [ "$SLOT_LAZY" = 1 ] && return 0
  slot_try && return 0
  echo "(queued: $(slots_max) heavy runs active)"; queue_mark
  until slot_try; do sleep 3; orphan_check; done
  queue_done; echo "(slot free after $(secs)s)"
}

changed_files() {
  [ -n "$GIT_ROOT" ] || return 0
  local base mb; base="$(base_branch)"
  mb="$(git -C "$GIT_ROOT" merge-base HEAD "$base" 2>/dev/null || git -C "$GIT_ROOT" rev-parse HEAD 2>/dev/null)"
  # Unity leaves Assets/InitTestScene<guid>.unity behind when a PlayMode run dies: generated, never a change.
  { [ -n "$mb" ] && git -C "$GIT_ROOT" diff --name-only "$mb" 2>/dev/null; git -C "$GIT_ROOT" ls-files -o --exclude-standard; } | tr -d '\r' \
    | grep -vE '(^|/)InitTestScene[0-9a-fA-F-]+\.unity(\.meta)?$' | sort -u
}

# Names of changed source files, as an alternation: lib/foo_bar.ts -> foo_bar. Partial files (Ship.Net.cs) count as Ship.
changed_names() { changed_files | grep -E "$1" | sed 's#.*/##; s/\.[^.]*$//; s/\..*$//' | sort -u | paste -sd'|' -; }

# shellcheck disable=SC2120  # check calls it without a filter on purpose: that is the full suite
run_tests() { merge_guard; SLOT_LAZY=1; FULL_RUN=0; [ -z "${1:-}" ] && FULL_RUN=1; a_test "$@"; local rc=$?; SLOT_LAZY=0; FULL_RUN=0; return $rc; }

# Build, then only the affected tests. On a small suite that costs more than the plain run: when the last full suite
# (full.ms) was faster than the last selective check (check.ms), check runs the full suite instead and stays under it.
run_check() {
  merge_guard
  local full chk t rc
  full="$(cat "$STATE/full.ms" 2>/dev/null)"; chk="$(cat "$STATE/check.ms" 2>/dev/null)"
  if [ "${WARMD_SELECT:-0}" != 1 ] && [ -n "$full" ] && [ -n "$chk" ] && [ "$full" -lt "$chk" ] 2>/dev/null; then
    echo "(running all tests: the full suite took ${full}ms, build plus selection ${chk}ms)"
    run_tests; return
  fi
  t="$(now_ms)"
  a_build || return 1
  a_check; rc=$?
  echo $(( $(now_ms) - t )) > "$STATE/check.ms" 2>/dev/null
  return $rc
}

# Reproducible proof on your own project: cold, warm and cached, plus what an agent has to read.
run_bench() {
  local self="$WARMD_HOME/bin/warmd" s cold warm cached raw out
  timed() { s="$(now_ms)"; "$@" > "$RUN/bench.out" 2>&1; echo $(( $(now_ms) - s )); }
  a_stop > /dev/null 2>&1
  cold="$(WARMD_NOCACHE=1 timed bash "$self" test "$@")"
  warm="$(WARMD_NOCACHE=1 timed bash "$self" test "$@")"
  out="$(wc -c < "$RUN/bench.out" | tr -d ' ')"
  raw=""; [ -f "$RUN/last.log" ] && raw="$(wc -c < "$RUN/last.log" | tr -d ' ')"
  bash "$self" test "$@" > /dev/null 2>&1
  cached="$(timed bash "$self" test "$@")"
  {
    echo "warmd bench on $KIND"
    echo "cold    $cold ms"
    echo "warm    $warm ms, $(( (cold - warm) * 100 / (cold > 0 ? cold : 1) ))% faster"
    echo "cached  $cached ms, $(( (cold - cached) * 100 / (cold > 0 ? cold : 1) ))% faster"
    if [ -n "$raw" ] && [ "${raw:-0}" -gt "$out" ]; then echo "output  $raw bytes raw, $out bytes shown, $(( (raw - out) * 100 / raw ))% fewer tokens"; fi
  } | tee "$RUN/bench.txt"
}

# Nothing is ever sent by warmd. This prints a prefilled issue link, the user reads it and decides.
common_feedback() {
  local repo=Vyrenbusiness-source/warmd-fewer-tokens-faster-agents body
  body="warmd $WARMD_VERSION, $OS, $KIND project

What got faster or better, or what broke:

$(cat "$RUN/bench.txt" 2>/dev/null)"
  echo "This text goes into the issue, nothing is sent until you submit it:"
  echo "$body" | cut -c1-100
  echo
  echo "https://github.com/$repo/issues/new?title=Feedback&body=$(printf '%s' "$body" | sed 's/%/%25/g; s/ /%20/g; s/,/%2C/g; s/#/%23/g; s/&/%26/g' | awk 'BEGIN{ORS="%0A"}{print}')"
}

# Outline with line numbers. Agents read the range they need, not a 2000-line file.
code_map() {
  [ -n "${1:-}" ] || { echo "warmd map <file or name>"; return 2; }
  local files
  if [ -f "$1" ]; then files="$1"
  else files="$(find "$PROJECT" -type f \( -name "$1" -o -name "$1.*" \) -not -name '*.meta' -not -path '*/node_modules/*' -not -path '*/.git/*' -not -path '*/Library/*' -not -path '*/.godot/*' -not -path '*/dist/*' -not -path '*/build/*' | sort | head -8)"; fi
  [ -n "$files" ] || { echo "warmd map: nothing named $1"; return 1; }
  printf '%s\n' "$files" | while IFS= read -r f; do
    echo "== ${f##*/}"
    case "$f" in
      *.cs) grep -nE '^ {0,8}(\[[^]]*\] *)?((public|private|protected|internal|static|override|sealed|partial|abstract|async|virtual|unsafe|readonly) +)*(class|struct|enum|interface) |^ {4,8}(\[[^]]*\] *)?((public|private|protected|internal|static|override|sealed|abstract|async|virtual|unsafe) +)*[A-Za-z_][][A-Za-z_0-9<>,.]* +[A-Za-z_][A-Za-z_0-9]*(<[^>]*>)? *\(' "$f" | grep -vE ':\s*(return|new|await|throw|else|if|for|foreach|while|switch|using|var) ';;
      *.gd) grep -nE '^(class_name|class|extends|signal|enum|const|@export|static func|func) ' "$f";;
      *.ts|*.tsx|*.js|*.jsx|*.mjs|*.vue|*.svelte) grep -nE '^(export +)?(default +)?(async +)?(function|class|const|interface|type|enum) ' "$f";;
      *.py) grep -nE '^\s*(async +)?(def|class) ' "$f";;
      *.rs) grep -nE '^\s*(pub(\([a-z]+\))? +)?(async +)?(fn|struct|enum|trait|impl|mod) ' "$f";;
      *.go) grep -nE '^(func|type) ' "$f";;
      *.css|*.scss) grep -nE '^[^ @}/*][^{]*\{|^@(media|layer|container)' "$f";;
      *.html) grep -nE '<(section|header|footer|main|nav|article|h1|h2|form)\b' "$f";;
      *) grep -nE '^[A-Za-z#]' "$f";;
    esac | sed -E 's/^([0-9]+):[[:space:]]*/\1 /' | cut -c1-110
  done | head -60
}

# Only on request: a silent self-update would run new code on every machine and break the promise that warmd sends and fetches nothing by itself.
common_update() {
  [ -d "$WARMD_HOME/.git" ] || { echo "FAIL not a git install, run install.sh again"; return 2; }
  local before; before="$(git -C "$WARMD_HOME" rev-parse --short HEAD)"
  git -C "$WARMD_HOME" pull -q --ff-only || { echo "FAIL could not update, local changes in $(native_path "$WARMD_HOME")?"; return 1; }
  local after; after="$(git -C "$WARMD_HOME" rev-parse --short HEAD)"
  if [ "$before" = "$after" ]; then echo "OK already current ($after)"; else echo "OK updated $before to $after"; fi
}

common_status() {
  if [ "$KIND" = none ]; then echo "warmd $WARMD_VERSION: no known project type at $(native_path "$PROJECT")"; else echo "warmd $WARMD_VERSION: $KIND project at $(native_path "$PROJECT")"; fi
  local held=("$CACHE_ROOT"/slots/*); [ -e "${held[0]}" ] || held=()
  echo "heavy runs: ${#held[@]} of $(slots_max)"
  [ -n "$(type -t team_agents)" ] || . "$WARMD_HOME/lib/team.sh" 2>/dev/null
  [ -n "$(type -t team_agents)" ] && echo "parallel agents: up to $(team_agents)${CFG_agents:+ (warmd.conf)}"
  local m avail total; if m="$(tune_mem)"; then read -r avail total <<< "$m"; echo "RAM free: $(( avail / 1048576 )) MB of $(( total / 1048576 )) MB ($(( avail * 100 / total ))%)"; fi
  # Every Unity editor on the machine with its project: an editor someone else started blocks this project's daemon
  local pid path flags what n=0
  while IFS='	' read -r pid path flags; do
    [ -n "$pid" ] || continue; n=$((n+1))
    case "$flags" in *d*) what="warmd daemon";; *b*) what=batchmode;; *) what=window;; esac
    echo "Unity pid $pid: $path ($what)$([ "${path,,}" = "$(native_path "$PROJECT" | tr '[:upper:]' '[:lower:]')" ] && echo ", this project")"
  done < <([ "$KIND" = unity ] || [ "${WARMD_STATUS_UNITY:-0}" = 1 ] && unity_procs)
  [ "$KIND" = unity ] && [ $n = 0 ] && echo "Unity editors: none running"
  # The running batch: per branch its last commit and how old it is
  local b wt line now; b="$([ -n "$GIT_ROOT" ] && git -C "$PROJECT" rev-parse --path-format=absolute --git-common-dir 2>/dev/null)/warmd-batch"
  if [ -s "$b" ]; then
    now="$(date +%s)"
    while IFS= read -r wt; do
      wt="${wt%$'\r'}"; [ -n "$wt" ] || continue
      line="$(git -C "$wt" log -1 --format='%h %ct %s' 2>/dev/null)" || { echo "batch $wt: folder missing"; continue; }
      read -r sha ct subj <<< "$line"
      echo "batch $(git -C "$wt" branch --show-current 2>/dev/null): $sha $(( (now - ct) / 60 )) min ago, $(printf '%s' "$subj" | cut -c1-50)"
    done < "$b"
  fi
}

common_doctor() {
  echo "detected: $([ "$KIND" = none ] && echo "no known project type" || echo "$KIND") at $(native_path "$PROJECT")"
  local fix_git="install git with your package manager" fix_py="install python 3 with your package manager" bin="${WARMD_BIN:-$HOME/.local/bin}"
  [ "$OS" = win ] && { fix_git="winget install --id Git.Git -e"; fix_py="winget install --id Python.Python.3.12 -e"; }
  # printf %()T needs bash 4.2, macOS ships 3.2
  if [ "${BASH_VERSINFO[0]}" -gt 4 ] || { [ "${BASH_VERSINFO[0]}" = 4 ] && [ "${BASH_VERSINFO[1]}" -ge 2 ]; }; then echo "ok bash $BASH_VERSION"
  else echo "MISSING bash 4.2 or newer, this is $BASH_VERSION. Fix: $([ "$OS" = win ] && echo "$fix_git" || echo "install a current bash")"; fi
  command -v git >/dev/null 2>&1 && echo "ok git" || echo "MISSING git (cache, check and agents need it). Fix: $fix_git"
  [ -n "$GIT_ROOT" ] && echo "ok git repo" || echo "note: not a git repo, cache and agent commands are off. Fix: git init"
  if command -v warmd >/dev/null 2>&1; then echo "ok warmd on PATH"
  else echo "MISSING warmd on PATH in this shell. Fix: echo 'export PATH=\"$bin:\$PATH\"' >> ~/.bashrc, then open a new terminal"; fi
  if [ "$OS" = win ]; then
    command -v powershell.exe >/dev/null 2>&1 && echo "ok powershell.exe" || echo "MISSING powershell.exe on PATH (process checks need it). Fix: add C:\\Windows\\System32\\WindowsPowerShell\\v1.0 to PATH"
    # Git Bash takes PATH from Windows, so a folder seen here is seen by PowerShell and cmd too
    if [ ! -f "$bin/warmd.cmd" ]; then echo "MISSING warmd.cmd, PowerShell and cmd cannot start warmd. Fix: run install.sh again in Git Bash"
    else case ":$PATH:" in *":$bin:"*) echo "ok warmd.cmd for PowerShell and cmd";;
      *) echo "MISSING $(native_path "$bin") on the Windows user PATH. Fix: run install.sh again, or in PowerShell: [Environment]::SetEnvironmentVariable('Path', \"\$([Environment]::GetEnvironmentVariable('Path','User'));$(cygpath -w "$bin" 2>/dev/null)\", 'User')";; esac; fi
  fi
  # The Store alias python.exe exists but runs nothing, so try a real import
  local p ok_py=""; for p in python3 python; do "$p" -c 'import json' >/dev/null 2>&1 && { ok_py="$p"; break; }; done
  [ -n "$ok_py" ] && echo "ok $ok_py (agent hooks)" || echo "MISSING python (only agent hooks need it, warmd init works without). Fix: $fix_py"
}

# What an agent pays for before it does anything. Tests are rarely the biggest cost, this shows the real one.
common_audit() {
  local root="${GIT_ROOT:-$PROJECT}" f size total=0
  echo "loaded on every turn (each line costs on all following turns):"
  for f in CLAUDE.md AGENTS.md .cursorrules; do
    [ -f "$root/$f" ] || continue
    size="$(wc -c < "$root/$f" | tr -d ' ')"; total=$((total + size))
    echo "  ~$((size / 4)) tokens  every turn  $f"
  done
  [ "$total" -gt 20000 ] && echo "  warning: over 5k tokens, move detail to files read on demand"
  echo "largest documents an agent may read:"
  { git -C "$root" ls-files '*.md' '*.txt' 2>/dev/null || find "$root" -name '*.md' -not -path '*/node_modules/*'; } | tr -d '\r' | while IFS= read -r f; do
    [ -f "$root/$f" ] && echo "$(wc -c < "$root/$f" | tr -d ' ') $f"
  done | sort -rn | head -6 | awk '{printf "  ~%d tokens  %s\n", $1/4, $2}'
  echo "images: about width x height / 750 tokens. warmd shot costs ~520 (desktop) and ~560 (phone), a full 1440x900 shot ~1730."
}

# Instructions for any agent: short, because this text is loaded on every turn. Claude Code reads agents and CLAUDE.md from the repo root.
common_init() {
  local f done=0 root="${GIT_ROOT:-$PROJECT}"
  mkdir -p "$root/.claude/agents"
  cp "$WARMD_HOME"/agents/warmd-*.md "$root/.claude/agents/"
  for f in CLAUDE.md AGENTS.md; do
    [ -f "$root/$f" ] || continue
    instr_sync "$root/$f"; done=1
  done
  [ $done = 1 ] || instr_sync "$root/AGENTS.md"
  echo "OK agent definitions in .claude/agents, instructions in CLAUDE.md or AGENTS.md"
}

# The warmd block in CLAUDE.md or AGENTS.md stays current: between its markers it is replaced when warmd brings a newer one
# (warmd init, and the session start hook in the shared checkout). A file without markers gets the block appended, an older
# unmarked block (a "## warmd" section that starts with "Use `warmd` for every build") is replaced in place.
INSTR_START='<!-- warmd: kept current by warmd, edits between these lines are replaced -->'
INSTR_END='<!-- /warmd -->'
instr_sync() { # file -> 0 when it changed, 1 when it was current
  local f="$1" blk="$WARMD_HOME/agents/INSTRUCTIONS.md" mode=append
  [ -f "$blk" ] || return 1
  if [ -f "$f" ]; then
    if grep -qxF "$INSTR_START" "$f"; then mode=marked
    elif grep -qx '## warmd' "$f" && grep -qF 'Use `warmd` for every build' "$f"; then mode=legacy; fi
  fi
  awk -v s="$INSTR_START" -v e="$INSTR_END" -v bf="$blk" -v mode="$mode" '
    BEGIN { while ((getline l < bf) > 0) b = b l "\n"; blk = s "\n" b e }
    mode == "marked" && $0 == s { skip = 1; print blk; next }
    mode == "marked" && skip { if ($0 == e) skip = 0; next }
    mode == "legacy" && !done && $0 == "## warmd" { skip = 1; done = 1; print blk; next }
    mode == "legacy" && skip { if ($0 ~ /^## / || $0 ~ /^# /) { skip = 0; print ""; print } ; next }
    { print }
    END { if (mode == "append") { if (NR > 0) print ""; print blk } }' "$f" 2>/dev/null > "$f.warmd" < /dev/null
  if [ -f "$f" ] && cmp -s "$f" "$f.warmd"; then rm -f "$f.warmd"; return 1; fi
  mv -f "$f.warmd" "$f"
}
