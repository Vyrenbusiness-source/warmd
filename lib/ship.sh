#!/usr/bin/env bash
# warmd ship and warmd ci: integrate finished task branches, open one PR, wait for CI, merge on green.
# Needs git and gh. Registers its own usage lines and dispatch, see reg in bin/warmd.

reg ship "warmd ship [--base B] [--release vX.Y.Z] <branch>...  merge task branches, one PR, wait for CI, merge on green" ship_main
reg ci   "warmd ci [branch]             wait for the CI of the current branch, one line per job" ci_main

# A conflict hunk is safe when every line on both sides is a usage line or a dispatch line.
# Resolution keeps both sides, ours first, without duplicates.
ship_union() { # file -> 0 resolved, 1 not safe
  awk '
    /^<<<<<<< / { inc=1; side=1; n1=0; n2=0; next }
    inc && /^\|\|\|\|\|\|\| / { side=0; next }
    inc && /^=======$/ { side=2; next }
    inc && /^>>>>>>> / {
      for (i=1;i<=n1;i++) { if (!safe(a[i])) bad=1; seen[a[i]]=1; out[++o]=a[i] }
      for (i=1;i<=n2;i++) { if (!safe(b[i])) bad=1; if (!(b[i] in seen)) out[++o]=b[i] }
      delete seen; inc=0; next
    }
    inc { if (side==1) a[++n1]=$0; else if (side==2) b[++n2]=$0; next }
    { out[++o]=$0 }
    function safe(l) { return l ~ /^  warmd / || l ~ /^ +[a-z][a-z-]*\) / || l ~ /^ +--/ || l ~ /^ *$/ }
    END { if (bad) exit 1; for (i=1;i<=o;i++) print out[i] }
  ' "$1" > "$1.warmd-union" || { rm -f "$1.warmd-union"; return 1; }
  mv "$1.warmd-union" "$1"
}

ship_run_id() { # branch -> newest run id
  gh run list --branch "$1" --limit 1 --json databaseId --jq '.[0].databaseId' 2>/dev/null
}

# One poll of a run. Line 1: run|status|conclusion|createdAt. Then per job: name|status|conclusion|open steps|failed steps|current step|steps.
ci_poll() { # id
  gh run view "$1" --json status,conclusion,createdAt,jobs --jq '"run|\(.status)|\(.conclusion // "")|\(.createdAt // "")", (.jobs[] | [.name, .status, (.conclusion // ""), ([.steps[]? | select(.status != "completed")] | length), ([.steps[]? | select(.conclusion == "failure")] | length), ([.steps[]? | select(.status == "in_progress") | .name][0] // ""), (.steps | length)] | map(tostring) | join("|"))' 2>/dev/null | tr -d '\r'
}

# A job whose steps are all completed counts by its steps: GitHub may keep it in_progress for many minutes after its last step.
# Prints one line per finished job, then: STATE|done|red|createdAt|first open job|its current step
ci_state() { # poll output on stdin
  awk -F'|' '
    NR==1 { rs=$2; rc=$3; created=$4; next }
    NF>=7 {
      st=$2; c=$3
      if (st!="completed" && $7>0 && $4==0) { st="completed"; c=($5>0 ? "failure" : "success") }
      n++
      if (st!="completed") { open++; if (job=="") { job=$1; step=($6!="" ? $6 : st) }; next }
      if (c!="success" && c!="skipped" && c!="neutral") red=1
      line[++l]=c " " $1
    }
    END {
      for (i=1;i<=l;i++) print line[i]
      done=((n>0 && open==0) || rs=="completed")
      if (n==0 && rs=="completed" && rc!="success") red=1
      print "STATE|" (done?1:0) "|" (red?1:0) "|" created "|" job "|" step
    }'
}

