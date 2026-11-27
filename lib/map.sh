# Repo map: the files other files depend on most, each with the symbols its importers really use, trimmed to a token budget.
# The edges come from the import graph of lib/affected.sh, so the ranking is what the code says, not a guess from file names.
#   repo_map [--budget N]    default 1500 tokens (4 characters per token); Godot scenes rank with the scripts, by who instances or loads them
#   scene_map <file.tscn>    one scene as an outline: nodes, types, scripts, instanced scenes, signal connections
#   scene_peek <scene> [N]   runs the scene headless for N frames, prints the live node tree (godot/peek.gd)

read -r -d '' MAP_AWK <<'EOF' || true
function ext(f) { if (f ~ /\.(ts|tsx|js|jsx|mjs|cjs|mts|cts|vue|svelte)$/) return "js"; if (f ~ /\.py$/) return "py"; if (f ~ /\.cs$/) return "cs"; if (f ~ /\.gd$/) return "gd"; if (f ~ /\.tscn$/) return "tscn"; return "" }
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
  } else if (x == "tscn") {
    if (t !~ /^\[node /) return ""
    return attr(t, "name")
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
      s = defname(l, x)
      # scene nodes: name and type, never counted as used symbols
      if (x == "tscn") { if (s == "") continue; nd[f]++; dn[f, nd[f]] = ""; dl[f, nd[f]] = n; dt[f, nd[f]] = "node " s (attr(l, "type") != "" ? " " attr(l, "type") : (index(l, " instance=") ? " instance" : "")); continue }
      if (s == "" || length(s) < 2 || s ~ /^__/) continue
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
  for lang in py cs; do grep -qE "\.$lang\$" "$tmp/list" && map_edges "$lang" "$tmp"; done
  grep -qE '\.(gd|tscn)$' "$tmp/list" && map_edges gd "$tmp"
  awk -v ROOT="$PROJECT" -v LIST="$tmp/list" -v EDGES="$tmp/edges" "$SCENE_LIB
$MAP_AWK" < /dev/null > "$tmp/out"
  grep '^R' "$tmp/out" | sort | cut -f5 > "$tmp/rank"
  grep '^S' "$tmp/out" | sort -t"$(printf '\t')" -k2,2 -k3,3 -k4,4 > "$tmp/syms"
  if [ ! -s "$tmp/rank" ]; then rm -rf "$tmp"; echo "warmd map: no JS, TS, Python, C#, GDScript or Godot scene source found"; return 1; fi
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

# Godot scene outline (.tscn as text, format 2 and 3): one line per node with its line number, indented by depth, then the
# signal connections. Attributes are read by name, so their order and unknown extra attributes (uid, index, flags) do not matter.
read -r -d '' SCENE_LIB <<'EOF' || true
# value of k="v" or k=v in a [section] header, "" when absent
function attr(s, k,   r, n) {
  if (match(s, "[[ ]" k "=\"[^\"]*\"")) { n = length(k) + 3; return substr(s, RSTART + n, RLENGTH - n - 1) }
  if (match(s, "[[ ]" k "=[^] \"]+")) { n = length(k) + 2; return substr(s, RSTART + n, RLENGTH - n) }
  return ""
}
# id inside ExtResource("1_ab") or ExtResource( 1 ), "" when t holds none
function extid(t) {
  if (!match(t, /ExtResource\( *"?[^")]*"? *\)/)) return ""
  t = substr(t, RSTART + 12, RLENGTH - 13); gsub(/[" ]/, "", t); return t
}
EOF
read -r -d '' SCENE_AWK <<'EOF' || true
function flush(   d, p, l) {
  if (cur == "") return
  p = npar[cur]; d = (p == "-") ? 0 : (p == "." ? 1 : split(p, _q, "/") + 1)
  l = sprintf("%d %" (2 * d + 1) "s%s", nline[cur], "", nname[cur]); sub(/ /, "", l)
  if (ntype[cur] != "") l = l "  " ntype[cur]
  if (ninst[cur] != "") l = l "  " (p == "-" ? "inherits " : "instance ") ninst[cur]
  else if (ntype[cur] == "") l = l "  (inherited)"
  if (nscr[cur] != "") l = l "  script " nscr[cur]
  if (ngrp[cur] != "") l = l "  groups " ngrp[cur]
  out[++no] = substr(l, 1, 140); cur = ""
}
{ sub(/\r$/, "") }
/^\[gd_scene/ { fmt = attr($0, "format") }
/^\[ext_resource/ { id = attr($0, "id"); er[id] = attr($0, "path"); if (er[id] == "") er[id] = attr($0, "uid"); next }
/^\[/ { flush() }
/^\[node / {
  cur = ++nn; nline[cur] = NR; nname[cur] = attr($0, "name"); ntype[cur] = attr($0, "type")
  npar[cur] = attr($0, "parent"); if (npar[cur] == "") npar[cur] = "-"
  i = extid(substr($0, index($0, " instance=") + 1)); if (index($0, " instance=")) ninst[cur] = (i in er) ? er[i] : "ExtResource " i
  if (match($0, /groups=\[[^]]*\]/)) { g = substr($0, RSTART + 8, RLENGTH - 9); gsub(/[" ]/, "", g); ngrp[cur] = g }
  if (npar[cur] == "-") root = ntype[cur]
  next
}
cur != "" && /^unique_name_in_owner *= *true/ { nname[cur] = "%" nname[cur]; next }
cur != "" && /^script *= */ {
  i = extid($0)
  if (i != "") nscr[cur] = (i in er) ? er[i] : "ExtResource " i
  else if ($0 ~ /SubResource/) nscr[cur] = "(built-in)"
  next
}
/^\[connection / {
  s = attr($0, "signal"); f = attr($0, "from"); t = attr($0, "to"); m = attr($0, "method")
  if (s == "" || m == "") { con[++nc] = NR " ? " substr($0, 1, 120); next }
  l = NR " " s " " (f == "" ? "." : f) " -> " (t == "" ? "." : t) " " m
  fl = attr($0, "flags"); if (fl != "") l = l "  flags " fl
  if (match($0, /binds=\[[^]]*\]/)) l = l "  " substr($0, RSTART, RLENGTH)
  con[++nc] = substr(l, 1, 140)
}
END {
  flush()
  printf "== %s  %s, %d node%s, %d connection%s%s\n", NAME, (root == "" ? "inherited scene" : root), nn, (nn == 1 ? "" : "s"), nc, (nc == 1 ? "" : "s"), (fmt != "" && fmt < 3 ? ", Godot 3 format" : "")
  for (i = 1; i <= no && i <= MAXN; i++) print out[i]
  if (no > MAXN) printf "... %d more nodes, see the line numbers\n", no - MAXN
  if (nc) print "connections: line signal from -> to method"
  for (i = 1; i <= nc && i <= MAXC; i++) print con[i]
  if (nc > MAXC) printf "... %d more connections\n", nc - MAXC
}
EOF

# warmd map <scene.tscn>: the scene as a text outline, cheaper than the raw file and readable without the editor.
scene_map() {
  local f
  for f in "$@"; do
    [ -f "$f" ] || { echo "warmd map: no file $f"; return 1; }
    awk -v NAME="${f##*/}" -v MAXN="${WARMD_MAP_NODES:-80}" -v MAXC="${WARMD_MAP_CONNECTIONS:-30}" "$SCENE_LIB
$SCENE_AWK" "$f"
  done
}

# path_inside <path> <root>: prints <path> relative to <root> when it lies inside, spelling-independent: a plain prefix
# match first (no program start), else both sides canonical once (cygpath -l on Windows, pwd -P elsewhere).
canon_path() { # a file: its folder canonical plus its name (cygpath -l expands only names that exist)
  local d="$1" n=""; [ -d "$d" ] || { n="/${d##*/}"; d="$(dirname "$d")"; }
  case "${OSTYPE:-}" in msys*|cygwin*) d="$(cygpath -ml "$d" 2>/dev/null)";; *) d="$(cd -P "$d" 2>/dev/null && pwd -P)";; esac # -l only with -m/-w
  [ -n "$d" ] && printf '%s\n' "${d%/}$n"
}
path_inside() {
  local p="$1" r="${2%/}"
  case "$p" in "$r"/*) printf '%s\n' "${p#"$r"/}"; return 0;; esac
  p="$(canon_path "$p")"; r="$(canon_path "$r")"; r="${r%/}"
  [ -n "$p" ] && [ -n "$r" ] || return 1
  case "$p" in "$r"/*) printf '%s\n' "${p#"$r"/}"; return 0;; esac
  return 1
}

# warmd peek <scene> [frames]: the scene runs headless at a fixed 60 fps for N frames (default 10), then godot/peek.gd prints
# its live node tree, one line per node: type, position, hidden, current animation, script and its exported vars.
# Text instead of a screenshot. Nothing is saved: the scene is played, never opened in the editor.
scene_peek() {
  local scene="${1:-}" frames="${2:-10}" exe res f rc log rel
  [ "$KIND" = godot ] && [ -n "$(type -t godot_exe)" ] || { echo "FAIL warmd peek is for Godot projects"; return 2; }
  [ -n "$scene" ] || { echo "warmd peek <scene.tscn | res://path | name> [frames]"; return 2; }
  case "$frames" in ''|*[!0-9]*) echo "FAIL frames wants a number, got $frames"; return 2;; esac
  case "$scene" in
    res://*|uid://*) res="$scene";;
    *)
      if [ -f "$scene" ]; then f="$scene"
      elif [ -f "$PROJECT/$scene" ]; then f="$PROJECT/$scene"
      else
        f="$(find "$PROJECT" -type f \( -name "$scene" -o -name "$scene.tscn" -o -name "$scene.scn" \) -not -path '*/.godot/*' -not -path '*/.git/*' -not -path '*/addons/*' 2>/dev/null | sort | head -2)"
        [ -n "$f" ] || { echo "FAIL no scene named $scene"; return 1; }
        [ "$(printf '%s\n' "$f" | wc -l)" -gt 1 ] && { echo "FAIL $scene names more than one scene, give the path:"; printf '%s\n' "$f" | sed "s#^$PROJECT/#  #"; return 1; }
      fi
      f="$(cd "$(dirname "$f")" && pwd)/${f##*/}"
      # spelling-independent: main.tscn resolved against an 8.3 $PWD is still inside a long-spelled PROJECT
      if rel="$(path_inside "$f" "$PROJECT")"; then res="res://$rel"; else echo "FAIL $scene is outside the project $(native_path "$PROJECT")"; return 1; fi;;
  esac
  exe="$(godot_exe)" || { echo "FAIL Godot not found, set WARMD_GODOT"; return 2; }
  slot_take
  if [ -d "$PROJECT/.godot" ]; then refresh_classes; else refresh_classes force; fi
  log="$RUN/peek.log"
  WARMD_SCENE="$res" WARMD_FRAMES="$frames" timeout "${WARMD_PEEK_TIMEOUT:-120}" "$exe" --headless --fixed-fps 60 --path "$(native_path "$PROJECT")" --script "$(native_path "$WARMD_HOME/godot/peek.gd")" > "$log" 2>&1
  rc=$?
  tr -d '\r' < "$log" | sed -n 's/^PEEK //p' | grep -v "^FAIL "
  if [ $rc = 0 ] && grep -q '^PEEK == ' "$log"; then
    grep -qE 'SCRIPT ERROR|^ERROR:' "$log" && echo "(errors while it ran, see $(native_path "$log"))"
    return 0
  fi
  if grep -q '^PEEK FAIL ' "$log"; then tr -d '\r' < "$log" | sed -n 's/^PEEK FAIL /FAIL /p' | head -1
  elif [ $rc = 124 ]; then echo "FAIL peek timeout after ${WARMD_PEEK_TIMEOUT:-120}s"
  else echo "FAIL Godot ended without a node tree (exit $rc), see $(native_path "$log")"; summarize_errors "$log"; fi
  return 1
}
