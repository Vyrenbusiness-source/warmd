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

# Waits for the newest run of a branch. Prints one line per job, failing test names on red.
ci_wait() { # branch
  local br="$1" id tries=0
  id="$(ship_run_id "$br")"
  while [ -z "$id" ] && [ $tries -lt "${WARMD_CI_TRIES:-30}" ]; do sleep "${WARMD_CI_POLL:-5}"; tries=$((tries+1)); id="$(ship_run_id "$br")"; done
  [ -n "$id" ] || { echo "FAIL no CI run for $br"; return 1; }
  gh run watch "$id" --exit-status >/dev/null 2>&1; local rc=$?
  gh run view "$id" --json jobs --jq '.jobs[] | "\(.conclusion) \(.name)"' 2>/dev/null | sed 's/^success /ok   /; s/^failure /FAIL /'
  if [ $rc -ne 0 ]; then
    gh run view "$id" --log-failed 2>/dev/null | grep -oE '(FAIL|not ok) [^:]{1,80}' | sort -u | head -15 | sed 's/^/  test /'
    echo "RED run $id"; return 1
  fi
  echo "GREEN run $id"
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
  if [ -n "$release" ]; then
    git fetch -q origin
    local last notes
    last="$(git describe --tags --abbrev=0 "origin/$base" 2>/dev/null)"
    notes="$(git log --no-merges --format='- %s' ${last:+"$last.."}"origin/$base")"
    gh release create "$release" --target "$base" --title "$release" --notes "$notes" >/dev/null 2>&1 || { echo "FAIL gh release create $release"; return 1; }
    echo "ok   release $release"
  fi
  echo "SHIPPED PR #$pr"
}
