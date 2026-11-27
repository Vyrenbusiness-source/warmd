# warmd mutate: do the tests notice a wrong line? One operator or value is flipped on a changed line (< and <=, + and -,
# true and false, a number plus one, == and !=, -lt and -le in shell), the selected tests run, and every mutant has to turn
# them red. A mutant that stays green is listed as file:line: no test checks that line.
# Changed lines only (git diff against the base), GDScript, shell, Python and JS/TS. Test files are never mutated.
# The file is changed in place and always restored (trap, also on Ctrl+C), nothing is ever staged or committed.
# Runs only when asked: at merge (mutate=merge in warmd.conf, the gate calls mutate_gate) or nightly, under a time limit.
#   warmd.conf  mutate_cmd=<command> (default: warmd check without cache)   mutate_limit=<seconds> (default 900)
#   A line with "warmd: nomutate" in it is skipped (an equivalent mutant, the same behavior on purpose).
reg mutate "warmd mutate [--base REF] [--limit S] [--cmd C]  flip one operator per changed line, each must turn a test red" mutate_main

# Per language: the first mutation the line allows, as "<new line>\037<old> -> <new>" (GDScript lines hold tabs). Nothing for a line without one.
# Strings and comments are masked first, a flipped character in a message is no mutant.
read -r -d '' MUT_AWK <<'EOF' || true
function mask(s, lang,   i, c, q, out, n, p) {
  out = ""; q = ""; n = length(s)
  for (i = 1; i <= n; i++) {
    c = substr(s, i, 1)
    if (q != "") { out = out "\001"; if (c == "\\" && !(q == "'" && lang == "sh")) { i++; out = out "\001" } else if (c == q) q = ""; continue }
    if (c == "\"" || c == "'" || (c == "`" && lang == "js")) { q = c; out = out "\001"; continue }
    p = (i == 1) ? " " : substr(s, i - 1, 1)
    if (c == "#" && lang != "js" && p ~ /[ \t]/) { while (i <= n) { out = out "\001"; i++ }; break }
    if (c == "/" && lang == "js" && substr(s, i + 1, 1) == "/") { while (i <= n) { out = out "\001"; i++ }; break }
    out = out c
  }
  return out
}
# the first match of re in the masked line m: replace the core part (core) of the match by rep in the real line s
function flip(re, core, rep,   tok, pre, k) {
  if (!match(m, re)) return 0
  tok = substr(s, RSTART, RLENGTH); k = index(tok, core); if (k == 0) return 0
  pre = substr(s, 1, RSTART - 1)
  NEW = pre substr(tok, 1, k - 1) rep substr(tok, k + length(core)) substr(s, RSTART + RLENGTH)
  DESC = core " -> " rep
  return 1
}
function bump(   tok, num, a, b, pre, post, n, i, nn) {
  if (lang == "sh") re = "(^|[^A-Za-z0-9_.${&-])[0-9]+([^A-Za-z0-9_.<>]|$)"
  else re = "(^|[^A-Za-z0-9_.$])[0-9]+(\\.[0-9]+)?([^A-Za-z0-9_.]|$)"
  if (!match(m, re)) return 0
  tok = substr(s, RSTART, RLENGTH); pre = substr(s, 1, RSTART - 1); post = substr(s, RSTART + RLENGTH)
  match(tok, /[0-9]+(\.[0-9]+)?/); num = substr(tok, RSTART, RLENGTH)
  a = substr(tok, 1, RSTART - 1); b = substr(tok, RSTART + RLENGTH)
  n = split(num, part, "."); nn = (part[1] + 1) (n > 1 ? "." part[2] : "")
  NEW = pre a nn b post; DESC = num " -> " nn
  return 1
}
{
  s = $0; lang = LANG; t = s; sub(/^[ \t]+/, "", t)
  if (t == "" || t ~ /^(#|\/\/|\/\*|\*)/ || s ~ /warmd: nomutate/) next
  m = mask(s, lang)
  if (lang == "sh") {
    if (flip("(^|[ \t])-lt([ \t]|$)", "-lt", "-le") || flip("(^|[ \t])-le([ \t]|$)", "-le", "-lt") ||
        flip("(^|[ \t])-gt([ \t]|$)", "-gt", "-ge") || flip("(^|[ \t])-ge([ \t]|$)", "-ge", "-gt") ||
        flip("(^|[ \t])-eq([ \t]|$)", "-eq", "-ne") || flip("(^|[ \t])-ne([ \t]|$)", "-ne", "-eq") ||
        flip(" == ", "==", "!=") || flip(" != ", "!=", "==") ||
        flip(" \\+ ", "+", "-") || flip(" - ", "-", "+") ||
        flip("(^|[^A-Za-z0-9_-])true([^A-Za-z0-9_-]|$)", "true", "false") || flip("(^|[^A-Za-z0-9_-])false([^A-Za-z0-9_-]|$)", "false", "true") ||
        bump()) { print NEW "\037" DESC }
    next
  }
  T = (lang == "py") ? "True" : "true"; F = (lang == "py") ? "False" : "false"
  if (flip("[^<]<=", "<=", "<") || flip("[^>]>=", ">=", ">") ||
      flip("[^<]<[^<=-]", "<", "<=") || flip("[^>=-]>[^>=]", ">", ">=") ||
      flip("===", "===", "!==") || flip("!==", "!==", "===") ||
      flip("[^=!<>]==[^=]", "==", "!=") || flip("!=[^=]", "!=", "==") ||
      flip(" \\+= ", "+=", "-=") || flip(" -= ", "-=", "+=") ||
      flip(" \\+ ", "+", "-") || flip(" - ", "-", "+") ||
      flip("(^|[^A-Za-z0-9_])" T "([^A-Za-z0-9_]|$)", T, F) || flip("(^|[^A-Za-z0-9_])" F "([^A-Za-z0-9_]|$)", F, T) ||
      bump()) { print NEW "\037" DESC }
}
EOF

# Language of a file for mutation, nothing when it is not code warmd mutates or when it is a test
mut_lang() { # path relative to the project
  local f="$1" l=""
  case "$f" in */tests/*|tests/*|*/test/*|test/*|*/spec/*|spec/*|*/__tests__/*|*test_*|*_test.*|*.test.*|*.spec.*|*/addons/*|addons/*) return 1;; esac
  case "$f" in
    *.gd) l=gd;; *.sh|*.bash) l=sh;; *.py) l=py;;
    *.ts|*.tsx|*.js|*.jsx|*.mjs|*.cjs|*.mts|*.cts) l=js;;
    *.*) return 1;;
    *) head -n 1 "$PROJECT/$f" 2>/dev/null | grep -qE '^#!.*\b(ba)?sh\b' && l=sh;;
  esac
  [ -n "$l" ] && echo "$l"
}

# Changed lines against a ref (working tree included) as "file<TAB>line", files relative to the project
mut_lines() { # ref
  local prefix; prefix="$(git -C "$PROJECT" rev-parse --show-prefix 2>/dev/null)"
  git -C "$PROJECT" diff -U0 --no-renames --no-color "$1" -- . 2>/dev/null | tr -d '\r' | awk -v P="$prefix" '
    /^\+\+\+ / { f = substr($0, 5); sub(/^b\//, "", f); if (f == "/dev/null") f = ""; else if (P != "" && index(f, P) == 1) f = substr(f, length(P) + 1); else if (P != "") f = ""; next }
    /^@@ / && f != "" { h = $3; sub(/^\+/, "", h); n = split(h, a, ","); st = a[1]; c = (n > 1) ? a[2] : 1; for (i = 0; i < c; i++) print f "\t" st + i }'
}

# One mutant: file, line, lang, new line, description with \037 between, or nothing
mut_make() { # file line lang
  local src; src="$(sed -n "${2}p" "$PROJECT/$1")"
  [ -n "$src" ] || return 0
  printf '%s\n' "$src" | tr -d '\r' | awk -v LANG="$3" "$MUT_AWK" | head -1 | { IFS= read -r x && printf '%s\037%s\037%s\037%s\n' "$1" "$2" "$3" "$x"; }
}

MUT_FILE=""; MUT_BAK=""; MUT_PID=""
# The real file back, byte for byte with its old time stamp, then the judge of that mutant ends. After every mutant and in the trap.
mutate_restore() {
  [ -n "$MUT_FILE" ] && [ -f "$MUT_BAK" ] && cp -p "$MUT_BAK" "$MUT_FILE" && rm -f "$MUT_BAK"
  MUT_FILE=""; MUT_BAK=""
  [ -n "$MUT_PID" ] && kill "$MUT_PID" 2>/dev/null; MUT_PID=""
  return 0
}

# The command that judges a mutant: mutate_cmd from warmd.conf, else warmd check without cache in a process of its own
mut_run() { # timeout secs, nocache 0|1
  local t="$1" nc="$2" rc
  # In the background with wait: Ctrl+C or a kill reaches the trap at once, not after the run
  if [ -n "${MUT_CMD:-}" ]; then ( cd "$PROJECT" && WARMD_NOCACHE="$nc" exec timeout "$t" bash -c "$MUT_CMD" ) > "$MUT_TMP/run.log" 2>&1 &
  else ( cd "$PROJECT" && WARMD_NOCACHE="$nc" WARMD_DETACHED=1 exec timeout "$t" bash "$WARMD_HOME/bin/warmd" check ) > "$MUT_TMP/run.log" 2>&1 & fi
  MUT_PID=$!; wait "$MUT_PID"; rc=$?; MUT_PID=""
  return $rc
}

# Quality metrics next to the cost ledger, in the common git dir (never committed): time, kind, commit, numbers
quality_file() { echo "$(git -C "$PROJECT" rev-parse --path-format=absolute --git-common-dir 2>/dev/null)/warmd-quality.tsv"; }
quality_record() { # kind values...
  local f; f="$(quality_file)"; [ "$f" = /warmd-quality.tsv ] && return 0
  local IFS=$'\t'; printf '%s\t%s\t%s\t%s\n' "$(date +%s)" "$1" "$(git -C "$PROJECT" rev-parse --short HEAD 2>/dev/null || echo -)" "${*:2}" >> "$f"
}
# One line for report and gain: the last nightly mismatch count and the last mutation score
quality_line() {
  local f; f="$(quality_file)"; [ -s "$f" ] || return 0
  awk -F'\t' '$2 == "nightly" { n++; mm += $5; last = $5 } $2 == "mutate" && $5 > 0 { k = $4; t = $5 }
    END { s = ""; if (n) s = sprintf("nightly cache mismatches: %d last run, %d in %d runs (target 0)", last, mm, n)
          if (t) s = s (s == "" ? "" : "; ") sprintf("mutation score %d%% (%d of %d killed)", int(100 * k / t), k, t)
          if (s != "") print s }' "$f"
}

mutate_main() {
  detect_project
  [ -n "$GIT_ROOT" ] || { echo "FAIL warmd mutate needs a git repo"; return 2; }
  local base="" limit="${CFG_mutate_limit:-900}"
  MUT_CMD="${CFG_mutate_cmd:-}"
  while [ $# -gt 0 ]; do
    case "$1" in
      --base) base="${2:-}"; shift;;
      --limit) limit="${2:-}"; shift;;
      --cmd) MUT_CMD="${2:-}"; shift;;
      *) echo "warmd mutate [--base REF] [--limit S] [--cmd C]"; return 2;;
    esac
    shift
  done
  case "$limit" in ''|*[!0-9]*) echo "FAIL --limit wants seconds"; return 2;; esac
  if [ -z "$base" ]; then
    if [ -n "${WARMD_DIFF_BASE:-}" ]; then base="$WARMD_DIFF_BASE"
    else base="$(git -C "$GIT_ROOT" merge-base HEAD "$(base_branch)" 2>/dev/null || echo HEAD)"; fi
  fi
  git -C "$GIT_ROOT" rev-parse -q --verify "$base^{commit}" >/dev/null 2>&1 || { echo "FAIL no commit $base"; return 2; }
  mutate_run "$base" "$limit"
}

# mutate_run <base> <limit secs>: prints the verdict, sets MUT_KILLED MUT_TOTAL MUT_SURVIVED, rc 1 when one survived
mutate_run() {
  local base="$1" limit="$2" f l g new desc t0 left per rc base_s a
  local -a muts=() surv=()
  MUT_KILLED=0; MUT_TOTAL=0; MUT_SURVIVED=0; MUT_SKIPPED=0
  MUT_TMP="$(mktemp -d)"
  while IFS=$'\t' read -r f l; do
    [ -f "$PROJECT/$f" ] || continue
    g="$(mut_lang "$f")" || continue
    while IFS= read -r a; do [ -n "$a" ] && muts+=("$a"); done < <(mut_make "$f" "$l" "$g")
  done < <(mut_lines "$base")
  if [ ${#muts[@]} = 0 ]; then rm -rf "$MUT_TMP"; echo "OK mutate: no changed line to mutate since ${base:0:12}"; return 0; fi
  # The tests have to be green on the real code first, else a red mutant proves nothing
  t0="$(now_ms)"
  mut_run "$limit" 0; rc=$?
  if [ $rc != 0 ]; then
    echo "FAIL mutate: the tests are red before any mutation (exit $rc), nothing to measure"
    tail -n 5 "$MUT_TMP/run.log" | cut -c1-200; rm -rf "$MUT_TMP"; return 1
  fi
  base_s=$(( ($(now_ms) - t0) / 1000 ))
  # A mutant gets three times a real run plus a minute: an endless loop it causes is a kill, not a hang
  per=$(( base_s * 3 + 60 ))
  printf -v t0 '%(%s)T' -1
  trap 'mutate_restore; on_exit' EXIT
  for a in "${muts[@]}"; do
    IFS=$'\037' read -r f l g new desc <<< "$a"
    printf -v left '%(%s)T' -1; left=$(( limit - (left - t0) ))
    if [ $left -lt $(( base_s + 5 )) ]; then MUT_SKIPPED=$(( ${#muts[@]} - MUT_TOTAL )); break; fi
    [ $left -lt $per ] && per=$left
    MUT_FILE="$PROJECT/$f"; MUT_BAK="$MUT_TMP/bak"
    cp -p "$MUT_FILE" "$MUT_BAK" || { MUT_FILE=""; continue; }
    # The new line comes from a file: awk -v would read its backslashes as escapes
    awk -v L="$l" 'NR == FNR { nl = $0; next } FNR == L { cr = (substr($0, length($0)) == "\r") ? "\r" : ""; print nl cr; next } { print }' \
      <(printf '%s\n' "$new") "$MUT_BAK" > "$MUT_TMP/mut"
    cat "$MUT_TMP/mut" > "$MUT_FILE"
    mut_run "$per" 1; rc=$?
    mutate_restore
    MUT_TOTAL=$((MUT_TOTAL + 1))
    if [ $rc = 0 ]; then MUT_SURVIVED=$((MUT_SURVIVED + 1)); surv+=("SURVIVED $f:$l  $desc")
    else MUT_KILLED=$((MUT_KILLED + 1)); fi
  done
  trap on_exit EXIT
  rm -rf "$MUT_TMP"
  quality_record mutate "$MUT_KILLED" "$MUT_TOTAL" "$MUT_SURVIVED"
  [ ${#surv[@]} -gt 0 ] && { printf '%s\n' "${surv[@]:0:20}"; [ ${#surv[@]} -gt 20 ] && echo "(+$(( ${#surv[@]} - 20 )) more)"; }
  local sk=""; [ "$MUT_SKIPPED" -gt 0 ] && sk=", $MUT_SKIPPED not run (time limit ${limit}s)"
  local sc=0; [ $MUT_TOTAL -gt 0 ] && sc=$(( 100 * MUT_KILLED / MUT_TOTAL ))
  if [ $MUT_TOTAL = 0 ]; then echo "WARN mutate: the time limit of ${limit}s ends before the first of $MUT_SKIPPED mutants, nothing measured (mutate_limit=)"; return 0; fi
  if [ $MUT_SURVIVED -gt 0 ]; then
    echo "FAIL mutate: $MUT_SURVIVED of $MUT_TOTAL mutants survived, score ${sc}%$sk: no test notices those lines (add a test, or mark an equivalent line warmd: nomutate)"
    return 1
  fi
  echo "OK mutate: $MUT_KILLED of $MUT_TOTAL mutants killed, score ${sc}%$sk"
}

# For the merge gate: runs only with mutate=merge in warmd.conf, against the commit before the merge (WARMD_DIFF_BASE)
mutate_gate() {
  [ "${CFG_mutate:-}" = merge ] || return 0
  mutate_run "${WARMD_DIFF_BASE:-$(git -C "$GIT_ROOT" merge-base HEAD "$(base_branch)")}" "${CFG_mutate_limit:-900}"
}