ci_epoch() { [ -n "${1:-}" ] && date -d "$1" +%s 2>/dev/null; }
ci_mark_file() { local top; top="$(git rev-parse --show-toplevel 2>/dev/null)" || return 1; mkdir -p "$top/.warmd" && echo "$top/.warmd/ci.wait"; }

# Waits for the newest run of a branch by polling, never by a blocking gh run watch.
# Prints an ETA from the median of recent runs, a SLOW line past 1.5x that median, one line per job, failing test names on red.
# WARMD_CI_MAX caps the wait in minutes. While it waits, .warmd/ci.wait tells warmd watch that this agent is busy.
ci_wait() { # branch
  local mark rc
  mark="$(ci_mark_file)"
  ci_wait_run "$@"; rc=$?
  [ -n "$mark" ] && rm -f "$mark"
  return $rc
}

ci_wait_run() { # branch
  local br="$1" id tries=0 t0 now cap med="" runs=0 snap st fin red created job step start el first=1 slow=0 mark left
  id="$(ship_run_id "$br")"
  while [ -z "$id" ] && [ $tries -lt "${WARMD_CI_TRIES:-30}" ]; do sleep "${WARMD_CI_POLL:-5}"; tries=$((tries+1)); id="$(ship_run_id "$br")"; done
  [ -n "$id" ] || { echo "FAIL no CI run for $br"; return 1; }
  t0="$(date +%s)"; cap=$(( ${WARMD_CI_MAX:-60} * 60 ))
  read -r med runs <<< "$(ci_median)"
  mark="$(ci_mark_file)"
  while :; do
    snap="$(ci_poll "$id" | ci_state)"
    st="$(printf '%s\n' "$snap" | tail -1)"
    IFS='|' read -r _ fin red created job step <<< "$st"
    now="$(date +%s)"; start="$(ci_epoch "$created")"; start="${start:-$t0}"; el=$((now - start))
    [ -n "$mark" ] && echo "$$ $id $start ${med:-0}" > "$mark"
    if [ $first = 1 ] && [ -n "$med" ]; then
      left=$(( (med - el + 59) / 60 ))
      if [ $left -gt 0 ]; then echo "ETA run $id: about $left min left, median $(( (med + 30) / 60 )) min of $runs runs"
      else echo "ETA run $id: past the median of $(( (med + 30) / 60 )) min over $runs runs"; fi
    fi
    first=0
    [ "$fin" = 1 ] && break
    if [ -n "$med" ] && [ "$med" -gt 0 ] && [ $slow = 0 ] && [ $((el * 2)) -gt $((med * 3)) ]; then
      slow=1; echo "SLOW run $id: $((el / 60)) min, median $(( (med + 30) / 60 )) min, ${job:-a job} at step ${step:-unknown}"
    fi
    if [ $((now - t0)) -ge $cap ]; then
      echo "FAIL CI run $id not done after ${WARMD_CI_MAX:-60} min, ${job:-a job} at step ${step:-unknown}"; return 1
    fi
    sleep "${WARMD_CI_POLL:-10}"
  done
  printf '%s\n' "$snap" | sed '$d' | sed 's/^success /ok   /; s/^failure /FAIL /'
  ci_record "$id" "$br" "$el" "$([ "$red" = 1 ] && echo failure || echo success)"
  if [ "$red" = 1 ]; then
    gh run view "$id" --log-failed 2>/dev/null | grep -oE '(FAIL|not ok) [^:]{1,80}' | sort -u | head -15 | sed 's/^/  test /'
    echo "RED run $id"; return 1
  fi
  echo "GREEN run $id"
}

