# Repo map: the files other files depend on most, each with the symbols its importers really use, trimmed to a token budget.
# The edges come from the import graph of lib/affected.sh, so the ranking is what the code says, not a guess from file names.
#   repo_map [--budget N]    default 1500 tokens (4 characters per token)

read -r -d '' MAP_AWK <<'EOF' || true
function ext(f) { if (f ~ /\.(ts|tsx|js|jsx|mjs|cjs|mts|cts|vue|svelte)$/) return "js"; if (f ~ /\.py$/) return "py"; if (f ~ /\.cs$/) return "cs"; if (f ~ /\.gd$/) return "gd"; return "" }
function istest(f) { return (f in tst) || f ~ /\.(test|spec)\.[A-Za-z]+$|(^|\/)(test_[^\/]*|[^\/]*_test)\.(py|gd)$|(^|\/)(tests?|__tests__|Tests?)\/|Tests?\.cs$|(^|\/)conftest\.py$/ }
# name of the symbol a definition line declares, "" when the line declares none
function defname(l, x,   t) {
  t = l
  if (x == "py") {
    if (t !~ /^( {4}|\t)?(async +)?(def|class) +[A-Za-z_]/) return ""
    sub(/^[ \t]*(async +)?(def|class) +/, "", t)
  } else if (x == "js") {
    if (t !~ /^(export +)?(default +)?(async +)?(function\*?|class|const|let|var|interface|type|enum) +[A-Za-z_$]/) return ""
    sub(/^(export +)?(default +)?(async +)?(function\*?|class|const|let|var|interface|type|enum) +/, "", t)
  } else if (x == "gd") {
    if (t !~ /^(class_name|static func|func|signal|const|enum) +[A-Za-z_]/) return ""
    sub(/^(class_name|static func|func|signal|const|enum) +/, "", t)
  } else if (x == "cs") {
    if (match(t, /(class|struct|enum|interface|record) +[A-Za-z_][A-Za-z0-9_]*/) && t ~ /^ {0,8}(\[[^]]*\] *)?((public|private|protected|internal|static|sealed|partial|abstract|readonly) +)*(class|struct|enum|interface|record) /) {
      t = substr(t, RSTART, RLENGTH); sub(/^[a-z]+ +/, "", t)
    } else if (t ~ /^ {4,8}(\[[^]]*\] *)?((public|protected|internal|static|override|sealed|abstract|async|virtual|unsafe) +)+[A-Za-z_][][A-Za-z_0-9<>,.]* +[A-Za-z_][A-Za-z_0-9]*(<[^>]*>)? *\(/ && t !~ /^ *(return|new|await|throw|else|if|for|foreach|while|switch|using|var) /) {
      sub(/(<[^>]*>)? *\(.*$/, "", t); sub(/^.* /, "", t)
    } else return ""
  } else return ""
  match(t, /^[A-Za-z_$][A-Za-z0-9_$]*/)
  return substr(t, 1, RLENGTH)
}
BEGIN {
  while ((getline l < EDGES) > 0) {
    split(l, p, "\t")
    if (p[1] == "T") tst[p[2]] = 1
    if (p[1] != "E" || p[2] == p[3]) continue
    k = p[2] SUBSEP p[3]; if (k in eg) continue
    eg[k] = 1; imp[p[3]] = imp[p[3]] SUBSEP p[2]
    if (istest(p[2])) nt[p[3]]++; else np[p[3]]++
  }
  close(EDGES)
  while ((getline f < LIST) > 0) {
    x = ext(f); if (x == "" || istest(f)) continue
    src[++ns] = f; n = 0
    while ((getline l < (ROOT "/" f)) > 0) {
      n++; sub(/\r$/, "", l)
      s = defname(l, x); if (s == "" || length(s) < 2 || s ~ /^__/) continue
      if ((f SUBSEP s) in has) continue
      has[f SUBSEP s] = 1; want[s] = 1
      nd[f]++; dn[f, nd[f]] = s; dl[f, nd[f]] = n; dt[f, nd[f]] = l
    }
    close(ROOT "/" f)
    size[f] = 0
  }
  close(LIST)
  # words each importer uses, kept only for names something defines
  for (k in eg) { split(k, p, SUBSEP); if (p[1] in rd) continue; rd[p[1]] = 1
    while ((getline l < (ROOT "/" p[1])) > 0) { t = l
      while (match(t, /[A-Za-z_$][A-Za-z0-9_$]*/)) { w = substr(t, RSTART, RLENGTH); t = substr(t, RSTART + RLENGTH); if (w in want) uses[p[1], w] = 1 }
    }
    close(ROOT "/" p[1])
  }
  for (i = 1; i <= ns; i++) {
    f = src[i]; if (!nd[f]) continue; tot = 0; m = split(imp[f], im, SUBSEP)
    for (j = 1; j <= nd[f]; j++) { c = 0; for (q = 2; q <= m; q++) if ((im[q], dn[f, j]) in uses) c++; rc[f, j] = c; tot += c }
    # rank: production importers, then test importers, then how many uses
    printf "R\t%09d\t%09d\t%09d\t%s\n", 999999999 - np[f], 999999999 - nt[f], 999999999 - tot, f
  }
  for (i = 1; i <= ns; i++) {
    f = src[i]
    printf "H\t%s\t%d\t%d\n", f, np[f], nt[f]
    for (j = 1; j <= nd[f]; j++) {
      d = dt[f, j]; sub(/^[ \t]+/, "", d); if (length(d) > 96) d = substr(d, 1, 96)
      printf "S\t%s\t%09d\t%09d\t%d\t%s\n", f, 999999999 - rc[f, j], dl[f, j], rc[f, j], d
    }
  }
}
EOF

