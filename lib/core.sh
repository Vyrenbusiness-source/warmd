# Project detection, config, bounded output, green cache, machine-wide queue, affected tests, code map.
T0=$(date +%s)
secs() { echo $(( $(date +%s) - T0 )); }
TIMEOUT="${WARMD_TIMEOUT:-900}"
CACHE_ROOT="${XDG_CACHE_HOME:-$HOME/.cache}/warmd"
LOCK=""; SLOT=""; JOBLOCK=""; MERGELOCK=""
PARENT_PID="$PPID"
on_exit() {
  [ -n "$LOCK" ] && rmdir "$LOCK" 2>/dev/null
  [ -n "$SLOT" ] && rm -rf "$SLOT"
  [ -n "$JOBLOCK" ] && rm -rf "$JOBLOCK"
  [ -n "$MERGELOCK" ] && rm -f "$MERGELOCK"
  return 0
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
  [ -n "$(find "$f" -mmin +240 2>/dev/null)" ] && { rm -f "$f"; return 0; }
  grep -qxF "$GIT_ROOT" "$f" && return 0
  echo "FAIL a batch runs, this is the shared checkout. Work in the worktree from your task file. Ending the batch: warmd batch-done, on purpose here: WARMD_BASE=1"; exit 5
}

# Changes during a merge end up in the merge. Only the merge's own checks may run here, everyone else gets a clear refusal.
merge_guard() {
  [ "${WARMD_IN_MERGE:-0}" = 1 ] && return 0
  local f="$STATE/merge.owner" owner
  if [ -f "$f" ]; then
    owner="$(cat "$f" 2>/dev/null)"
    if shell_alive "$owner"; then echo "FAIL a merge is running in this checkout, work in your own worktree"; exit 4; fi
    rm -f "$f"
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
  elif ls "$d"/*.sln "$d"/*.slnx "$d"/*.csproj >/dev/null 2>&1; then echo dotnet
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

CFG_build=""; CFG_test=""; CFG_lint=""; CFG_dev=""; CFG_url=""; CFG_base=""; CFG_slots=""; CFG_idle_min=30
CFG_port_env=""; CFG_seed_links=""; CFG_gate=""; CFG_package_method=""; CFG_package_args=""; CFG_shot_method=""
CFG_floor=""; CFG_warm=0; CFG_cheap=haiku; CFG_mid=sonnet; CFG_top=opus
CFG_top_paths=''; CFG_top_words='architecture|race condition|concurrency|physics|netcode|security|root cause|crash'
CFG_budget_cheap=40; CFG_budget_mid=100; CFG_budget_top=160
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
  if [ -n "$CFG_base" ]; then echo "$CFG_base"; return; fi
  local b; b="$(git -C "$PROJECT" symbolic-ref -q --short refs/remotes/origin/HEAD 2>/dev/null)"
  b="${b#origin/}"
  [ -n "$b" ] && { echo "$b"; return; }
  git -C "$PROJECT" rev-parse -q --verify main >/dev/null 2>&1 && { echo main; return; }
  echo master
}

# run_bounded <label> <cmd...>: agents see one line on success, the error lines on failure, the rest stays in .warmd/last.log
run_bounded() {
  local label="$1" rc; shift
  "$@" > "$RUN/last.log" 2>&1; rc=$?
  if [ $rc = 0 ]; then echo "OK $(secs)s $label"; return 0; fi
  echo "FAIL $(secs)s $label (full log: $(native_path "$RUN/last.log"))"
  summarize_errors "$RUN/last.log"
  return "$rc"
}
summarize_errors() {
  sed 's/\x1b\[[0-9;]*[A-Za-z]//g' "$1" | grep -iE 'error|fail|panic|traceback|assert|expected|✗|×|exception' | awk '!seen[$0]++' | cut -c1-200 | head -13 | grep . \
    || { tail -13 "$1" | cut -c1-200; }
}

code_key() {
  local top="${GIT_ROOT:-}"
  [ -n "$top" ] || return 1
  ( cd "$top" && {
      git rev-parse 'HEAD^{tree}' 2>/dev/null
      git ls-files -mo --exclude-standard | tr -d '\r' | sort -u | while IFS= read -r f; do
        echo "$f"; [ -f "$f" ] && { sha1sum < "$f" 2>/dev/null || shasum < "$f"; }
      done
    } | { sha1sum 2>/dev/null || shasum; } | cut -c1-20 )
}
sha_of() { printf '%s' "$1" | { sha1sum 2>/dev/null || shasum; } | cut -c1-12; }

# A green run stays green until the code changes, across all worktrees. Red is never cached.
cached() {
  local what="$1" key f tmp rc; shift
  key="$(code_key)" || { "$@"; return $?; }
  f="$CACHE_ROOT/green/${key}_$(sha_of "$KIND|$what")"
  if [ "${WARMD_NOCACHE:-0}" != 1 ] && [ -f "$f" ]; then echo "OK cached, code unchanged: $(cat "$f")"; return 0; fi
  tmp="$(mktemp)"; "$@" > "$tmp"; rc=$?; cat "$tmp"
  if [ $rc = 0 ]; then
    mkdir -p "$CACHE_ROOT/green"; tail -1 "$tmp" | cut -c1-120 > "$f"
    find "$CACHE_ROOT/green" -type f -mtime +7 -delete 2>/dev/null
  fi
  rm -f "$tmp"; return $rc
}

# Queue: at most <slots> heavy runs per machine across all projects. A slot is a directory (mkdir is atomic) holding the owner pid, dead owners expire.
slots_max() {
  if [ -n "$CFG_slots" ]; then echo "$CFG_slots"; return; fi
  if [ "$ADAPTER" = unity ]; then echo 2; return; fi
  local n=$(( $(cpu_count) / 2 )); [ "$n" -lt 2 ] && n=2; echo "$n"
}
slot_try() {
  [ -n "$SLOT" ] && return 0
  local i holder dir="$CACHE_ROOT/slots"
  mkdir -p "$dir"
  for i in $(seq 1 "$(slots_max)"); do
    if mkdir "$dir/$i" 2>/dev/null; then echo "$$" > "$dir/$i/pid"; SLOT="$dir/$i"; return 0; fi
    holder="$(cat "$dir/$i/pid" 2>/dev/null)"
    if [ -n "$holder" ]; then shell_alive "$holder" || rm -rf "$dir/$i"
    elif [ -n "$(find "$dir/$i" -maxdepth 0 -mmin +1 2>/dev/null)" ]; then rm -rf "$dir/$i"; fi
  done
  return 1
}
slot_take() {
  slot_try && return 0
  echo "(queued: $(slots_max) heavy runs active)"
  until slot_try; do sleep 3; orphan_check; done
  echo "(slot free after $(secs)s)"
}

changed_files() {
  [ -n "$GIT_ROOT" ] || return 0
  local base mb; base="$(base_branch)"
  mb="$(git -C "$GIT_ROOT" merge-base HEAD "$base" 2>/dev/null || git -C "$GIT_ROOT" rev-parse HEAD 2>/dev/null)"
  { [ -n "$mb" ] && git -C "$GIT_ROOT" diff --name-only "$mb"; git -C "$GIT_ROOT" ls-files -o --exclude-standard; } | tr -d '\r' | sort -u
}

# Names of changed source files, as an alternation: lib/foo_bar.ts -> foo_bar. Partial files (Ship.Net.cs) count as Ship.
changed_names() { changed_files | grep -E "$1" | sed 's#.*/##; s/\.[^.]*$//; s/\..*$//' | sort -u | paste -sd'|' -; }

run_tests() { merge_guard; a_test "$@"; }

run_check() {
  merge_guard
  a_build || return 1
  a_check
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

common_status() {
  echo "warmd $WARMD_VERSION: $KIND project at $(native_path "$PROJECT")"
  echo "heavy runs: $(ls "$CACHE_ROOT/slots" 2>/dev/null | wc -l | tr -d ' ') of $(slots_max)"
}

common_doctor() {
  echo "detected: $KIND at $(native_path "$PROJECT")"
  command -v git >/dev/null 2>&1 && echo "ok git" || echo "MISSING git (cache, check and agents need it)"
  [ -n "$GIT_ROOT" ] && echo "ok git repo" || echo "note: not a git repo, cache and agent commands are off"
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
  local f block="$WARMD_HOME/agents/INSTRUCTIONS.md" done=0 root="${GIT_ROOT:-$PROJECT}"
  mkdir -p "$root/.claude/agents"
  cp "$WARMD_HOME"/agents/warmd-*.md "$root/.claude/agents/"
  for f in CLAUDE.md AGENTS.md; do
    [ -f "$root/$f" ] || continue
    grep -q 'warmd' "$root/$f" || { printf '\n' >> "$root/$f"; cat "$block" >> "$root/$f"; }
    done=1
  done
  [ $done = 1 ] || cp "$block" "$root/AGENTS.md"
  echo "OK agent definitions in .claude/agents, instructions in CLAUDE.md or AGENTS.md"
}
