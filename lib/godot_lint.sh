# warmd lint: Godot lints on the changed .gd, .tscn and .tres files (or the files given).
#   ERROR  proven: the engine (godot/lint.gd, headless) or the real file system confirms it. warmd check turns red.
#   WARN   what nobody can prove from here, capped (WARMD_LINT_WARN, default 10) so the output stays worth reading.
# Cheap first: one awk pass finds candidates, project.godot and the file list settle most of them, the engine starts
# only for what is left. Without Godot the rest stays a warning, never an error.
#   string lints   Input actions, groups, /root/ autoload paths, collision layers, tr("KEY"), res:// paths
#   res:// case    a path whose case differs from the file on disk works on Windows, breaks on export and Linux
#   per frame      load() or get_node() in _process/_physics_process, physics calls in _process or input callbacks
#   shared res     a preloaded .tres/.res changed without duplicate(): every user of the resource sees the change
#   determinism    global randi/randf without seed(), RandomNumberGenerator without a seed, wall clock in gameplay code
#   scenes         editable children of an instanced sub-scene, very big scenes, big embedded sub_resources
# godot_lint [files...] is what warmd check calls, lint_main the command.
reg lint "warmd lint [files...]        Godot lints on changed files: engine-proven errors, capped warnings" lint_main

lint_main() {
  detect_project
  [ "$KIND" = godot ] || { echo "FAIL warmd lint is for Godot projects, this is $KIND"; return 2; }
  # shellcheck source=/dev/null
  . "$WARMD_HOME/adapters/godot.sh"
  godot_lint "$@"
}

