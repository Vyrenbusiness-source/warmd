# Roles and their models: role_<role>=provider:model in warmd.conf (a bare model means provider claude).
# producer plans milestones, worker edits code (per area), qa writes scenarios and replays, reviewer judges work it did not
# write, merge integrates, scout reads. The director is the human. warmd models shows and sets them.
ROLES="producer worker qa reviewer merge scout"

# model_rank <model> -> REPLY 1 (cheap), 2 (mid), 3 (top). An unknown name counts as mid.
model_rank() { case "$1" in *haiku*) REPLY=1;; *opus*) REPLY=3;; *) REPLY=2;; esac; }
floor_rank() { case "${CFG_floor:-}" in top) REPLY=3;; mid) REPLY=2;; *) REPLY=1;; esac; }

# role_model <role> -> REPLY the model alias of that role, empty when warmd.conf sets none.
# Worker and qa edit files: never the cheap tier. Reviewer and merge never below floor. Raised to the tier model of the floor.
role_model() {
  local v="" min=1 r
  case "$1" in producer|worker|qa|reviewer|merge|scout) ;; *) REPLY=""; return 1;; esac
  eval "v=\"\${CFG_role_$1:-}\""
  v="${v##*:}"; v="${v//[[:space:]]/}"
  [ -n "$v" ] || { REPLY=""; return 1; }
  case "$1" in worker|qa) min=2;; reviewer|merge) floor_rank; min=$REPLY;; esac
  model_rank "$v"; r=$REPLY
  if [ "$r" -lt "$min" ]; then case "$min" in 3) v="$CFG_top";; 2) v="$CFG_mid";; esac; fi
  REPLY="$v"
}
role_provider() { local v; eval "v=\"\${CFG_role_$1:-}\""; case "$v" in *:*) REPLY="${v%%:*}";; *) REPLY=claude;; esac; }

# Presets: Quality is the default, Balanced trades the planner and the reviewer down, Frugal everything the floors allow.
models_preset() { # name -> role=model words
  case "$1" in
    quality|"") echo "producer=claude:opus worker=claude:sonnet qa=claude:sonnet reviewer=claude:opus merge=claude:sonnet scout=claude:haiku";;
    balanced) echo "producer=claude:sonnet worker=claude:sonnet qa=claude:sonnet reviewer=claude:sonnet merge=claude:sonnet scout=claude:haiku";;
    frugal) echo "producer=claude:haiku worker=claude:sonnet qa=claude:sonnet reviewer=claude:haiku merge=claude:haiku scout=claude:haiku";;
    *) return 1;;
  esac
}