# Release: the version in bin/warmd and the Unreleased section of CHANGELOG.md move to the new version, one commit.
ship_bump() { # vX.Y.Z
  local v="${1#v}" prev
  if [ -f bin/warmd ] && grep -q '^WARMD_VERSION=' bin/warmd; then
    sed -i "s/^WARMD_VERSION=.*/WARMD_VERSION=$v/" bin/warmd; git add bin/warmd
  fi
  if [ -f CHANGELOG.md ] && grep -q '^## \[Unreleased\]' CHANGELOG.md && ! grep -qF "## [$v]" CHANGELOG.md; then
    prev="$(sed -nE 's/^\[Unreleased\]: .*compare\/(v[0-9][0-9.]*)\.\.\.HEAD.*/\1/p' CHANGELOG.md)"
    awk -v v="$v" -v d="$(date +%Y-%m-%d)" -v prev="$prev" '
      /^## \[Unreleased\]/ { print; print ""; print "## [" v "] - " d; next }
      /^\[Unreleased\]: / && prev != "" { u=$0; sub(/^\[Unreleased\]: /, "", u); sub(/compare\/.*/, "", u)
        print "[Unreleased]: " u "compare/v" v "...HEAD"; print "[" v "]: " u "compare/" prev "...v" v; next }
      { print }' CHANGELOG.md > CHANGELOG.md.warmd && mv CHANGELOG.md.warmd CHANGELOG.md
    git add CHANGELOG.md
  fi
  git diff --cached --quiet && return 0
  git commit -qm "release v$v" || { echo "FAIL commit release v$v"; return 1; }
  echo "ok   version $v in bin/warmd and CHANGELOG.md"
}

# Origin URLs in one form: https, ssh and a trailing .git name the same repo
ship_url() { printf '%s' "$1" | sed -E 's#^[a-z+]+://##; s#^[^@/]*@##; s#^([^/:]+):([^/])#\1/\2#; s#/+$##; s#\.git$##' | tr '[:upper:]' '[:lower:]'; }

# After a green release the installed copy pulls, when it is a clean clone of this repo on the base branch
ship_install() { # base
  local inst="${WARMD_INSTALL:-$HOME/.warmd}" before after
  [ -d "$inst/.git" ] || return 0
  [ "$(ship_url "$(git -C "$inst" remote get-url origin 2>/dev/null)")" = "$(ship_url "$(git remote get-url origin 2>/dev/null)")" ] || return 0
  [ "$(git -C "$inst" rev-parse --abbrev-ref HEAD 2>/dev/null)" = "$1" ] || { echo "WARN installed copy not on $1, not updated"; return 0; }
  [ -z "$(git -C "$inst" status --porcelain 2>/dev/null)" ] || { echo "WARN installed copy has local changes, not updated"; return 0; }
  before="$(git -C "$inst" rev-parse --short HEAD)"
  git -C "$inst" pull -q --ff-only >/dev/null 2>&1 || { echo "WARN installed copy could not fast-forward"; return 0; }
  after="$(git -C "$inst" rev-parse --short HEAD)"
  [ "$before" = "$after" ] || echo "ok   installed copy $before to $after"
}

# One line when an install is behind its origin. Reads local refs only; a background fetch refreshes them at most every 6 hours.
install_behind() { # [install dir]
  local inst="${1:-$WARMD_HOME}" stamp n
  [ -d "$inst/.git" ] || return 0
  stamp="$inst/.git/warmd-fetched"
  if [ "${WARMD_UPDATE_CHECK:-1}" = 1 ] && [ -z "$(find "$stamp" -mmin -360 2>/dev/null)" ]; then
    touch "$stamp"; ( git -C "$inst" fetch -q origin >/dev/null 2>&1 & )
  fi
  n="$(git -C "$inst" rev-list --count 'HEAD..@{u}' 2>/dev/null)"
  [ -n "$n" ] && [ "$n" -gt 0 ] || return 0
  echo "UPDATE installed $(git -C "$inst" rev-parse --short HEAD) behind origin $(git -C "$inst" rev-parse --short '@{u}') by $n commits, run: warmd update"
}

ci_main() {
  local br="${1:-$(git branch --show-current)}"
  ci_wait "$br"
}

