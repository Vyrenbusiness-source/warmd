# Project detection, config, bounded output, green cache, machine-wide queue, affected tests, code map.
T0=$(date +%s)
secs() { echo $(( $(date +%s) - T0 )); }
TIMEOUT="${WARMD_TIMEOUT:-900}"
CACHE_ROOT="${XDG_CACHE_HOME:-$HOME/.cache}/warmd"
LOCK=""; SLOT=""
on_exit() { [ -n "$LOCK" ] && rmdir "$LOCK" 2>/dev/null; [ -n "$SLOT" ] && rm -rf "$SLOT"; return 0; }
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
CFG_warm=0; CFG_cheap=haiku; CFG_mid=sonnet; CFG_top=opus
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
    if mkdir "$dir/$i" 2>/dev/null; then self_pid > "$dir/$i/pid"; SLOT="$dir/$i"; return 0; fi
    holder="$(cat "$dir/$i/pid" 2>/dev/null)"
    if [ -n "$holder" ]; then pid_alive "$holder" || rm -rf "$dir/$i"
    elif [ -n "$(find "$dir/$i" -maxdepth 0 -mmin +1 2>/dev/null)" ]; then rm -rf "$dir/$i"; fi
  done
  return 1
}
slot_take() {
  slot_try && return 0
  echo "(queued: $(slots_max) heavy runs active)"
  until slot_try; do sleep 3; done
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

run_tests() { slot_free_cached "$@"; }
slot_free_cached() { a_test "$@"; }

run_check() {
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
  echo "warmd bench on $KIND"
  echo "cold    $cold ms"
  echo "warm    $warm ms, $(( (cold - warm) * 100 / (cold > 0 ? cold : 1) ))% faster"
  echo "cached  $cached ms, $(( (cold - cached) * 100 / (cold > 0 ? cold : 1) ))% faster"
  if [ -n "$raw" ] && [ "${raw:-0}" -gt "$out" ]; then echo "output  $raw bytes raw, $out bytes shown, $(( (raw - out) * 100 / raw ))% fewer tokens"; fi
}

# Outline with line numbers. Agents read the range they need, not a 2000-line file.
code_map() {
  [ -n "${1:-}" ] || { echo "warmd map <file or name>"; return 2; }
  local files
  if [ -f "$1" ]; then files="$1"
  else files="$(find "$PROJECT" -type f \( -name "$1" -o -name "$1.*" \) -not -path '*/node_modules/*' -not -path '*/.git/*' -not -path '*/Library/*' -not -path '*/.godot/*' -not -path '*/dist/*' -not -path '*/build/*' | sort | head -8)"; fi
  [ -n "$files" ] || { echo "warmd map: nothing named $1"; return 1; }
  printf '%s\n' "$files" | while IFS= read -r f; do
    echo "== ${f##*/}"
    case "$f" in
      *.cs) grep -nE '^ {0,8}(\[[^]]*\] *)?((public|private|protected|internal|static|override|sealed|partial|abstract|async|virtual|unsafe|readonly) +)*(class|struct|enum|interface) |^ {4,8}(\[[^]]*\] *)?((public|private|protected|internal|static|override|sealed|abstract|async|virtual|unsafe) +)*[A-Za-z_][A-Za-z_0-9<>,.\[\]]* +[A-Za-z_][A-Za-z_0-9]*(<[^>]*>)? *\(' "$f" | grep -vE ':\s*(return|new|await|throw|else|if|for|foreach|while|switch|using|var) ';;
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

# Instructions for any agent: short, because this text is loaded on every turn.
common_init() {
  local f block="$WARMD_HOME/agents/INSTRUCTIONS.md" done=0
  mkdir -p "$PROJECT/.claude/agents"
  cp "$WARMD_HOME"/agents/warmd-*.md "$PROJECT/.claude/agents/"
  for f in CLAUDE.md AGENTS.md; do
    [ -f "$PROJECT/$f" ] || continue
    grep -q 'warmd' "$PROJECT/$f" || { printf '\n' >> "$PROJECT/$f"; cat "$block" >> "$PROJECT/$f"; }
    done=1
  done
  [ $done = 1 ] || cp "$block" "$PROJECT/AGENTS.md"
  echo "OK agent definitions in .claude/agents, instructions in CLAUDE.md or AGENTS.md"
}
