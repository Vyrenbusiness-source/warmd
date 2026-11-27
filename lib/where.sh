# warmd where: a signpost into the code. One term in, at most five "file:line what" lines out, so an agent reads the
# right lines instead of searching. It only says where to read: every edit still goes to the real code.
#   where_main <term...>        places for a term, then what changed since this checkout last asked
#   where_main --changed [ref]  every change since the last answer, or since a git state
# Symbol index: GDScript (class_name, func, signal, export, groups), .tscn (nodes, attached scripts, groups),
# project.godot (input actions, autoloads, global groups), plus C#, TS/JS and Python definitions.
# Each file's rows are bound to its git blob hash and only a changed file is read again. The index lives in the git dir
# of this checkout (warmd-where/), never in the work tree. Feature map: path words, "# warmd: feature=a,b" comment
# lines (a,b are synonyms), notes in the shared brief that name file:line (kept in the common git dir), and a German
# and English synonym table. A note whose file changed is re-resolved through the symbol it pointed at, or marked stale.

# Synonym groups, ASCII folded (ae oe ue ss). One group per line.
read -r -d '' WHERE_SYN <<'EOF' || true
laufen gehen bewegen bewegung movement move moving walk walking run running rennen sprint locomotion velocity steuerung
springen sprung jump jumping hop
schiessen schuss feuern shoot shooting fire gun weapon waffe waffen projektil projektile projectile projectiles bullet bullets kugel geschoss munition ammo
schaden damage hit treffer health leben lebenspunkte heal heilen
tod sterben die death dead respawn
gegner feind feinde enemy enemies mob monster
spieler player held hero figur
kamera camera cam
menue menu hud oberflaeche button knopf
inventar inventory item items gegenstand
speichern save load spielstand savegame
ton sound audio musik music sfx
karte map level welt world szene scene
eingabe input taste key keyboard tastatur controller gamepad maus mouse
punkte score highscore
zeit timer countdown
animation animieren anim sprite
physik physics collision kollision
netzwerk network multiplayer online
dialog dialogue gespraech
einstellungen settings optionen options config
spawn spawner spawnen erzeugen
angriff attack melee schlag nahkampf
ziel target aim zielen
EOF