# Edges of one language into $2/edges, the same graph affected_select builds.
map_edges() {
  local lang="$1" tmp="$2" prog al=0
  case "$lang" in js) prog="$AFF_AWK_JS";; py) prog="$AFF_AWK_PY";; cs) prog="$AFF_AWK_CS";; gd) prog="$AFF_AWK_GD";; *) return 0;; esac
  : > "$tmp/pkg"
  case "$lang" in
    js)
      grep -lE '"(paths|baseUrl|imports|workspaces)"|moduleNameMapper|alias' "$PROJECT"/tsconfig*.json "$PROJECT"/jsconfig.json "$PROJECT"/package.json "$PROJECT"/vite.config.* >/dev/null 2>&1 && al=1
      [ -d "$PROJECT/node_modules" ] && ( cd "$PROJECT/node_modules" && find . -mindepth 1 -maxdepth 2 ! -type l -type d 2>/dev/null | sed 's#^\./##' | awk -F/ '$1 ~ /^@/ { if (NF == 2) print; next } NF == 1' ) > "$tmp/pkg"
      awk -v ROOT="$PROJECT" -v LIST="$tmp/list" -v PKG="$tmp/pkg" -v AL="$al" "$AFF_AWK_COMMON
$prog" < /dev/null >> "$tmp/edges";;
    cs)
      aff_asm "$tmp"
      awk -v ROOT="$PROJECT" -v LIST="$tmp/list" -v ASM="$tmp/asm" -v GATE="$AFF_GATE" "$AFF_AWK_COMMON
$prog" < /dev/null >> "$tmp/edges";;
    *)
      awk -v ROOT="$PROJECT" -v LIST="$tmp/list" "$AFF_AWK_COMMON
$prog" < /dev/null >> "$tmp/edges";;
  esac
}

repo_map() {
  local budget=1500 tmp lang used=0 shown=0 left=0 readc=0 f np nt line cost hdr per=8 k c
  while [ $# -gt 0 ]; do
    case "$1" in
      --budget) budget="${2:-}"; shift; [ $# -gt 0 ] && shift;;
      --budget=*) budget="${1#*=}"; shift;;
      *) echo "warmd map [--budget N]   repo map; warmd map <file> for one outline"; return 2;;
    esac
  done
  case "$budget" in ''|*[!0-9]*) echo "FAIL --budget wants a number of tokens"; return 2;; esac
  . "$WARMD_HOME/lib/affected.sh"
  tmp="$(mktemp -d)"
  aff_list > "$tmp/list"
  : > "$tmp/edges"
  grep -qE '\.(ts|tsx|js|jsx|mjs|cjs|mts|cts|vue|svelte)$' "$tmp/list" && map_edges js "$tmp"
  for lang in py cs gd; do grep -qE "\.$lang\$" "$tmp/list" && map_edges "$lang" "$tmp"; done
  awk -v ROOT="$PROJECT" -v LIST="$tmp/list" -v EDGES="$tmp/edges" "$MAP_AWK" < /dev/null > "$tmp/out"
  grep '^R' "$tmp/out" | sort | cut -f5 > "$tmp/rank"
  grep '^S' "$tmp/out" | sort -t"$(printf '\t')" -k2,2 -k3,3 -k4,4 > "$tmp/syms"
  if [ ! -s "$tmp/rank" ]; then rm -rf "$tmp"; echo "warmd map: no JS, TS, Python, C# or GDScript source found"; return 1; fi
  budget=$((budget * 4))
  hdr="repo map: files ranked by how many files import them, then the symbols those importers use [uses]"
  echo "$hdr"; used=${#hdr}
  while IFS= read -r f; do
    line="$(awk -F"	" -v f="$f" '$1 == "H" && $2 == f { print; exit }' "$tmp/out")"
    np="$(printf '%s' "$line" | cut -f3)"; nt="$(printf '%s' "$line" | cut -f4)"
    {
      if [ "${nt:-0}" -gt 0 ]; then echo "== $f  used by $np (+$nt in tests)"; else echo "== $f  used by $np"; fi
      awk -F'\t' -v f="$f" -v per="$per" '$2 == f { n++; if (n <= per) printf "  %d %s%s\n", $4, $6, ($5 > 0 ? "  [" $5 "]" : ""); } END { if (n > per) printf "  +%d more\n", n - per }' "$tmp/syms"
    } > "$tmp/block"
    cost="$(wc -c < "$tmp/block" | tr -d ' ')"
    if [ $((used + cost)) -gt "$budget" ]; then left=$((left + 1)); continue; fi
    cat "$tmp/block"; used=$((used + cost)); shown=$((shown + 1))
    c="$(wc -c < "$PROJECT/$f" | tr -d ' ')"; readc=$((readc + c))
  done < "$tmp/rank"
  [ "$left" -gt 0 ] && echo "... $left more files, raise --budget"
  echo "map ~$((used / 4)) tokens of $((budget / 4)); reading the $shown files listed ~$((readc / 4)) tokens. One file: warmd map <file>"
  rm -rf "$tmp"
}
