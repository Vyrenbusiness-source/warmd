# Affected tests from a real dependency graph.
#   js  imports and requires (JS, TS, Vue, Svelte)          py  import and from-import
#   cs  type names plus asmdef references (C#, Unity)       gd  preload, load, res:// paths, class_name, autoloads
# Edges point from a file to what it depends on. A change selects every test that reaches it, transitive dependencies included.
# Anything the graph cannot see makes the answer wider, never narrower: dynamic imports, aliases, reflection, a deleted file,
# a changed file nobody references. Then the test file itself (or all tests) is selected.
#
#   affected_select <js|py|cs|gd> [scope dirs]
# sets AFF_MODE: CLEAN (nothing code-like changed), NONE (no test depends on it), SOME (AFF_FILES, AFF_CLASSES), ALL (AFF_REASON)

# ---- awk programs, one per language, written to a temp dir at run time ----
read -r -d '' AFF_AWK_COMMON <<'EOF' || true
function dname(f,  t) { t = f; if (sub(/\/[^\/]*$/, "", t)) return t; return "" }
function bname(f,  t) { t = f; sub(/^.*\//, "", t); return t }
function norm(p,   n, a, i, k, q, out) {
  n = split(p, a, "/"); k = 0
  for (i = 1; i <= n; i++) {
    if (a[i] == "" || a[i] == ".") continue
    if (a[i] == "..") { if (k == 0) return "\001"; k--; continue }
    q[++k] = a[i]
  }
  out = ""
  for (i = 1; i <= k; i++) out = out (i > 1 ? "/" : "") q[i]
  return out
}
function edge(f, t,   k) { if (f == t) return; k = f SUBSEP t; if (!(k in seen)) { seen[k] = 1; print "E\t" f "\t" t } }
function uns(f) { if (!(f in us)) { us[f] = 1; print "U\t" f } }
function loadlist(   f) { while ((getline f < LIST) > 0) { ex[f] = 1; all[++na] = f } close(LIST) }
function jn(a, b) { return a == "" ? b : a "/" b }
EOF

read -r -d '' AFF_AWK_JS <<'EOF' || true
function isjs(f) { return f ~ /\.(ts|tsx|js|jsx|mjs|cjs|mts|cts|vue|svelte)$/ }
function istest(f) {
  if (f ~ /\.(test|spec)\.[A-Za-z]+$/) return 1
  return (f ~ /(^|\/)__tests__\// && f !~ /(fixtures|helpers|utils|mocks|setup)/)
}
function rjs(p,   i, st, ip) {
  if (p == "\001") return ""
  if (p in ex) return p
  for (i = 1; i <= ne; i++) if ((p E[i]) in ex) return p E[i]
  if (p ~ /\.(js|jsx|mjs|cjs)$/) { st = p; sub(/\.[a-z]+$/, "", st); for (i = 1; i <= ne; i++) if ((st E[i]) in ex) return st E[i] }
  ip = (p == "" ? "index" : p "/index")
  for (i = 1; i <= ne; i++) if ((ip E[i]) in ex) return ip E[i]
  return ""
}
function bare(f, m,   pp, pk, r) {
  if (m ~ /^(@\/|~|#|\/)/) { uns(f); return }
  if (!AL) return
  r = rjs(norm(m)); if (r == "") r = rjs(norm("src/" m))
  if (r != "") { edge(f, r); return }
  split(m, pp, "/"); pk = pp[1]
  if (m ~ /^@/) pk = pp[1] "/" pp[2]
  if (pk ~ /^node:/ || (pk in bi) || (pk in pkg)) return
  uns(f)
}
BEGIN {
  ne = split(".ts .tsx .js .jsx .mjs .cjs .mts .cts .vue .svelte .json .css .scss", E, " ")
  split("fs path os util events stream http https http2 url crypto assert child_process buffer zlib readline net tls dns cluster module process vm worker_threads perf_hooks timers string_decoder querystring v8 tty dgram constants repl inspector", b, " ")
  for (i in b) bi[b[i]] = 1
  while ((getline l < PKG) > 0) pkg[l] = 1
  close(PKG)
  loadlist()
  for (x = 1; x <= na; x++) {
    f = all[x]
    if (!isjs(f)) continue
    print "N\t" f
    if (istest(f)) print "T\t" f
    d = dname(f)
    while ((getline s < (ROOT "/" f)) > 0) {
      if (s ~ /(require|import)[ \t]*\([ \t]*[^ \t'")]/ || s ~ /import\.meta\.glob|require\.context/) uns(f)
      t = s
      while (match(t, /["'`]\.\.?(\/[^"'`]*)?["'`]/)) {
        spec = substr(t, RSTART + 1, RLENGTH - 2); pre = substr(t, 1, RSTART - 1); t = substr(t, RSTART + RLENGTH)
        sub(/[?#].*$/, "", spec)
        if (index(spec, "${") > 0) { uns(f); continue }
        r = rjs(norm(d "/" spec))
        if (r != "") edge(f, r)
        else if (pre ~ /(from|import|require|mock|doMock|unmock|requireActual|importActual|requireMock|resolve)[ \t]*\(?[ \t]*$/) uns(f)
      }
      t = s
      while (match(t, /(from|import|require)[ \t]*\(?[ \t]*["'][^"'.][^"']*["']/)) {
        m = substr(t, RSTART, RLENGTH); t = substr(t, RSTART + RLENGTH)
        sub(/^[^"']*["']/, "", m); sub(/["']$/, "", m)
        bare(f, m)
      }
    }
    close(ROOT "/" f)
  }
}
EOF

read -r -d '' AFF_AWK_PY <<'EOF' || true
function ispy(f) { return f ~ /\.py$/ }
function istest(f,  b) { b = bname(f); return (b ~ /^test_.*\.py$/ || b ~ /_test\.py$/) }
function pyres(f, root, dotted,   n, s, k, j, q, pre) {
  if (dotted == "") { q = jn(root, "__init__.py"); if (q in ex) { edge(f, q); return 1 } return 0 }
  n = split(dotted, s, ".")
  for (k = n; k >= 1; k--) {
    q = root
    for (j = 1; j <= k; j++) q = jn(q, s[j])
    if ((q ".py") in ex) edge(f, q ".py")
    else if ((q "/__init__.py") in ex) edge(f, q "/__init__.py")
    else continue
    pre = root
    for (j = 1; j < k; j++) { pre = jn(pre, s[j]); if (jn(pre, "__init__.py") in ex) edge(f, jn(pre, "__init__.py")) }
    return 1
  }
  return 0
}
function roots(f,   d) {
  nr = 0; R[++nr] = ""; R[++nr] = "src"
  d = dname(f)
  while (d != "") { R[++nr] = d; R[++nr] = d "/src"; d = dname(d) }
}
function finish(f, mod, rest,   n, a, i, nm, dots, rem, root, found, r) {
  gsub(/[()\\]/, " ", rest)
  n = split(rest, a, ",")
  if (mod ~ /^\./) {
    dots = mod; sub(/[^.].*$/, "", dots); rem = substr(mod, length(dots) + 1)
    root = dname(f)
    for (i = 2; i <= length(dots); i++) root = dname(root)
    found = pyres(f, root, rem)
    for (i = 1; i <= n; i++) {
      nm = a[i]; sub(/[ \t]+as[ \t].*$/, "", nm); gsub(/[ \t]/, "", nm)
      if (nm == "" || nm == "*") continue
      if (pyres(f, root, rem == "" ? nm : rem "." nm)) found = 1
    }
    if (!found) uns(f)
    return
  }
  roots(f)
  for (r = 1; r <= nr; r++) {
    pyres(f, R[r], mod)
    for (i = 1; i <= n; i++) {
      nm = a[i]; sub(/[ \t]+as[ \t].*$/, "", nm); gsub(/[ \t]/, "", nm)
      if (nm == "" || nm == "*") continue
      pyres(f, R[r], mod "." nm)
    }
  }
}
function absmod(f, m,   r) { roots(f); for (r = 1; r <= nr; r++) pyres(f, R[r], m) }
BEGIN {
  loadlist()
  for (x = 1; x <= na; x++) {
    f = all[x]
    if (!ispy(f)) continue
    print "N\t" f
    if (istest(f)) print "T\t" f
    col = 0
    while ((getline s < (ROOT "/" f)) > 0) {
      sub(/[ \t]*#.*$/, "", s)
      if (s ~ /importlib|__import__|import_module|pkgutil|runpy|pytest_plugins/) uns(f)
      if (col) {
        buf = buf " " s
        if (s ~ /\)/) { finish(f, cmod, buf); col = 0 }
        continue
      }
      if (s ~ /^[ \t]*from[ \t]+[.A-Za-z_][A-Za-z0-9_.]*[ \t]+import[ \t]/) {
        sub(/^[ \t]*from[ \t]+/, "", s)
        cmod = s; sub(/[ \t].*$/, "", cmod)
        buf = s; sub(/^[^ \t]+[ \t]+import[ \t]+/, "", buf)
        if (buf ~ /\(/ && buf !~ /\)/) { col = 1; continue }
        finish(f, cmod, buf)
      } else if (s ~ /^[ \t]*import[ \t]+[A-Za-z_]/) {
        sub(/^[ \t]*import[ \t]+/, "", s)
        n = split(s, parts, ",")
        for (i = 1; i <= n; i++) { p = parts[i]; sub(/[ \t]+as[ \t].*$/, "", p); gsub(/[ \t;]/, "", p); if (p != "") absmod(f, p) }
      }
    }
    close(ROOT "/" f)
  }
}
EOF

read -r -d '' AFF_AWK_CS <<'EOF' || true
function iscs(f) { return f ~ /\.cs$/ }
function addsym(name, f) {
  if (name == "" || name == "class" || name == "struct" || name == "record" || name == "interface" || name == "enum") return
  if (!((name SUBSEP f) in sd)) { sd[name SUBSEP f] = 1; nd[name]++; D[name, nd[name]] = f }
}
function asmof(f,   d, best, bl) {
  if (f in amemo) return amemo[f]
  best = ""; bl = -1
  for (d in adir) if (adir[d] == 1) {
    if ((d == "" || index(f, d "/") == 1) && length(d) > bl) { best = amap[d]; bl = length(d) }
  }
  amemo[f] = best
  return best
}
function reach(a,   n, r, i, cur, stack, sp, seenA, ok) {
  if (a in rmemo) return rmemo[a]
  sp = 1; stack[1] = a; seenA = "," a ","
  while (sp > 0) {
    cur = stack[sp--]
    n = split(arefs[cur], r, ",")
    for (i = 1; i <= n; i++) {
      if (r[i] == "") continue
      if (index(seenA, "," r[i] ",") == 0) { seenA = seenA r[i] ","; stack[++sp] = r[i] }
    }
  }
  rmemo[a] = seenA
  return seenA
}
function allowed(a, b,   ra) {
  if (!GATE || a == b || a == "") return 1
  if (b == "") return 0
  ra = reach(a)
  return (index(ra, ",*,") > 0 || index(ra, "," b ",") > 0)
}
BEGIN {
  loadlist()
  while ((getline l < ASM) > 0) {
    n = split(l, a, "\t"); adir[a[1]] = 1; amap[a[1]] = a[2]; arefs[a[2]] = "," a[3] ","
  }
  close(ASM)
  for (x = 1; x <= na; x++) {
    f = all[x]
    if (!iscs(f)) continue
    print "N\t" f
    ext = 0; cand = ""; tst = 0; cls = ""
    while ((getline s < (ROOT "/" f)) > 0) {
      c = s; sub(/\/\/.*$/, "", c)
      if (c ~ /^[ \t]*\*/ || c ~ /^[ \t]*\/\*/) continue
      t = c
      while (match(t, /(^|[^A-Za-z0-9_])(class|struct|interface|enum|record)[ \t]+[A-Za-z_][A-Za-z0-9_]*/)) {
        m = substr(t, RSTART, RLENGTH); t = substr(t, RSTART + RLENGTH)
        kw = m; sub(/^[^A-Za-z]*/, "", kw); sub(/[ \t].*$/, "", kw)
        nm = m; sub(/^.*[ \t]/, "", nm)
        addsym(nm, f)
        if (kw == "class" || kw == "struct") cls = cls (cls == "" ? "" : " ") nm
      }
      if (c ~ /delegate[ \t][^;(]*\(/) {
        m = c; sub(/^.*delegate[ \t]/, "", m); sub(/\(.*$/, "", m); sub(/<.*$/, "", m); sub(/[ \t]+$/, "", m); sub(/^.*[ \t]/, "", m)
        addsym(m, f)
      }
      if (c ~ /[(,][ \t]*this[ \t]+[A-Za-z_]/ || c ~ /^[ \t]*this[ \t]+[A-Za-z_]/) ext = 1
      t = c
      while (match(t, /[A-Za-z_][A-Za-z0-9_]*[ \t]*(<[^>(]*>)?[ \t]*\(/)) {
        m = substr(t, RSTART, RLENGTH); t = substr(t, RSTART + RLENGTH)
        sub(/[ \t<(].*$/, "", m); cand = cand " " m
      }
      if (s ~ /\[(Test|TestCase|TestCaseSource|UnityTest|Fact|Theory|TestMethod|DataTestMethod|TestFixture)[\](]/) tst = 1
      if (s ~ /GetTypes[ \t]*\(|GetExportedTypes|TypeCache|Assembly\.Load|AppDomain/) uns(f)
    }
    close(ROOT "/" f)
    if (ext) { n = split(cand, a, " "); for (i = 1; i <= n; i++) addsym(a[i], f) }
    if (tst) { print "T\t" f; n = split(cls, a, " "); for (i = 1; i <= n; i++) print "C\t" f "\t" a[i] }
  }
  for (x = 1; x <= na; x++) {
    f = all[x]
    if (!iscs(f)) continue
    af = asmof(f)
    while ((getline s < (ROOT "/" f)) > 0) {
      n = split(s, tok, /[^A-Za-z0-9_]+/)
      for (i = 1; i <= n; i++) {
        w = tok[i]
        if (w in nd) {
          if (((f SUBSEP w) in tseen)) continue
          tseen[f SUBSEP w] = 1
          for (j = 1; j <= nd[w]; j++) if (allowed(af, asmof(D[w, j]))) edge(f, D[w, j])
        }
      }
    }
    close(ROOT "/" f)
  }
}
EOF

read -r -d '' AFF_AWK_GD <<'EOF' || true
function isgd(f) { return f ~ /\.(gd|tscn|tres)$/ }
function istest(f,  b) { b = bname(f); return ((b ~ /^test_.*\.gd$/ || (b ~ /^run_.*\.gd$/ && f ~ /(^|\/)tests?\//)) && f !~ /(^|\/)addons\//) }
function rres(p,   q) { q = norm(p); if (q == "\001") return ""; return (q in ex) ? q : "" }
BEGIN {
  loadlist()
  # global names: class_name and autoloads
  for (x = 1; x <= na; x++) {
    f = all[x]
    if (f ~ /\.gd$/) {
      while ((getline s < (ROOT "/" f)) > 0) if (match(s, /^[ \t]*class_name[ \t]+[A-Za-z_][A-Za-z0-9_]*/)) { m = substr(s, RSTART, RLENGTH); sub(/^.*[ \t]/, "", m); sym[m] = sym[m] SUBSEP f }
      close(ROOT "/" f)
    }
  }
  if ("project.godot" in ex) {
    while ((getline s < (ROOT "/project.godot")) > 0) if (s ~ /^[A-Za-z_][A-Za-z0-9_]*="\*?res:\/\//) {
      nm = s; sub(/=.*$/, "", nm); p = s; sub(/^[^=]*="\*?res:\/\//, "", p); sub(/".*$/, "", p)
      if (p in ex) sym[nm] = sym[nm] SUBSEP p
    }
    close(ROOT "/project.godot")
  }
  for (x = 1; x <= na; x++) {
    f = all[x]
    if (!isgd(f)) continue
    print "N\t" f
    if (istest(f)) print "T\t" f
    d = dname(f)
    while ((getline s < (ROOT "/" f)) > 0) {
      if (f ~ /\.gd$/) {
        if (s ~ /(load|preload)[ \t]*\([ \t]*[^ \t"')]/ || s ~ /DirAccess|uid:\/\//) uns(f)
        t = s
        while (match(t, /(load|preload)[ \t]*\([ \t]*["'][^"']+["']/)) {
          m = substr(t, RSTART, RLENGTH); t = substr(t, RSTART + RLENGTH)
          sub(/^[^"']*["']/, "", m); sub(/["']$/, "", m)
          if (m !~ /^(res|uid|user):\/\//) { r = rres(d "/" m); if (r != "") edge(f, r); else uns(f) }
        }
      }
      t = s
      while (match(t, /res:\/\/[^"' \t)\]},]+/)) {
        m = substr(t, RSTART + 6, RLENGTH - 6); t = substr(t, RSTART + RLENGTH)
        r = rres(m)
        if (r != "") edge(f, r)
        else if (m !~ /\*/ && f ~ /\.gd$/) uns(f)
      }
      n = split(s, tok, /[^A-Za-z0-9_]+/)
      for (i = 1; i <= n; i++) if (tok[i] in sym) {
        k = split(sym[tok[i]], dl, SUBSEP)
        for (j = 2; j <= k; j++) edge(f, dl[j])
      }
    }
    close(ROOT "/" f)
  }
}
EOF

read -r -d '' AFF_AWK_CLOSE <<'EOF' || true
function risky(f,  b) { b = tolower(f); return (b ~ /(setup|config|conftest|global|mock|fixture|polyfill|jest|vitest|karma|babel|webpack|vite|rollup|eslint)/) }
BEGIN {
  while ((getline l < EDGES) > 0) {
    n = split(l, a, "\t"); t = a[1]
    if (t == "N") node[a[2]] = 1
    else if (t == "T") { test[a[2]] = 1; node[a[2]] = 1; ntest++ }
    else if (t == "U") uns[a[2]] = 1
    else if (t == "C") cls[a[2]] = cls[a[2]] " " a[3]
    else if (t == "E") { dst[a[3]] = 1; rc[a[3]]++; rev[a[3], rc[a[3]]] = a[2] }
  }
  while ((getline f < CHG) > 0) {
    if (f == "") continue
    nchg++
    if (!(f in node) && !(f in dst)) { print "ALL\t" f " is not part of the graph"; exit }
    if ((f in node) && !(f in dst) && !(f in test) && risky(f)) { print "ALL\t" f " looks like shared configuration"; exit }
    if (!(f in vis)) { vis[f] = 1; q[++qn] = f }
  }
  if (nchg == 0) { print "CLEAN"; exit }
  if (ntest == 0) { print "ALL\tno test files recognized"; exit }
  for (u in uns) if (!(u in vis)) { vis[u] = 1; q[++qn] = u }
  for (h = 1; h <= qn; h++) {
    x = q[h]
    for (i = 1; i <= rc[x]; i++) { y = rev[x, i]; if (!(y in vis)) { vis[y] = 1; q[++qn] = y } }
  }
  for (x in vis) if (x in test) { c++; out[c] = x }
  if (c == 0) { print "NONE"; exit }
  print "SOME"
  for (i = 1; i <= c; i++) { print "F\t" out[i]; m = split(cls[out[i]], cl, " "); for (j = 1; j <= m; j++) print "K\t" cl[j] }
}
EOF

AFF_PRUNE='node_modules .git .warmd .godot Library Temp Logs obj __pycache__ .venv venv .tox .mypy_cache .pytest_cache .next .nuxt coverage'
AFF_DOCS='(\.(md|rst)$|(^|/)(LICENSE|COPYING|NOTICE)[^/]*$|(^|/)\.(gitignore|gitattributes|editorconfig)$|^\.warmd/)'

# Changed files relative to the project, renames shown as delete plus add so the old path is seen.
aff_changed() {
  [ -n "$GIT_ROOT" ] || return 0
  local base mb prefix f
  base="$(base_branch)"
  # warmd merge of several branches commits each one: its gate compares with the commit before the first (WARMD_DIFF_BASE)
  if [ -n "${WARMD_DIFF_BASE:-}" ]; then mb="$WARMD_DIFF_BASE"; else mb="$(git -C "$GIT_ROOT" merge-base HEAD "$base" 2>/dev/null || git -C "$GIT_ROOT" rev-parse HEAD 2>/dev/null)"; fi
  prefix="$(git -C "$PROJECT" rev-parse --show-prefix)"   # from git: string math breaks on symlinked and short temp paths
  { [ -n "$mb" ] && git -C "$GIT_ROOT" diff --name-only --no-renames "$mb" 2>/dev/null; git -C "$GIT_ROOT" ls-files -o --exclude-standard; } | tr -d '\r' | sort -u | while IFS= read -r f; do
    [ -n "$f" ] || continue
    if [ -n "$prefix" ]; then case "$f" in "$prefix"*) f="${f#"$prefix"}";; *) continue;; esac; fi
    echo "$f"
  done
}

aff_list() { # scope dirs
  local d dirs="" args=() n
  for d in "$@"; do [ -d "$PROJECT/$d" ] && dirs="$dirs $d"; done
  [ $# -gt 0 ] && [ -z "$dirs" ] && return 0
  for n in $AFF_PRUNE; do args+=(-name "$n" -o); done
  unset 'args[${#args[@]}-1]'
  # shellcheck disable=SC2086
  ( cd "$PROJECT" && find ${dirs:-.} \( "${args[@]}" \) -prune -o -type f -print ) | sed 's#^\./##' | tr -d '\r'
}

affected_select() {
  local lang="$1"; shift
  local tmp edges prog test_re ignore_re del gate=0 f rc line
  AFF_MODE=""; AFF_FILES=""; AFF_REASON=""; AFF_CLASSES=""
  tmp="$(mktemp -d)"; edges="$tmp/edges"
  aff_changed > "$tmp/changed.all"
  aff_list "$@" > "$tmp/list"
  case "$lang" in
    js) prog="$AFF_AWK_JS"; test_re='\.(test|spec)\.[A-Za-z]+$'; ignore_re='^$';;
    py) prog="$AFF_AWK_PY"; test_re='(^|/)(test_[^/]*|[^/]*_test)\.py$'; ignore_re='(^|/)__pycache__/|\.pyc$';;
    cs) prog="$AFF_AWK_CS"; test_re='^$'; ignore_re='\.cs\.meta$|(^|/)(obj|bin)/';;
    gd) prog="$AFF_AWK_GD"; test_re='(^|/)test_[^/]*\.gd$|(^|/)tests?/run_[^/]*\.gd$'; ignore_re='\.gd\.uid$|\.import$';;
    *) rm -rf "$tmp"; AFF_MODE=ALL; AFF_REASON="unknown language $lang"; return 0;;
  esac
  # Jest snapshots belong to their test file
  : > "$tmp/changed"
  while IFS= read -r f; do
    echo "$f" | grep -qE "$AFF_DOCS" && continue
    echo "$f" | grep -qE "$ignore_re" && continue
    case "$f" in */__snapshots__/*.snap) f="${f%/__snapshots__/*}/${f##*/__snapshots__/}"; f="${f%.snap}";; esac
    if [ ! -e "$PROJECT/$f" ]; then
      if echo "$f" | grep -qE "$test_re"; then continue; fi
      rm -rf "$tmp"; AFF_MODE=ALL; AFF_REASON="$f was deleted or renamed"; return 0
    fi
    echo "$f" >> "$tmp/changed"
  done < "$tmp/changed.all"
  if [ ! -s "$tmp/changed" ]; then rm -rf "$tmp"; AFF_MODE=CLEAN; return 0; fi

  : > "$tmp/pkg"
  case "$lang" in
    js)
      local al=0
      if grep -lE '"(paths|baseUrl|imports|workspaces)"|moduleNameMapper|modulePaths|moduleDirectories|alias' "$PROJECT"/tsconfig*.json "$PROJECT"/jsconfig.json "$PROJECT"/package.json "$PROJECT"/vite.config.* "$PROJECT"/vitest.config.* "$PROJECT"/jest.config.* "$PROJECT"/webpack.config.* >/dev/null 2>&1; then al=1; fi
      [ -f "$PROJECT/pnpm-workspace.yaml" ] && al=1
      if [ -d "$PROJECT/node_modules" ]; then
        ( cd "$PROJECT/node_modules" && find . -mindepth 1 -maxdepth 2 ! -type l -type d 2>/dev/null | sed 's#^\./##' | grep -vE '^(\.bin|\.cache|\.pnpm|\.vite)' | awk -F/ '$1 ~ /^@/ { if (NF == 2) print $0; next } NF == 1 { print $0 }' ) > "$tmp/pkg"
      fi
      awk -v ROOT="$PROJECT" -v LIST="$tmp/list" -v PKG="$tmp/pkg" -v AL="$al" "$AFF_AWK_COMMON
$prog" < /dev/null > "$edges";;
    cs)
      aff_asm "$tmp"
      gate="$AFF_GATE"
      awk -v ROOT="$PROJECT" -v LIST="$tmp/list" -v ASM="$tmp/asm" -v GATE="$gate" "$AFF_AWK_COMMON
$prog" < /dev/null > "$edges";;
    *)
      awk -v ROOT="$PROJECT" -v LIST="$tmp/list" "$AFF_AWK_COMMON
$prog" < /dev/null > "$edges";;
  esac
  rc=$?
  if [ $rc -ne 0 ]; then rm -rf "$tmp"; AFF_MODE=ALL; AFF_REASON="graph could not be built"; return 0; fi
  line="$(awk -v EDGES="$edges" -v CHG="$tmp/changed" "$AFF_AWK_CLOSE" < /dev/null)"
  AFF_MODE="$(printf '%s\n' "$line" | head -1 | cut -f1)"
  case "$AFF_MODE" in
    ALL) AFF_REASON="$(printf '%s\n' "$line" | head -1 | cut -f2)";;
    SOME)
      AFF_FILES="$(printf '%s\n' "$line" | grep '^F	' | cut -f2 | sort -u | paste -sd' ' -)"
      AFF_CLASSES="$(printf '%s\n' "$line" | grep '^K	' | cut -f2 | sort -u | paste -sd' ' -)";;
    CLEAN|NONE) ;;
    *) AFF_MODE=ALL; AFF_REASON="graph gave no answer";;
  esac
  rm -rf "$tmp"
  return 0
}

# Assembly definitions for C#. Gating by asmdef only when every reference resolves; otherwise plain type matching.
aff_asm() {
  local tmp="$1" f dir name refs g mf
  AFF_GATE=0
  : > "$tmp/asm"
  grep -E '\.asmdef$' "$tmp/list" > "$tmp/asmdefs"
  [ -s "$tmp/asmdefs" ] || return 0
  grep -qE '\.asmref$' "$tmp/list" && return 0
  : > "$tmp/guids"
  while IFS= read -r f; do
    mf="$PROJECT/$f.meta"; [ -f "$mf" ] || continue
    g="$(grep -m1 '^guid:' "$mf" | tr -d ' \r' | cut -d: -f2)"
    name="$(tr -d '\r\n' < "$PROJECT/$f" | sed -n 's/.*"name"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p')"
    [ -n "$g" ] && [ -n "$name" ] && printf '%s\t%s\n' "$g" "$name" >> "$tmp/guids"
  done < "$tmp/asmdefs"
  while IFS= read -r f; do
    dir="${f%/*}"; [ "$dir" = "$f" ] && dir=""
    name="$(tr -d '\r\n' < "$PROJECT/$f" | sed -n 's/.*"name"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p')"
    [ -n "$name" ] || return 0
    refs="$(tr -d '\r\n' < "$PROJECT/$f" | sed -n 's/.*"references"[[:space:]]*:[[:space:]]*\[\([^]]*\)\].*/\1/p' | tr ',' '\n' | sed 's/^[[:space:]]*"//; s/"[[:space:]]*$//' \
      | awk -v G="$tmp/guids" 'BEGIN { while ((getline l < G) > 0) { split(l, p, "\t"); m[p[1]] = p[2] } } $0 == "" { next } /^GUID:/ { g = substr($0, 6); print (g in m) ? m[g] : "*"; next } { print }' | paste -sd, -)"
    printf '%s\t%s\t%s\n' "$dir" "$name" "$refs" >> "$tmp/asm"
  done < "$tmp/asmdefs"
  AFF_GATE=1
}