read -r -d '' WHERE_AWK <<'EOF' || true
function trim(s) { sub(/^[ \t]+/, "", s); sub(/[ \t]+$/, "", s); return s }
function norm(s) {
  gsub(/\303\204/, "\303\244", s); gsub(/\303\226/, "\303\266", s); gsub(/\303\234/, "\303\274", s)
  s = tolower(s)
  gsub(/\303\244/, "ae", s); gsub(/\303\266/, "oe", s); gsub(/\303\274/, "ue", s); gsub(/\303\237/, "ss", s)
  return s
}
# space separated lower case words, snake_case and camelCase split
function words(s) {
  gsub(/[^A-Za-z0-9\200-\377]+/, " ", s)
  while (match(s, /[a-z0-9][A-Z]/)) s = substr(s, 1, RSTART) " " substr(s, RSTART + 1)
  return norm(trim(s))
}
function pathwords(f) { sub(/\.[A-Za-z]+$/, "", f); return words(f) }
function base(p) { sub(/^.*\//, "", p); return p }
function rel(p) { if (p == "") return ""; if (sub(/^res:\/\//, "", p)) p = PRJ p; return p }
function attr(l, a,   t) {
  if (match(l, "[ [](" a ")=\"[^\"]*\"")) { t = substr(l, RSTART, RLENGTH); sub(/^[^"]*"/, "", t); sub(/"$/, "", t); return t }
  if (match(l, "[ [](" a ")=[^ \\]]+")) { t = substr(l, RSTART, RLENGTH); sub(/^[^=]*=/, "", t); return t }
  return ""
}
function lastid(l,   t) { t = substr(l, RSTART, RLENGTH); sub(/[ \t(]+$/, "", t); sub(/^.*[^A-Za-z0-9_$]/, "", t); return t }
function sig(s) { s = trim(s); if (length(s) > 100) s = substr(s, 1, 100); return s }

# ---- rows: target N (index of now) or O (the state compared against) ----
function addrow(w, f, h, l, k, n, s, x,   r) {
  if (w == "N") {
    r = ++nN; Nf[r] = f; Nl[r] = l; Nk[r] = k; Nn[r] = n; Ns[r] = s; Nx[r] = x
    if (k == "file") { Nh[f] = h; Nfile[++nNF] = f } else Nrows[f] = Nrows[f] " " r
    if (!((f, k, n) in NK)) NK[f, k, n] = r
    if (k != "file" && k != "tag") { NS[k, n] = NS[k, n] " " r }
    if (WRITE) print f "\t" h "\t" l "\t" k "\t" n "\t" s "\t" x > NEWIDX
  } else {
    r = ++nO; Of[r] = f; Ol[r] = l; Ok[r] = k; On[r] = n; Os[r] = s
    if (k == "file") { Oh[f] = h; Ofile[++nOF] = f }
    if (!((f, k, n) in OK)) OK[f, k, n] = r
    if (k != "file" && k != "tag") OSx[k, n] = OSx[k, n] " " r
  }
}
function emit(k, n, l, s, x) { if (n != "") addrow(TGT, F, H, l, k, n, sig(s), x) }
function def(k, n, l, s) {
  if (PT != "") { emit("tag", PT, l, sig(s) "  [feature " PT "]", PT); PT = "" }
  emit(k, n, l, s, "")
}

# ---- scanner, one line at a time ----
function begin(f, h) {
  F = f; H = h; X = f; sub(/^.*\./, "", X); if (f ~ /(^|\/)project\.godot$/) X = "godot"
  if (X == "tsx" || X == "mjs") X = (X == "tsx") ? "ts" : "js"
  PT = ""; PE = 0; PS = 0; PX = 0; SEC = ""; NL = 0; ROOTN = ""; split("", ER)
  emit("file", f, 0, "", "")
}
function flushnode(   s, t) {
  if (!NL) return
  t = (NT != "") ? NT : (NI != "" ? "instance " base(NI) : "")
  s = "node " NPATH (t != "" ? " (" t ")" : "") (NS0 != "" ? " script " rel(NS0) : "")
  emit("node", NPATH, NL, s, rel(NS0) " " rel(NI)); NL = 0
}
function finish() { flushnode(); if (PT != "") emit("tag", PT, PTL, "feature=" PT, PT); PT = "" }
function scan(l, n,   t, s, g, ga, i, m) {
  sub(/\r$/, "", l)
  if (l ~ /^[ \t]*(#|\/\/|;)[ \t]*warmd:[ \t]*feature[ \t]*=/) {
    t = l; sub(/^.*feature[ \t]*=[ \t]*/, "", t); gsub(/[ \t]/, "", t)
    if (t != "") { PT = t; PTL = n }
    return
  }
  if (X == "gd") {
    if (match(l, /^class_name[ \t]+[A-Za-z_][A-Za-z0-9_]*/)) { t = lastid(l); def("class", t, n, "class_name " t) }
    else if (match(l, /^[ \t]*class[ \t]+[A-Za-z_][A-Za-z0-9_]*/)) { t = lastid(l); def("class", t, n, "class " t) }
    else if (match(l, /^[ \t]*(static[ \t]+)?func[ \t]+[A-Za-z_][A-Za-z0-9_]*/)) {
      t = lastid(l); s = l
      if (match(s, /^.*\)([ \t]*->[ \t]*[A-Za-z_][][A-Za-z0-9_.]*)?/)) s = substr(s, RSTART, RLENGTH)
      def("func", t, n, s)
    }
    else if (match(l, /^[ \t]*signal[ \t]+[A-Za-z_][A-Za-z0-9_]*/)) { t = lastid(l); s = l; sub(/[ \t]*#.*$/, "", s); def("signal", t, n, s) }
    else if (l ~ /^[ \t]*(@export|export[ \t(])/ || (PE && l ~ /^[ \t]*(@onready[ \t]+)?var[ \t]/)) {
      if (match(l, /(^|[ \t)])var[ \t]+[A-Za-z_][A-Za-z0-9_]*/)) { t = lastid(l); s = l; sub(/[ \t]*#.*$/, "", s); def("export", t, n, s); PE = 0 }
      else if (l !~ /@export_(group|subgroup|category)/) PE = 1
    }
    else if (l ~ /[^ \t]/ && l !~ /^[ \t]*@/) PE = 0
    if (match(l, /add_to_group\([ \t]*&?["'][A-Za-z0-9_]+/)) { t = substr(l, RSTART, RLENGTH); sub(/^.*["']/, "", t); emit("group", t, n, "add_to_group " t, "") }
  } else if (X == "tscn") {
    if (l ~ /^\[/) flushnode()
    if (l ~ /^\[ext_resource/) ER[attr(l, "id")] = attr(l, "path")
    else if (l ~ /^\[node /) {
      NN = attr(l, "name"); NT = attr(l, "type"); t = attr(l, "parent"); NS0 = ""; NI = ""; NL = n
      if (t == "") { ROOTN = NN; NPATH = NN } else if (t == ".") NPATH = ROOTN "/" NN; else NPATH = ROOTN "/" t "/" NN
      if (match(l, /instance=ExtResource\([ \t]*"?[^")]*/)) { t = substr(l, RSTART, RLENGTH); sub(/^.*\([ \t]*"?/, "", t); gsub(/[ \t]/, "", t); NI = ER[t] }
      if (match(l, /groups=\[[^]]*\]/)) {
        g = substr(l, RSTART + 8, RLENGTH - 9); gsub(/"/, "", g); m = split(g, ga, /[ ,]+/)
        for (i = 1; i <= m; i++) if (ga[i] != "") emit("group", ga[i], n, "group " ga[i] " on " NPATH, "")
      }
    }
    else if (NL && match(l, /^script[ \t]*=[ \t]*ExtResource\([ \t]*"?[^")]*/)) { t = substr(l, RSTART, RLENGTH); sub(/^.*\([ \t]*"?/, "", t); gsub(/[ \t]/, "", t); NS0 = ER[t] }
  } else if (X == "godot") {
    if (match(l, /^\[[A-Za-z_]+\]/)) { SEC = substr(l, 2, RLENGTH - 2); return }
    if (match(l, /^[A-Za-z0-9_.\/]+=/)) {
      t = substr(l, 1, RLENGTH - 1)
      if (SEC == "input") emit("input", t, n, "input " t, "")
      else if (SEC == "global_group") emit("group", t, n, "global_group " t, "")
      else if (SEC == "autoload") { s = l; sub(/^[^=]*="?\*?/, "", s); sub(/"[ \t]*$/, "", s); emit("autoload", t, n, "autoload " t " " rel(s), rel(s)) }
    }
  } else if (X == "cs") {
    if (l ~ /^[ \t]*\[Signal\][ \t]*$/) { PS = 1; return }
    if (l ~ /^[ \t]*\[Export[^]]*\][ \t]*$/) { PX = 1; return }
    if (match(l, /^[ \t]*(\[[^]]*\][ \t]*)*((public|private|protected|internal|static|sealed|partial|abstract|readonly)[ \t]+)*(class|struct|interface|enum|record)[ \t]+[A-Za-z_][A-Za-z0-9_]*/)) { t = lastid(l); def("class", t, n, l) }
    else if ((PS || l ~ /\[Signal\]/) && l ~ /delegate/ && match(l, /[A-Za-z_][A-Za-z0-9_]*[ \t]*\(/)) { t = lastid(l); sub(/EventHandler$/, "", t); s = l; sub(/^[ \t]*\[Signal\][ \t]*/, "", s); def("signal", t, n, s) }
    else if ((PX || l ~ /\[Export/) && match(l, /[A-Za-z_][A-Za-z0-9_]*[ \t]*(\{|=|;)/)) { t = substr(l, RSTART, RLENGTH); sub(/[ \t]*[{=;]$/, "", t); s = l; sub(/^[ \t]*\[Export[^]]*\][ \t]*/, "", s); def("export", t, n, s) }
    else if (match(l, /^[ \t]*(\[[^]]*\][ \t]*)*((public|private|protected|internal|static|override|virtual|async|sealed|abstract|partial|extern|unsafe|new)[ \t]+)+[A-Za-z_][^=;(]*[ \t]+[A-Za-z_][A-Za-z0-9_]*[ \t]*(<[^>]*>)?[ \t]*\(/)) {
      t = substr(l, RSTART, RLENGTH); sub(/[ \t]*(<[^>]*>)?[ \t]*\($/, "", t); sub(/^.*[^A-Za-z0-9_]/, "", t); s = l; sub(/[ \t]*\{.*$/, "", s); def("func", t, n, s)
    }
    if (l ~ /[^ \t]/) { PS = 0; PX = 0 }
  } else if (X == "ts" || X == "js") {
    if (match(l, /^(export[ \t]+)?(default[ \t]+)?(async[ \t]+)?function\*?[ \t]+[A-Za-z_$][A-Za-z0-9_$]*/)) { t = lastid(l); s = l; sub(/[ \t]*\{.*$/, "", s); def("func", t, n, s) }
    else if (match(l, /^(export[ \t]+)?(default[ \t]+)?(abstract[ \t]+)?class[ \t]+[A-Za-z_$][A-Za-z0-9_$]*/)) { t = lastid(l); def("class", t, n, "class " t) }
    else if (match(l, /^export[ \t]+(const|let|var)[ \t]+[A-Za-z_$][A-Za-z0-9_$]*/)) { t = lastid(l); def("const", t, n, substr(l, RSTART, RLENGTH)) }
  } else if (X == "py") {
    if (match(l, /^( {4}|\t)?(async[ \t]+)?def[ \t]+[A-Za-z_][A-Za-z0-9_]*/)) { t = lastid(l); s = l; sub(/:[ \t]*(#.*)?$/, "", s); def("func", t, n, s) }
    else if (match(l, /^( {4}|\t)?class[ \t]+[A-Za-z_][A-Za-z0-9_]*/)) { t = lastid(l); def("class", t, n, "class " t) }
  }
}
function scanfile(f, h,   l, n) {
  begin(f, h); n = 0
  while ((getline l < (ROOT "/" f)) > 0) scan(l, ++n)
  close(ROOT "/" f); finish()
}

# ---- query: match words against the expanded terms of each query word ----
function hit(t, w,   a, b) {
  if (t == w) return 2
  a = length(t); b = length(w)
  if ((a < b ? a : b) >= 4 && (index(w, t) == 1 || index(t, w) == 1)) return 1
  return 0
}
# best score of one query word qi over the words in s
function qscore(qi, s,   ws, m, i, j, b, v, h) {
  m = split(s, ws, " "); b = 0
  for (i = 1; i <= m; i++) for (j = 1; j <= TN[qi]; j++) {
    h = hit(T[qi, j], ws[i]); if (!h) continue
    v = (TW[qi, j] ? (h == 2 ? 10 : 8) : (h == 2 ? 7 : 5)); if (v > b) b = v
  }
  return b
}
function score(s,   qi, t, v) { t = 0; for (qi = 1; qi <= nQ; qi++) { v = qscore(qi, s); if (!v) return 0; t += v } return t }
function cand(sc, f, l, label, pri) { nC++; Cs[nC] = sc * 10 + pri; Cf[nC] = f; Cl[nC] = l; Ct[nC] = label }
function expand(   qs, i, j, m, g, gw, gm, k, hasw) {
  nQ = split(words(Q), qs, " ")
  for (i = 1; i <= nQ; i++) {
    TN[i] = 1; T[i, 1] = qs[i]; TW[i, 1] = 1; split("", hasw); hasw[qs[i]] = 1
    for (g = 1; g <= nG; g++) {
      gm = split(G[g], gw, " "); m = 0
      for (j = 1; j <= gm; j++) if (hit(qs[i], gw[j])) { m = 1; break }
      if (!m) continue
      for (j = 1; j <= gm; j++) if (!(gw[j] in hasw)) { hasw[gw[j]] = 1; k = ++TN[i]; T[i, k] = gw[j]; TW[i, k] = 0 }
    }
  }
}
function query(   r, f, i, s, sc, ps, best, pri, j, take, out, fr, cap) {
  expand()
  for (r = 1; r <= nN; r++) {
    if (Nk[r] == "file") continue
    s = words(Nn[r]); if (Nk[r] == "tag" || Nk[r] == "node" || Nk[r] == "autoload") s = s " " words(Nx[r])
    sc = score(s); if (!sc) continue
    if (score(pathwords(Nf[r]))) sc += 2
    pri = (Nk[r] == "tag") ? 5 : (Nk[r] ~ /^(class|func|signal|export|input|autoload)$/) ? 4 : (Nk[r] == "node") ? 3 : 2
    cand(sc, Nf[r], Nl[r], Ns[r], pri)
  }
  for (i = 1; i <= nNF; i++) {
    f = Nfile[i]; ps = score(pathwords(f)); if (!ps) continue
    best = 0; s = "file"
    split(Nrows[f], fr, " ")
    for (j in fr) if (Nk[fr[j]] == "class") { best = Nl[fr[j]]; s = Ns[fr[j]]; break }
    cand(int(ps / 2), f, (best ? best : 1), (s == "file" ? "file " base(f) : s), 1)
  }
  notes()
  # at most five lines, best first, then the shorter path and the earlier line; two per file while other files match
  out = 0; split("", take); cap = 2
  while (out < 5) {
    best = 0
    for (i = 1; i <= nC; i++) {
      if (i in take || cnt[Cf[i]] >= cap || ((Cf[i], Cl[i]) in shown)) continue
      if (!best || Cs[i] > Cs[best] || (Cs[i] == Cs[best] && (length(Cf[i]) < length(Cf[best]) || (length(Cf[i]) == length(Cf[best]) && Cl[i] + 0 < Cl[best] + 0)))) best = i
    }
    if (!best) { if (cap == 2) { cap = 5; continue } break }
    take[best] = 1; cnt[Cf[best]]++; shown[Cf[best], Cl[best]] = 1; out++
    print Cf[best] ":" Cl[best] "  " Ct[best]
  }
  return out
}

# ---- feature map from notes: bound to the file hash and the symbol at the noted line ----
function nearest(f, l,   fr, j, r, b) {
  b = 0; split(Nrows[f], fr, " ")
  for (j in fr) { r = fr[j]; if (Nk[r] != "tag" && Nk[r] != "group" && Nl[r] <= l && (!b || Nl[r] > Nl[b])) b = r }
  return b
}
function resolve(p,   i, g, n) {
  if (p in Nh) return p
  n = 0; for (i = 1; i <= nNF; i++) { g = Nfile[i]; if (substr(g, length(g) - length(p)) == "/" p) { n++; r0 = g } }
  return n == 1 ? r0 : ""
}
function harvest(   l, txt, k, t, p, ln, f, r, i, ws) {
  if (BRIEF == "") return
  while ((getline l < BRIEF) > 0) {
    sub(/\r$/, "", l); if (l !~ /^- /) continue
    txt = l; sub(/^- [^:]*: /, "", txt); i = 0; t = txt
    while (match(t, /[A-Za-z0-9_.\/-]+\.(gd|tscn|cs|tsx?|m?js|py|godot)(:[0-9]+)?/)) {
      p = substr(t, RSTART, RLENGTH); t = substr(t, RSTART + RLENGTH); k = txt "#" (++i)
      if (k in FK) continue
      ln = 0; if (match(p, /:[0-9]+$/)) { ln = substr(p, RSTART + 1) + 0; p = substr(p, 1, RSTART - 1) }
      f = resolve(p); if (f == "") continue
      r = nearest(f, ln ? ln : 1); if (!ln) r = 0
      ws = txt; gsub(/[A-Za-z0-9_.\/-]+\.(gd|tscn|cs|tsx?|m?js|py|godot)(:[0-9]+)?/, " ", ws)
      FK[k] = 1; nF++; Ff[nF] = f; Fl[nF] = ln; Fh[nF] = Nh[f]; Fk[nF] = (r ? Nk[r] : ""); Fn[nF] = (r ? Nn[r] : ""); Fw[nF] = words(ws); Ft[nF] = txt
      print k "\t" f "\t" ln "\t" Nh[f] "\t" Fk[nF] "\t" Fn[nF] "\t" Fw[nF] "\t" txt >> FEAT
    }
  }
  close(BRIEF); close(FEAT)
}
function notes(   i, sc, f, l, lab, r, m, g, j, rs) {
  for (i = 1; i <= nF; i++) {
    sc = score(Fw[i]); if (!sc) continue
    lab = "note: " (length(Ft[i]) > 70 ? substr(Ft[i], 1, 70) "..." : Ft[i]); f = Ff[i]; l = Fl[i]
    if ((f in Nh) && Nh[f] == Fh[i]) { cand(sc + 1, f, (l ? l : 1), lab, 4); continue }
    if (Fn[i] != "") {
      if ((f, Fk[i], Fn[i]) in NK) { r = NK[f, Fk[i], Fn[i]]; cand(sc + 1, f, Nl[r], lab " (file changed, found " Fk[i] " " Fn[i] " again)", 4); continue }
      m = split(NS[Fk[i], Fn[i]], rs, " ")
      if (m == 1) { r = rs[1]; cand(sc + 1, Nf[r], Nl[r], lab " (moved from " f ")", 4); continue }
      cand(sc - 2, f, l, "STALE " lab " (" Fk[i] " " Fn[i] " is gone, read the code)", 0); continue
    }
    if (f in Nh) { cand(sc - 2, f, (l ? l : 1), "STALE? " lab " (file changed since the note, line may have moved)", 0); continue }
    g = ""; for (j = 1; j <= nNF; j++) if (Nh[Nfile[j]] == Fh[i]) g = Nfile[j]
    if (g != "") cand(sc + 1, g, (l ? l : 1), lab " (moved from " f ")", 4)
    else cand(sc - 2, f, l, "STALE " lab " (file is gone)", 0)
  }
}

# ---- changes between O (last answer or a git state) and N (now) ----
function chg(pri, s) { nX++; Xp[nX] = pri; Xs[nX] = s }
function changes(   i, f, g, r, k, n, key, m, rs, j, dst, cntf, ren, gone) {
  split("", ren); split("", ren2)
  for (i = 1; i <= nOF; i++) {
    f = Ofile[i]; if (f in Nh) continue
    for (j = 1; j <= nNF; j++) { g = Nfile[j]; if (!(g in Oh) && Nh[g] == Oh[f] && !(g in ren2)) { ren[f] = g; ren2[g] = f; chg(1, "moved: " f " -> " g); break } }
    if (!(f in ren)) gone[f] = 1
  }
  for (r = 1; r <= nO; r++) {
    k = Ok[r]; n = On[r]; f = Of[r]; if (k == "file" || k == "tag" || OK[f, k, n] != r) continue
    dst = (f in ren) ? ren[f] : f
    if ((dst, k, n) in NK) {
      j = NK[dst, k, n]; if (Ns[j] != Os[r]) chg(2, "changed: " dst ":" Nl[j] " " Ns[j] "  was " Os[r]); continue
    }
    m = split(NS[k, n], rs, " "); g = ""
    for (j = 1; j <= m; j++) if (!((Nf[rs[j]], k, n) in OK) && !(Nf[rs[j]] in ren2)) { g = rs[j]; break }
    if (g != "") chg(1, "moved: " k " " n " " f " -> " Nf[g] ":" Nl[g])
    else if (!(f in gone)) chg(3, "gone: " k " " n " (was " f ":" Ol[r] ")")
  }
  for (f in gone) chg(3, "deleted: " f)
  for (i = 1; i <= nNF; i++) { f = Nfile[i]; if (!(f in Oh) && !(f in ren2)) { split(Nrows[f], rs, " "); m = 0; for (j in rs) if (Nk[rs[j]] != "tag") m++; chg(4, "new: " f " (" m " symbols)") } }
  for (r = 1; r <= nN; r++) {
    k = Nk[r]; n = Nn[r]; f = Nf[r]; if (k == "file" || k == "tag" || !(f in Oh) || NK[f, k, n] != r) continue
    src = (f in ren2) ? ren2[f] : f
    if ((src, k, n) in OK) continue
    m = split(OSx[k, n], rs, " "); g = 0
    for (j = 1; j <= m; j++) if (!((Of[rs[j]], k, n) in NK)) { g = 1; break }
    if (!g) chg(4, "added: " f ":" Nl[r] " " Ns[r])
  }
}
function printchanges(max,   p, i, out) {
  out = 0
  for (p = 1; p <= 4; p++) for (i = 1; i <= nX; i++) if (Xp[i] == p) { if (out < max) print Xs[i]; out++ }
  if (out > max) print "+" (out - max) " more changes: warmd where --changed"
  return out
}

BEGIN {
  # previous index, one block of rows per file
  while ((getline l < OLDIDX) > 0) { split(l, p, "\t"); if (p[4] == "file") PH[p[1]] = p[2]; PR[p[1]] = PR[p[1]] l "\n" }
  close(OLDIDX)
  PRJ = ""; pl = 0
  while ((getline f < LIST) > 0) { if ((getline h < HASHES) <= 0) break; nL++; Lf[nL] = f; Lh[nL] = h
    if (f ~ /(^|\/)project\.godot$/ && (!pl || length(f) < pl)) { pl = length(f); PRJ = f; sub(/project\.godot$/, "", PRJ) } }
  close(LIST); close(HASHES)
  TGT = "N"; WRITE = 1
  for (i = 1; i <= nL; i++) {
    f = Lf[i]; h = Lh[i]
    if (PH[f] == h && h != "") { m = split(PR[f], rows, "\n"); for (j = 1; j < m; j++) { split(rows[j], p, "\t"); addrow("N", p[1], p[2], p[3], p[4], p[5], p[6], p[7]) } }
    else scanfile(f, h)
  }
  close(NEWIDX); WRITE = 0
  # the state to compare against: the last answer of this checkout, or a git state
  if (MODE == "cr") {
    while ((getline l < REFLIST) > 0) { split(l, p, "\t"); if (p[1] in Nh && Nh[p[1]] == p[2]) { addrow("O", p[1], p[2], 0, "file", p[1], "", ""); split(Nrows[p[1]], rs, " "); for (j in rs) { r = rs[j]; addrow("O", Nf[r], "", Nl[r], Nk[r], Nn[r], Ns[r], Nx[r]) } } }
    while ((getline l < REQ) > 0) { split(l, p, "\t"); nR++; Rf[nR] = p[1]; Rh[nR] = p[2] }
    TGT = "O"; i = 0
    while ((getline hd < STREAM) > 0) {
      if (hd == "") continue
      i++; if (hd ~ / missing$/) continue
      split(hd, p, " "); size = p[3] + 0; got = 0; n = 0; begin(Rf[i], Rh[i])
      while (got < size && (getline l < STREAM) > 0) { got += length(l) + 1; scan(l, ++n) }
      finish()
    }
    TGT = "N"
  } else if (SEEN != "") {
    while ((getline l < SEEN) > 0) { split(l, p, "\t"); addrow("O", p[1], p[2], p[3], p[4], p[5], p[6], p[7]); had = 1 }
    close(SEEN)
  }
  if (MODE == "q") {
    nG = split(SYN, G, "\n")
    for (r = 1; r <= nN; r++) if (Nk[r] == "tag") { t = Nx[r]; gsub(/,/, " ", t); G[++nG] = words(t) }
    while ((getline l < FEAT) > 0) { split(l, p, "\t"); FK[p[1]] = 1; nF++; Ff[nF] = p[2]; Fl[nF] = p[3] + 0; Fh[nF] = p[4]; Fk[nF] = p[5]; Fn[nF] = p[6]; Fw[nF] = p[7]; Ft[nF] = p[8] }
    close(FEAT)
    harvest()
    found = query()
    if (!found) print "no place for '" Q "' in " nNF " files. Try another word, warmd map, or tag the code: # warmd: feature=" words(Q)
    if (had) { changes(); printchanges(3) }
  } else {
    if (MODE == "cs" && !had) { print "OK first read, nothing to compare yet; the next warmd where shows what changed"; }
    else { changes(); if (!printchanges(60)) print "OK no changes since " (MODE == "cr" ? REF : "your last warmd where") }
  }
  if (MODE != "cr" && SEEN != "") {
    printf "" > SEEN
    for (r = 1; r <= nN; r++) print Nf[r] "\t" (Nk[r] == "file" ? Nh[Nf[r]] : "") "\t" Nl[r] "\t" Nk[r] "\t" Nn[r] "\t" Ns[r] "\t" Nx[r] > SEEN
    close(SEEN)
  }
  exit (MODE == "q" && !found) ? 1 : 0
}
EOF

where_main() {
  local mode=q ref="" q="" root gd cd dir rc p seen="" brief="" files
  case "${1:-}" in
    ""|-h|--help) echo "warmd where <term>          at most five file:line places for a term, then what changed since your last read"
                  echo "warmd where --changed [ref]  every moved, changed, gone or added symbol since your last read or a git state"; return 2;;
    --changed) mode=cs; [ -n "${2:-}" ] && { mode=cr; ref="$2"; };;
    *) q="$*";;
  esac
  { IFS= read -r root; IFS= read -r gd; IFS= read -r cd; } < <(git -C "${GIT_ROOT:-$PWD}" rev-parse --show-toplevel --path-format=absolute --git-dir --git-common-dir 2>/dev/null)
  [ -n "${cd:-}" ] || { echo "FAIL warmd where needs a git repo"; return 2; }
  dir="$gd/warmd-where"; mkdir -p "$dir"
  # git lists tracked and untracked sources, a tracked file deleted in the work tree is dropped here (hash-object needs it)
  git -C "$root" -c core.quotepath=off ls-files -co --exclude-standard --deduplicate -- '*.gd' '*.tscn' '*.cs' '*.ts' '*.tsx' '*.js' '*.mjs' '*.py' '*project.godot' > "$dir/files.all"
  mapfile -t files < "$dir/files.all"
  for p in "${files[@]}"; do [ -f "$root/$p" ] && printf '%s\n' "$p"; done > "$dir/files"
  git -C "$root" hash-object --stdin-paths < "$dir/files" > "$dir/hashes" || { echo "FAIL git hash-object"; return 2; }
  : > "$dir/reflist"; : > "$dir/req"; : > "$dir/stream"
  if [ "$mode" = cr ]; then
    git -C "$root" rev-parse -q --verify "$ref^{commit}" >/dev/null || { echo "FAIL $ref is no git state"; return 2; }
    git -C "$root" -c core.quotepath=off ls-tree -r --full-tree "$ref" | LC_ALL=C awk -F'\t' -v L="$dir/files" -v H="$dir/hashes" -v RL="$dir/reflist" -v RQ="$dir/req" '
      BEGIN { while ((getline f < L) > 0) { getline h < H; cur[f] = h } }
      $2 ~ /\.(gd|tscn|cs|ts|tsx|js|mjs|py)$|(^|\/)project\.godot$/ { split($1, m, " "); if (m[2] != "blob") next
        print $2 "\t" m[3] > RL; if (cur[$2] != m[3]) { print $2 "\t" m[3] > RQ; print m[3] > (RQ ".ids") } }'
    [ -s "$dir/req.ids" ] && git -C "$root" cat-file --batch < "$dir/req.ids" > "$dir/stream"
    rm -f "$dir/req.ids"
  else seen="$dir/seen.tsv"
  fi
  [ -f "$cd/warmd-shared.md" ] && brief="$cd/warmd-shared.md"
  LC_ALL=C awk -v ROOT="$root" -v LIST="$dir/files" -v HASHES="$dir/hashes" -v OLDIDX="$dir/index.tsv" -v NEWIDX="$dir/index.new" \
    -v MODE="$mode" -v Q="$q" -v REF="$ref" -v SEEN="$seen" -v SYN="$WHERE_SYN" -v BRIEF="$brief" -v FEAT="$cd/warmd-where-features.tsv" \
    -v REFLIST="$dir/reflist" -v REQ="$dir/req" -v STREAM="$dir/stream" "$WHERE_AWK" < /dev/null
  rc=$?
  if [ -f "$dir/index.new" ]; then mv -f "$dir/index.new" "$dir/index.tsv"; elif [ ! -s "$dir/files" ]; then : > "$dir/index.tsv"; fi
  return $rc
}
