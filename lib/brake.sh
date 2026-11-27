# Brake log: what slowed an agent down, kept machine-wide so the causes can be ranked and fixed in warmd.
# One row per brake: epoch, project, task, cause, minutes, fix idea. Lives in the warmd cache dir, never committed.
# warmd note "BRAKE: <what> | ~<min> | <fix>" lands here too, the batch brief keeps only its newest 40 lines.
reg brake  "warmd brake \"<what>\" [minutes] [fix idea]  record what slowed you down, machine-wide" brake_main
reg brakes "warmd brakes [--days N]       causes ranked by minutes lost, top 10" brakes_main

brake_file() { echo "${CACHE_ROOT:-${XDG_CACHE_HOME:-$HOME/.cache}/warmd}/brakes.tsv"; }
brake_clean() { local s="${1//$'\t'/ }"; s="${s//$'\r'/}"; s="${s//$'\n'/ }"; s="${s#"${s%%[![:space:]]*}"}"; printf '%s' "${s%"${s##*[![:space:]]}"}"; }

brake_where() { # -> REPLY "project<TAB>task"
  local common top br p t
  common="$(git rev-parse --path-format=absolute --git-common-dir 2>/dev/null)"
  if [ -n "$common" ]; then
    top="${common%/}"; [ "${top##*/}" = .git ] && top="${top%/.git}"; p="${top##*/}"
    br="$(git branch --show-current 2>/dev/null)"; t="${br#warmd/}"
  else p="${PWD##*/}"; fi
  REPLY="${p:--}"$'\t'"${t:--}"
}

brake_add() { # what minutes fix
  local what min fix f
  what="$(brake_clean "${1:-}")"; min="$(brake_clean "${2:-}")"; fix="$(brake_clean "${3:-}")"
  [ -n "$what" ] || { echo "warmd brake \"<what>\" [minutes] [fix idea]"; return 2; }
  min="${min#\~}"; min="${min%%[!0-9]*}"; [ -n "$min" ] || min=0   # "~4", "4 min", "~10/round" all count their number
  brake_where
  f="$(brake_file)"; mkdir -p "${f%/*}"
  printf '%s\t%s\t%s\t%s\t%s\n' "$(date +%s)" "$REPLY" "$what" "$min" "${fix:--}" >> "$f"
}

brake_main() {
  brake_add "$@" || return $?
  echo "OK brake recorded, warmd brakes ranks them"
}

# A note "BRAKE: what | ~min | fix" -> brake_add. Returns 1 when the text is no brake.
brake_from_note() { # text
  local t="$1" what min fix
  case "$t" in BRAKE:*|brake:*) ;; *) return 1;; esac
  t="${t#*:}"
  what="${t%%|*}"; t="${t#"$what"}"; t="${t#|}"
  min="${t%%|*}"; t="${t#"$min"}"; t="${t#|}"
  fix="$t"
  brake_add "$what" "$min" "$fix" >/dev/null
}

# Causes grouped by their words (case, digits and punctuation do not split a group), ranked by total minutes, top 10.
brakes_main() {
  local days="" f since=0
  while [ $# -gt 0 ]; do
    case "$1" in
      --days) days="${2:-}"; shift;;
      --days=*) days="${1#--days=}";;
      *) echo "warmd brakes [--days N]"; return 2;;
    esac
    shift
  done
  case "$days" in *[!0-9]*) echo "FAIL --days takes a number"; return 2;; esac
  [ -n "$days" ] && since=$(( $(date +%s) - days * 86400 ))
  f="$(brake_file)"
  [ -s "$f" ] || { echo "no brakes recorded yet, warmd brake \"<what>\" [minutes] [fix] adds one"; return 0; }
  awk -F'\t' -v since="$since" '
    $1 >= since {
      k=tolower($4); gsub(/[^a-z ]/, " ", k); gsub(/ +/, " ", k); sub(/^ /, "", k); sub(/ $/, "", k)
      if (k == "") k = "-"
      m[k] += $5; n[k]++; tot += $5; rows++
      if (!(k in c)) c[k] = $4
      if ($6 != "-") fx[k] = $6
      if (index(" " who[k] " ", " " $3 " ") == 0) who[k] = (who[k] == "" ? $3 : who[k] " " $3)
    }
    END {
      if (!rows) { print "no brakes in that window"; exit }
      printf "%d min lost in %d brakes\n", tot, rows
      for (i = 1; i <= 10; i++) {
        best = ""; for (k in m) if (best == "" || m[k] > m[best]) best = k
        if (best == "") break
        printf "%4d min %2dx  %s (%s)%s\n", m[best], n[best], c[best], who[best], (best in fx ? "  fix: " fx[best] : "")
        delete m[best]
      }
    }' "$f"
}

# One line for report and finish: brake minutes of the running batch (rows since its marker), else of the last day.
# With a task name, that task's own minutes come first.
brake_batch_line() { # [task]
  local f common since label="last 24h"; f="$(brake_file)"; [ -s "$f" ] || return 0
  common="$(git rev-parse --path-format=absolute --git-common-dir 2>/dev/null)"
  since="$(stat -c %Y "$common/warmd-batch" 2>/dev/null || stat -f %m "$common/warmd-batch" 2>/dev/null)"
  if [ -n "$since" ]; then label="this batch"; else since=$(( $(date +%s) - 86400 )); fi
  brake_where
  awk -F'\t' -v since="$since" -v p="${REPLY%%$'\t'*}" -v task="${1:-}" -v label="$label" '
    $1 >= since && $2 == p { m += $5; n++; if ($3 == task) { tm += $5; tn++ } }
    END { if (!n) exit
      printf "brakes: %s%d min in %d entries %s (warmd brakes ranks them)\n", (task != "" ? sprintf("%s %d min, ", task, tm) : ""), m, n, label }' "$f"
}