read -r -d '' LINT_SCAN_AWK <<'EOF' || true
# out: E|W <tab> file:line <tab> message, R <tab> file:line <tab> message (global random, dropped when seed() is called),
#      C <tab> kind <tab> value <tab> file:line (a string candidate the next pass settles)
function out(k, m) { print k "\t" FILENAME ":" FNR "\t" m }
function cand(k, v) { print "C\t" k "\t" v "\t" FILENAME ":" FNR }
# every first string argument of a call matching re, as candidates of kind k
function firsts(s, re, k,   t, q) {
  while (match(s, re)) {
    t = substr(s, RSTART, RLENGTH); s = substr(s, RSTART + RLENGTH)
    if (match(t, /"[^"]*"$/)) { q = substr(t, RSTART + 1, RLENGTH - 2); if (q != "") cand(k, q) }
  }
}
function flush(   n) {
  if (pf == "") return
  for (n in mut) if (!(mut[n] in dup)) print "W\t" pf ":" n "\t" mutmsg[n]
  if (!rngseed) for (n in rng) print "W\t" pf ":" n "\tRandomNumberGenerator without a seed: set .seed (or .state) so a replay gives the same run"
  if (nodes > NODEMAX) print "W\t" pf ":1\t" nodes " nodes in one scene: instance sub-scenes, one scene per thing it owns"
  flushsub()
  split("", mut); split("", mutmsg); split("", dup); split("", shared); split("", rng); rngseed = 0; nodes = 0; pf = ""
}
function flushsub() {
  if (subline && subbytes > SUBMAX * 1024) print "W\t" pf ":" subline "\tembedded " subtype " of " int(subbytes / 1024) " KB: save it as its own .tres and load it"
  subline = 0; subbytes = 0
}
# regexes as strings: a regex constant passed to a function is matched against $0 first (gawk)
BEGIN {
  RE_action = "(is_action[a-z_]*|get_action_[a-z_]*strength|action_press|action_release)\\( *&?\"[^\"]*\""
  RE_group = "(is_in_group|get_nodes_in_group|get_first_node_in_group|call_group|set_group|notify_group)\\( *&?\"[^\"]*\""
  RE_tr = "(^|[^A-Za-z_.])(tr|tr_n|atr|atr_n)\\( *&?\"[^\"]*\""
  RE_layer = "[A-Za-z_]*layer[A-Za-z_]*\\( *\"[^\"]*\""
}
FNR == 1 { flush(); pf = FILENAME; gd = FILENAME ~ /\.gd$/; fn = ""; fnind = -1
  gameplay = FILENAME !~ /(^|\/)(tests?|addons)\// && FILENAME !~ /(^|\/)test_[^\/]*$|_test\.gd$/ }
{ sub(/\r$/, "") }
!gd {
  if ($0 ~ /^\[/) { flushsub(); if ($0 ~ /^\[sub_resource /) { subline = FNR; subtype = $0; sub(/^.*type="/, "", subtype); sub(/".*$/, "", subtype) } }
  else if (subline) subbytes += length($0) + 1
  if ($0 ~ /^\[node /) nodes++
  if ($0 ~ /^\[editable path="/) { p = $0; sub(/^\[editable path="/, "", p); sub(/".*$/, "", p)
    out("W", "editable children of the instanced sub-scene at " p ": this scene owns nodes of another one, change the sub-scene or expose an @export") }
  s = $0
  while (match(s, /"res:\/\/[^"]*"/)) {
    q = substr(s, RSTART + 1, RLENGTH - 2); s = substr(s, RSTART + RLENGTH)
    if (q != "res://" && q !~ /\/$/) cand(($0 ~ /uid="uid:\/\//) ? "resuid" : "res", q)
  }
  next
}
/^[ \t]*(#|$)/ { next }
{
  line = $0; match(line, /^[ \t]*/); ind = RLENGTH
  if (match(line, /^[ \t]*(static +)?func +[A-Za-z_0-9]+/)) { fn = substr(line, RSTART, RLENGTH); sub(/^.* /, "", fn); fnind = ind }
  else if (fnind >= 0 && ind <= fnind) { fn = ""; fnind = -1 }
  code = line; sub(/[ \t]#[^"]*$/, "", code)
  # strings
  firsts(code, RE_action, "action")
  if (match(code, /Input\.(get_axis|get_vector)\([^)]*\)/)) { t = substr(code, RSTART, RLENGTH)
    while (match(t, /"[^"]*"/)) { cand("action", substr(t, RSTART + 1, RLENGTH - 2)); t = substr(t, RSTART + RLENGTH) } }
  firsts(code, RE_group, "group")
  t = code; while (match(t, /"\/root\/[A-Za-z_][A-Za-z0-9_]*/)) { cand("autoload", substr(t, RSTART + 7, RLENGTH - 7)); t = substr(t, RSTART + RLENGTH) }
  firsts(code, RE_tr, "tr")
  firsts(code, RE_layer, "layer")
  t = code; while (match(t, /set_collision_(layer|mask)_value\( *[0-9]+|get_collision_(layer|mask)_value\( *[0-9]+/)) {
    v = substr(t, RSTART, RLENGTH); t = substr(t, RSTART + RLENGTH); sub(/^[^(]*\( */, "", v)
    if (v + 0 < 1 || v + 0 > 32) out("E", "collision layer " v " is out of range, Godot has layers 1 to 32") }
  t = code
  while (match(t, /"res:\/\/[^"]*"[ ]*[%+]?/)) {
    q = substr(t, RSTART, RLENGTH); pre = substr(t, 1, RSTART - 1); t = substr(t, RSTART + RLENGTH)
    if (q ~ /[%+]$/) continue
    # a path the code only asks about (file_exists, globalize_path) is no reference, and a line can opt out
    if (pre ~ /(exists|exists_absolute|globalize_path)\( *$/ || $0 ~ /warmd: nolint/) continue
    sub(/^"/, "", q); sub(/"[ ]*$/, "", q)
    if (q != "res://" && q !~ /\/$/ && q !~ /[%{*]/) cand("res", q)
  }
  # per frame and physics
  if (fn == "_process" || fn == "_physics_process") {
    if (match(code, /(^|[^A-Za-z_.])load\(|ResourceLoader\.load\(|get_node(_or_null)?\(/)) {
      w = substr(code, RSTART, RLENGTH); sub(/^[^A-Za-z]/, "", w); sub(/\($/, "", w)
      out("W", w "() in " fn " runs every frame: load or look it up once (@onready, _ready, preload)") }
  }
  if (fn ~ /^(_process|_input|_unhandled_input|_unhandled_key_input|_gui_input|_shortcut_input)$/ && match(code, /(move_and_slide|move_and_collide|apply_force|apply_central_force|apply_impulse|apply_central_impulse|apply_torque|apply_torque_impulse|intersect_ray|intersect_shape|intersect_point|force_raycast_update|force_shapecast_update)\(/)) {
    w = substr(code, RSTART, RLENGTH - 1)
    out("W", w "() in " fn ": physics belongs in _physics_process, the frame rate changes the result") }
  # shared resources
  if (match(code, /^[ \t]*(@[a-z_]+ +)*(var|const) +[A-Za-z_][A-Za-z0-9_]*( *:[^=]*)? *:?= *(preload|load)\( *"res:\/\/[^"]+\.(tres|res)" *\) *$/)) {
    n = code; sub(/^[ \t]*(@[a-z_]+ +)*(var|const) +/, "", n); sub(/[^A-Za-z0-9_].*$/, "", n); shared[n] = 1 }
  if (match(code, /[A-Za-z_][A-Za-z0-9_]* *= *[A-Za-z_][A-Za-z0-9_]*\.duplicate\(/)) { n = substr(code, RSTART, RLENGTH); sub(/[^A-Za-z0-9_].*$/, "", n); dup[n] = 1 }
  for (n in shared) if (match(code, "(^|[^A-Za-z0-9_.])" n "\\.[A-Za-z_][A-Za-z0-9_]* *([-+*/]?=[^=]|\\.?set\\()")) {
    mut[FNR] = n; mutmsg[FNR] = n " is a shared resource (preload/load of a .tres): changing it changes it for every user, " n " = " n ".duplicate() first" }
  # determinism, gameplay code only
  if (gameplay) {
    if (match(code, /(^|[^A-Za-z0-9_.])(randi|randf|randi_range|randf_range|randfn|randomize)\(/)) { w = substr(code, RSTART, RLENGTH); sub(/^[^a-z]/, "", w); sub(/\($/, "", w)
      out("R", w "() uses the global unseeded generator: a replay differs, use a RandomNumberGenerator with a seed") }
    if (code ~ /RandomNumberGenerator\.new\(/) rng[FNR] = 1
    if (code ~ /\.(seed|state) *= *[^=]/) rngseed = 1
    if (match(code, /(Time\.get_ticks_(msec|usec)|Time\.get_unix_time_from_system|Time\.get_(datetime|date|time)_[a-z_]*|OS\.get_unix_time|OS\.get_ticks_msec)\(/)) { w = substr(code, RSTART, RLENGTH - 1)
      out("W", w "() in gameplay code: wall clock time is not deterministic, use delta or a tick counter") }
  }
}
END { flush() }
EOF

# Settles the candidates with project.godot, the file list and the group definitions; what only the engine can say goes on.
read -r -d '' LINT_RESOLVE_AWK <<'EOF' || true
# in: project.godot, the file list (FILES), group definitions (GROUPS), the scan output
# out: E|W lines, Q <tab> kind <tab> value <tab> loc <tab> fallback-message (asks the engine)
FILENAME == PG { sub(/\r$/, "")
  if ($0 ~ /^\[/) { sec = $0; next }
  if (sec == "[input]" && match($0, /^[^=]+=/)) act[substr($0, 1, RLENGTH - 1)] = 1
  if (sec == "[autoload]" && match($0, /^[^=]+=/)) aut[substr($0, 1, RLENGTH - 1)] = 1
  if (sec == "[global_group]" && match($0, /^[^=]+=/)) grp[substr($0, 1, RLENGTH - 1)] = 1
  if (sec == "[layer_names]" && match($0, /="[^"]*"$/)) lay[substr($0, RSTART + 2, RLENGTH - 3)] = 1
  if (sec == "[internationalization]" && $0 ~ /^locale\/translations=/) trs = 1
  next }
FILENAME == FILES { sub(/\r$/, ""); have[$0] = 1; low[tolower($0)] = $0; next }
FILENAME == GROUPS { sub(/\r$/, "")
  if ($0 ~ /^add_to_group/) { if (match($0, /"[^"]*"/)) grp[substr($0, RSTART + 1, RLENGTH - 2)] = 1; else dyn = 1 }
  else { t = $0; while (match(t, /"[^"]*"/)) { grp[substr(t, RSTART + 1, RLENGTH - 2)] = 1; t = substr(t, RSTART + RLENGTH) } }
  next }
$1 != "C" { print; next }
{ k = $2; v = $3; loc = $4
  if (k == "action") { if (!(v in act)) print "Q\taction\t" v "\t" loc "\tinput action \"" v "\" is not in project.godot [input]" }
  else if (k == "autoload") { if (!(v in aut)) print "Q\tautoload\t" v "\t" loc "\t/root/" v " is no autoload in project.godot" }
  else if (k == "group") { if (!dyn && !(v in grp)) print "W\t" loc "\tgroup \"" v "\" is never added: no add_to_group, scene groups or global group of that name" }
  else if (k == "layer") { if (!(v in lay)) print "W\t" loc "\tlayer name \"" v "\" is not in project.godot [layer_names]" }
  else if (k == "tr") { if (trs && v ~ /^[A-Z][A-Z0-9_.]*$/) print "Q\ttr\t" v "\t" loc "\ttranslation key \"" v "\"" }
  else if (k == "res" || k == "resuid") {
    p = substr(v, 7)
    if (p in have) next
    if (tolower(p) in low) { print (k == "res" ? "E" : "W") "\t" loc "\t" v " differs in case from res://" low[tolower(p)] ": works on Windows, breaks on export and Linux"; next }
    if (k == "res") print "Q\tres\t" v "\t" loc "\t" v " does not exist"
  }
}
EOF

godot_lint() {
  local -a files=()
  local f raw="$RUN/lint.raw" res="$RUN/lint.res" q="$RUN/lint.in" log="$RUN/lint.log" exe max="${WARMD_LINT_WARN:-10}" rc
  if [ $# -gt 0 ]; then
    for f in "$@"; do f="${f#"$PROJECT"/}"; f="${f#./}"; f="${f#res://}"; [ -f "$PROJECT/$f" ] && files+=("$f"); done
  else
    [ -n "$(type -t aff_changed)" ] || . "$WARMD_HOME/lib/affected.sh"
    while IFS= read -r f; do [ -f "$PROJECT/$f" ] && files+=("$f"); done < <(aff_changed | grep -E '\.(gd|tscn|tres)$' | grep -vE '(^|/)(\.godot|\.warmd|addons)/')
  fi
  [ ${#files[@]} -gt 0 ] || { echo "OK lint: no Godot file changed"; return 0; }
  ( cd "$PROJECT" && awk -v NODEMAX="${WARMD_LINT_NODES:-300}" -v SUBMAX="${WARMD_LINT_SUBRES_KB:-64}" "$LINT_SCAN_AWK" "${files[@]}" ) > "$raw"
  # Only what the candidates need: the file list for res:// paths, the group definitions for groups, a seed() for random
  : > "$RUN/lint.files"; : > "$RUN/lint.groups"
  if grep -qE '^C	(res|resuid)	' "$raw"; then
    ( cd "$PROJECT" && find . \( -name .git -o -name .godot -o -name .warmd \) -prune -o -print ) | sed 's#^\./##' > "$RUN/lint.files"
  fi
  if grep -q '^C	group	' "$raw"; then
    grep -rhoEs --include='*.gd' --include='*.tscn' -e 'add_to_group\( *&?("[^"]*"|[^"& )][^),]*)' -e 'groups=\[[^]]*\]' "$PROJECT" --exclude-dir=.godot --exclude-dir=.git > "$RUN/lint.groups"
  fi
  if grep -q '^R	' "$raw" && grep -rqsE --include='*.gd' '(^|[^A-Za-z0-9_.])seed\(' "$PROJECT" --exclude-dir=.godot --exclude-dir=.git --exclude-dir=addons; then
    sed -i '/^R	/d' "$raw"
  fi
  awk -F'\t' -v PG="$PROJECT/project.godot" -v FILES="$RUN/lint.files" -v GROUPS="$RUN/lint.groups" "$LINT_RESOLVE_AWK" \
    "$PROJECT/project.godot" "$RUN/lint.files" "$RUN/lint.groups" "$raw" > "$res"
  # The engine only for what is still open, one start for all of it
  : > "$log"
  if grep -q '^Q	' "$res"; then
    if exe="$(godot_exe)"; then
      cut -f2,3 < <(grep '^Q	' "$res") | awk '!seen[$0]++' > "$q"
      [ -n "${SLOT:-}" ] || slot_take
      WARMD_LINT_IN="$(native_path "$q")" timeout "${WARMD_LINT_TIMEOUT:-120}" "$exe" --headless --path "$(native_path "$PROJECT")" --script "$(native_path "$WARMD_HOME/godot/lint.gd")" > "$log" 2>&1
      rc=$?
      grep -q '^LINT END' "$log" || echo "(the engine gave no verdict, exit $rc: the open candidates stay warnings, see $(native_path "$log"))"
    else exe=""; fi
  fi
  tr -d '\r' < "$log" | sed -n 's/^LINT \([a-z]\)/\1/p' > "$RUN/lint.verdict"
  awk -F'\t' -v MAX="$max" -v ENG="${exe:+1}" -v N="${#files[@]}" -v V="$RUN/lint.verdict" '
    FILENAME == V { v[$1 "\t" $2] = $3; next }
    $1 == "Q" { r = v[$2 "\t" $3]
      if (r == "ok") next
      if (r == "missing") { $1 = "E"; $2 = $4; $3 = $5 " and the engine does not know it either" }
      else { $1 = "W"; $2 = $4; $3 = $5 (r == "unknown" ? ", the engine could not tell" : ENG ? ", the engine gave no verdict" : ", not confirmed: no Godot (set WARMD_GODOT)") } }
    !seen[$1 "\t" $2 "\t" $3]++ { if ($1 == "E") e[++ne] = $2 " " $3; else w[++nw] = $2 " " $3 }
    END {
      for (i = 1; i <= ne; i++) print "ERROR " e[i]
      for (i = 1; i <= nw && i <= MAX; i++) print "WARN " w[i]
      if (nw > MAX) print "(" nw - MAX " more warnings, WARMD_LINT_WARN=" nw " shows all)"
      print (ne ? "FAIL" : "OK") " lint: " N " files, " ne + 0 " errors, " nw + 0 " warnings"
      exit ne > 0 }' "$RUN/lint.verdict" "$res"
}