ship_main() {
  local base=main release="" into="warmd-ship" branches=() b
  while [ $# -gt 0 ]; do
    case "$1" in
      --base) base="$2"; shift 2;;
      --release) release="$2"; shift 2;;
      --into) into="$2"; shift 2;;
      *) branches+=("$1"); shift;;
    esac
  done
  [ ${#branches[@]} -gt 0 ] || { echo "usage: warmd ship [--base B] [--release vX.Y.Z] <branch>..."; return 2; }
  [ -z "$release" ] || echo "$release" | grep -qE '^v[0-9]+\.[0-9]+\.[0-9]+$' || { echo "FAIL release must look like v1.2.3"; return 2; }
  git fetch -q origin || { echo "FAIL git fetch origin"; return 1; }
  git checkout -q -B "$into" "origin/$base" || { echo "FAIL cannot branch from origin/$base"; return 1; }
  for b in "${branches[@]}"; do
    local ref="$b"; git rev-parse -q --verify "origin/$b" >/dev/null && ref="origin/$b"
    if git merge -q --no-ff --no-edit "$ref" >/dev/null 2>&1; then echo "ok   merged $b"; continue; fi
    local files f safe=1
    files="$(git diff --name-only --diff-filter=U)"
    for f in $files; do
      [ "$f" = bin/warmd ] && ship_union "$f" && git add "$f" || { safe=0; break; }
    done
    if [ $safe = 1 ] && [ -n "$files" ] && git -c core.editor=true commit -q --no-edit >/dev/null 2>&1; then
      echo "ok   merged $b, usage/dispatch conflict resolved"
    else
      git merge --abort 2>/dev/null
      echo "FAIL $b conflicts outside the usage/dispatch block: $(echo "$files" | tr '\n' ' ')"; return 1
    fi
  done
  [ -z "$release" ] || ship_bump "$release" || return 1
  git push -q --force-with-lease -u origin "$into" 2>/dev/null || git push -q -f -u origin "$into" || { echo "FAIL push $into"; return 1; }
  local pr
  pr="$(gh pr list --head "$into" --state open --json number --jq '.[0].number' 2>/dev/null)"
  if [ -n "$pr" ]; then echo "ok   updated PR #$pr"
  else
    pr="$(gh pr create --base "$base" --head "$into" --title "ship: ${branches[*]}" --body "Merged by warmd ship: ${branches[*]}" 2>/dev/null | grep -oE '[0-9]+$' | tail -1)"
    [ -n "$pr" ] || { echo "FAIL gh pr create"; return 1; }
    echo "ok   opened PR #$pr"
  fi
  ci_wait "$into" || { echo "FAIL CI red, PR #$pr not merged"; return 1; }
  gh pr merge "$pr" --merge >/dev/null 2>&1 || { echo "FAIL gh pr merge $pr"; return 1; }
  echo "ok   merged PR #$pr into $base"
  git fetch -q origin
  for b in "${branches[@]}"; do   # merged task branches leave origin, unmerged ones stay
    { [ "$b" = "$base" ] || [ "$b" = "$into" ]; } && continue
    git rev-parse -q --verify "origin/$b" >/dev/null || continue
    git merge-base --is-ancestor "origin/$b" "origin/$base" || continue
    if git push -q origin --delete "$b" 2>/dev/null; then echo "ok   deleted origin/$b"; else echo "WARN could not delete origin/$b"; fi
  done
  if [ -n "$release" ]; then
    git fetch -q origin
    local last notes
    last="$(git describe --tags --abbrev=0 "origin/$base" 2>/dev/null)"
    notes="$(git log --no-merges --format='- %s' ${last:+"$last.."}"origin/$base")"
    gh release create "$release" --target "$base" --title "$release" --notes "$notes" >/dev/null 2>&1 || { echo "FAIL gh release create $release"; return 1; }
    echo "ok   release $release"
    ship_install "$base"
  fi
  echo "SHIPPED PR #$pr"
}