# The role of a task: no files means a reading scout, scenario or replay work is qa, everything else a worker.
role_of() { # name goal files -> REPLY
  if [ -z "$3" ] || [ "$3" = none ]; then REPLY=scout; return; fi
  if printf '%s %s' "$1" "$2" | grep -qiE '(^|[^a-z])(qa|scenarios?|replays?)([^a-z]|$)'; then REPLY=qa; else REPLY=worker; fi
}
# The area a worker serves, from its files: ui, ai, audio, tools, gameplay, else plain worker. Each has its own role file.
area_role() { # files -> REPLY
  local f="/${1//,/ /}"
  case "$f" in
    */ui/*|*/hud/*|*/menu*|*/menus/*) REPLY=ui;;
    */ai/*|*/npc*|*/enemies/*|*/enemy/*) REPLY=ai;;
    */audio/*|*/sound*|*/music/*|*/sfx/*) REPLY=audio;;
    */tools/*|*/addons/*|*/editor/*) REPLY=tools;;
    */gameplay/*|*/player/*|*/levels/*|*/game/*) REPLY=gameplay;;
    *) REPLY=worker;;
  esac
}

# Role files: one per role and area in .warmd/roles, the area's Godot rules first, then lines learned from rolled-back merges.
role_file() { echo "$STATE/roles/$1.md"; }
role_file_init() { # role
  local f; f="$(role_file "$1")"; [ -f "$f" ] && return 0
  mkdir -p "$STATE/roles"
  {
    echo "# Role $1"
    [ -f "$PROJECT/project.godot" ] && case "$1" in
      ui) echo "- Godot UI: Control nodes with anchors and containers, no fixed pixel positions. Signals over polling, theme over per-node overrides.";;
      ai) echo "- Godot AI: decisions in _physics_process with a fixed budget, NavigationAgent for paths, no scene tree search per frame.";;
      audio) echo "- Godot audio: AudioStreamPlayer on named buses, no volume set in code without the bus, streams preloaded.";;
      tools) echo "- Godot tools: @tool scripts guard with Engine.is_editor_hint(), addons never write into game scenes on load.";;
      gameplay) echo "- Godot gameplay: logic in scripts, scenes only wire nodes. Typed GDScript, no get_node with long paths, physics in _physics_process.";;
      qa) echo "- QA: write only scenarios and replays, never game code. A scenario states its pass criterion.";;
      *) echo "- Godot: typed GDScript, one scene per task, never hand-edit .import or .uid files.";;
    esac
    echo "## Learned (one line per rolled-back merge)"
  } > "$f"
}
# A rolled-back merge leaves one rule line in the role file of each task it held.
role_learn() { # task cause
  local t="${1#warmd/}" r f
  r="$(cat "$STATE/tasks/$t.role" 2>/dev/null)" || return 0
  [ -n "$r" ] || return 0
  role_file_init "$r"; f="$(role_file "$r")"
  printf -- '- %s %s rolled back: %s\n' "$(date +%Y-%m-%d)" "$t" "$(printf '%s' "$2" | tr '\n' ' ' | cut -c1-140)" >> "$f"
}

# Success per model from the ledger: the model a task ran on (tasks/<name>.model, else its tier's model).
models_rate() { # -> lines "model ok total"
  local f td line t tier m out=""
  f="$(ledger_file 2>/dev/null)"; [ -s "$f" ] || return 0
  td="$STATE/tasks"
  while IFS=$'\t' read -r _ t tier _ _ _ _ o; do
    m=""; [ -f "$td/$t.model" ] && read -r m < "$td/$t.model"
    [ -n "$m" ] || m="$(tier_model "$tier")"
    out="$out$m $o"$'\n'
  done < "$f"
  printf '%s' "$out" | awk 'NF {n[$1]++; if ($2=="ok") k[$1]++} END {for (m in n) print m, k[m]+0, n[m]}'
}
models_rate_of() { # model rates -> REPLY "ok n/m" or "no data"
  local l; l="$(printf '%s\n' "$2" | awk -v m="$1" '$1==m {print $2 "/" $3; exit}')"
  REPLY="${l:-no data}"; [ -n "$l" ] && REPLY="ok $l"
}

# warmd.conf: one key set, its line replaced or appended, the running shell sees it at once
conf_set() { # key value
  local f="$PROJECT/warmd.conf"
  touch "$f"
  awk -v k="$1" -v v="$2" 'BEGIN {d=0} { s=$0; sub(/\r$/, "", s); split(s, a, "="); kk=a[1]; gsub(/[[:space:]]/, "", kk); if (kk==k) { if (!d) print k "=" v; d=1; next } print } END { if (!d) print k "=" v }' "$f" > "$f.tmp" && mv -f "$f.tmp" "$f"
  printf -v "CFG_$1" '%s' "$2"
}

# models_set role=model...: roles, preset=quality|balanced|frugal, cost_limit_day=<usd>. Nothing is written on a bad word.
models_set() {
  local w k v ok=1 todo=()
  for w in "$@"; do
    k="${w%%=*}"; v="${w#*=}"
    [ "$k" != "$w" ] || { echo "FAIL $w: role=model wanted"; ok=0; continue; }
    case "$k" in
      preset) models_preset "$v" >/dev/null || { echo "FAIL unknown preset $v: quality, balanced or frugal"; ok=0; continue; }
              for w in $(models_preset "$v"); do todo+=("role_${w%%=*}=${w#*=}"); done;;
      cost_limit_day) [[ $v =~ ^[0-9]+([.][0-9]+)?$ ]] || { echo "FAIL cost_limit_day is a number (USD per day)"; ok=0; continue; }; todo+=("$k=$v");;
      *) case " $ROLES " in *" $k "*) ;; *) echo "FAIL unknown role $k: $ROLES"; ok=0; continue;; esac
         [[ $v =~ ^([a-z0-9_-]+:)?[A-Za-z0-9._-]+$ ]] || { echo "FAIL $k=$v: provider:model or model"; ok=0; continue; }
         case "$v" in *:*) ;; *) v="claude:$v";; esac
         todo+=("role_$k=$v");;
    esac
  done
  [ $ok = 1 ] || return 2
  [ ${#todo[@]} -gt 0 ] || { echo "warmd models --set role=model..., e.g. warmd models --set worker=sonnet reviewer=opus"; return 2; }
  for w in "${todo[@]}"; do conf_set "${w%%=*}" "${w#*=}"; done
  echo "OK ${#todo[@]} set in warmd.conf"
}

models_list() {
  local r rates m eff
  rates="$(models_rate)"
  for r in $ROLES; do
    eval "m=\"\${CFG_role_$r:-}\""
    role_model "$r"; eff="$REPLY"
    if [ -z "$m" ]; then
      case "$r" in worker) eff="$(tier_model mid)";; scout) eff="$(tier_model cheap)";; reviewer|producer) eff="$(tier_model top)";; *) eff="$(tier_model mid)";; esac
      m="(default)"
    fi
    models_rate_of "$eff" "$rates"
    printf '%-9s %-22s model=%-12s %s\n' "$r" "$m" "$eff" "$REPLY"
  done
  echo "cost_limit_day=${CFG_cost_limit_day:-none}${CFG_floor:+ floor=$CFG_floor}"
}

# Text prompt: Enter keeps a value. Used without a display, over ssh, and on any non-Windows system.
models_prompt() {
  local p r cur v words=() c
  models_list
  printf 'preset (quality, balanced, frugal; Enter keeps): '; read -r p || p=""
  [ -n "$p" ] && words+=("preset=$p")
  for r in $ROLES; do
    eval "cur=\"\${CFG_role_$r:-}\""
    printf '%s [%s]: ' "$r" "${cur:-default}"; read -r v || v=""
    [ -n "$v" ] && words+=("$r=$v")
  done
  printf 'daily cost limit USD [%s]: ' "${CFG_cost_limit_day:-none}"; read -r c || c=""
  [ -n "$c" ] && words+=("cost_limit_day=$c")
  [ ${#words[@]} -gt 0 ] || { echo "OK nothing changed"; return 0; }
  models_set "${words[@]}"
}

# WinForms window: one row per role (provider, model, success from the ledger), a preset box and the daily cost limit.
# It prints role=provider:model lines on OK, nothing on Cancel; the values go through models_set like the text prompt.
models_gui() {
  local ps1 out r cur rates rows="" eff
  rates="$(models_rate)"
  for r in $ROLES; do
    eval "cur=\"\${CFG_role_$r:-}\""; role_provider "$r"; local pv="$REPLY"
    role_model "$r"; eff="${REPLY:-$(tier_model mid)}"
    models_rate_of "$eff" "$rates"
    rows="$rows$r|$pv|${cur##*:}|$REPLY;"
  done
  ps1="$(mktemp "${TMPDIR:-/tmp}/warmd-models.XXXXXX").ps1"
  cat > "$ps1" <<'PS'
param([string]$Rows, [string]$Cost, [string]$Presets)
Add-Type -AssemblyName System.Windows.Forms
$f = New-Object Windows.Forms.Form; $f.Text = 'warmd models'; $f.Width = 560; $f.FormBorderStyle = 'FixedDialog'; $f.StartPosition = 'CenterScreen'
$models = @('haiku', 'sonnet', 'opus'); $boxes = @{}; $y = 44
$pl = New-Object Windows.Forms.Label; $pl.Text = 'Preset'; $pl.Left = 10; $pl.Top = 14; $pl.Width = 90; $f.Controls.Add($pl)
$pre = New-Object Windows.Forms.ComboBox; $pre.Left = 100; $pre.Top = 10; $pre.Width = 140; $pre.DropDownStyle = 'DropDownList'
[void]$pre.Items.AddRange(@('(keep)', 'Quality', 'Balanced', 'Frugal')); $pre.SelectedIndex = 0; $f.Controls.Add($pre)
foreach ($row in ($Rows -split ';' | Where-Object { $_ })) {
  $p = $row -split '\|'
  $l = New-Object Windows.Forms.Label; $l.Text = $p[0]; $l.Left = 10; $l.Top = $y + 4; $l.Width = 90; $f.Controls.Add($l)
  $pv = New-Object Windows.Forms.ComboBox; $pv.Left = 100; $pv.Top = $y; $pv.Width = 90; [void]$pv.Items.Add('claude'); $pv.Text = $p[1]; $f.Controls.Add($pv)
  $m = New-Object Windows.Forms.ComboBox; $m.Left = 200; $m.Top = $y; $m.Width = 140; [void]$m.Items.AddRange($models); $m.Text = $p[2]; $f.Controls.Add($m)
  $s = New-Object Windows.Forms.Label; $s.Text = $p[3]; $s.Left = 350; $s.Top = $y + 4; $s.Width = 180; $f.Controls.Add($s)
  $boxes[$p[0]] = @($pv, $m, $p[2]); $y += 30
}
$pre.Add_SelectedIndexChanged({
  $sel = $pre.SelectedItem.ToString().ToLower(); if ($sel -eq '(keep)') { return }
  foreach ($w in (($Presets -split ';' | Where-Object { $_.StartsWith($sel + '=') }) -replace '^[^=]*=', '' -split ' ')) {
    $kv = $w -split '='; if ($boxes.ContainsKey($kv[0])) { $boxes[$kv[0]][1].Text = ($kv[1] -split ':')[-1] }
  }
})
$cl = New-Object Windows.Forms.Label; $cl.Text = 'Daily cost limit (USD)'; $cl.Left = 10; $cl.Top = $y + 4; $cl.Width = 180; $f.Controls.Add($cl)
$ct = New-Object Windows.Forms.TextBox; $ct.Left = 200; $ct.Top = $y; $ct.Width = 140; $ct.Text = $Cost; $f.Controls.Add($ct); $y += 40
$ok = New-Object Windows.Forms.Button; $ok.Text = 'OK'; $ok.Left = 360; $ok.Top = $y; $ok.DialogResult = 'OK'; $f.Controls.Add($ok); $f.AcceptButton = $ok
$no = New-Object Windows.Forms.Button; $no.Text = 'Cancel'; $no.Left = 450; $no.Top = $y; $no.DialogResult = 'Cancel'; $f.Controls.Add($no); $f.CancelButton = $no
$f.Height = $y + 80
if ($f.ShowDialog() -ne 'OK') { exit 1 }
foreach ($k in $boxes.Keys) { $b = $boxes[$k]; if ($b[1].Text -and $b[1].Text -ne $b[2]) { "$k=$($b[0].Text):$($b[1].Text)" } }
if ($ct.Text -and $ct.Text -ne $Cost) { "cost_limit_day=$($ct.Text)" }
PS
  local presets="" p
  for p in quality balanced frugal; do presets="$presets$p=$(models_preset "$p");"; done
  out="$(powershell.exe -NoProfile -STA -ExecutionPolicy Bypass -File "$(native_path "$ps1")" -Rows "$rows" -Cost "${CFG_cost_limit_day:-}" -Presets "$presets" 2>/dev/null | tr -d '\r')"; r=$?
  rm -f "$ps1"
  [ $r = 0 ] || { echo "OK cancelled, nothing changed"; return 0; }
  [ -n "$out" ] || { echo "OK nothing changed"; return 0; }
  # shellcheck disable=SC2086
  models_set $out
}

# Which face: WARMD_MODELS_UI=gui|text|none forces one. The window only on Windows with a desktop, never in CI or without a tty.
models_ui() {
  case "${WARMD_MODELS_UI:-}" in gui|text|none) REPLY="$WARMD_MODELS_UI"; return;; esac
  if [ -n "${CI:-}" ] || [ ! -t 0 ] || [ ! -t 1 ]; then REPLY=none
  elif case "$(uname -s 2>/dev/null)" in MINGW*|MSYS*|CYGWIN*) true;; *) false;; esac && command -v powershell.exe >/dev/null 2>&1 && [ -z "${SSH_CONNECTION:-}" ]; then REPLY=gui
  else REPLY=text
  fi
}

models_main() {
  case "${1:-}" in
    --list) models_list; return;;
    --set) shift; models_set "$@"; return;;
    "") ;;
    *) echo "warmd models [--list | --set role=model... | --set preset=quality|balanced|frugal | --set cost_limit_day=N]"; return 2;;
  esac
  models_ui
  case "$REPLY" in
    gui) models_gui;;
    text) models_prompt;;
    *) models_list; echo "not interactive: warmd models --set role=model changes one";;
  esac
}

# The first warmd init asks once, only when a person sits at it: never in CI, a hook or a pipe.
models_first_run() {
  [ -f "$STATE/models.asked" ] && return 0
  grep -q '^role_' "$PROJECT/warmd.conf" 2>/dev/null && return 0
  models_ui; [ "$REPLY" = none ] && return 0
  mkdir -p "$STATE"; : > "$STATE/models.asked"
  echo "warmd models: one model per role (Enter keeps the defaults)"
  models_main
}
