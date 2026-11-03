#!/usr/bin/env bash
# End to end: warmd runs a whole batch alone. Real claude -p with haiku, two tasks (one green, one that breaks a test).
# After the batch starts, no warmd command is typed: the hooks must record tokens, push, merge and end the batch.
# Skips with a clear line when claude is not on PATH. Waits for 15% free RAM first, agents run one after another. Needs python3 or python (hooks), 5 to 15 minutes.
set -u
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WARMD="$HERE/bin/warmd"
command -v claude >/dev/null 2>&1 || { echo "SKIP e2e: claude is not on PATH"; exit 0; }
TMP="$(mktemp -d)"; export XDG_CACHE_HOME="$TMP/cache"
KEEP="${E2E_KEEP:-0}"; WAIT="${E2E_WAIT:-300}"
fails=0
ok() { echo "ok   $1"; }
no() { echo "FAIL $1"; fails=$((fails+1)); }
# the live session leaves its transcripts under ~/.claude/projects/<mangled path>: removed with the rest
cleanup() { [ "$KEEP" = 1 ] && { echo "kept $TMP"; return; }; rm -rf "$TMP" "$HOME"/.claude/projects/*"$(basename "$TMP" | tr '.' '-')"-app 2>/dev/null; }
trap cleanup EXIT

# ---- sample project with a local bare remote ----
git init -q --bare "$TMP/remote.git"
mkdir "$TMP/app"; cd "$TMP/app" || exit 1
git init -q -b main .; git config user.name e2e; git config user.email e2e@example.com
git remote add origin "$TMP/remote.git"
cat > sub.sh <<'X'
sub() { echo $(( $1 - $2 )); }
X
cat > t_sub.sh <<'X'
. ./sub.sh
[ "$(sub 9 4)" = 5 ] || { echo "FAIL sub 9 4 gave $(sub 9 4)"; exit 1; }
X
cat > test.sh <<'X'
rc=0
for t in t_*.sh; do sh "$t" || rc=1; done
[ $rc = 0 ] && echo "OK all tests"
exit $rc
X
printf 'test=sh test.sh\n' > warmd.conf
printf '.warmd/\n.claude/\n' > .gitignore
git add -A && git commit -qm base && git push -q -u origin main
[ "$(sh test.sh)" = "OK all tests" ] && ok "sample project starts green" || no "sample project starts red"

# ---- init with hooks, split ----
out="$("$WARMD" init 2>&1)"
echo "$out" | grep -q 'hooks installed' && ok "init installs the hooks" || no "init: $(echo "$out" | tail -2)"
grep -q hook-subagent .claude/settings.local.json 2>/dev/null && ok "SubagentStop hook is in the settings" || no "no SubagentStop hook"
out="$("$WARMD" split "$HERE/tests/e2e/tasks.txt" 2>&1)"
echo "$out" | grep -q 'OK 2 tasks split' && ok "split makes 2 tasks" || no "split: $(echo "$out" | head -3)"
lines="$(echo "$out" | grep '^AGENT ')"
[ "$(echo "$lines" | grep -c .)" = 2 ] || { no "no 2 AGENT lines"; echo "$out" | head; exit 1; }
# haiku for both, whatever the tier router said
lines="$(echo "$lines" | sed -E 's/model=[a-z0-9.-]+/model=haiku/; s/subagent_type=[a-z-]+/subagent_type=warmd-worker/')"

# ---- one live claude session starts the agents one after another ----
COMMON="$(git rev-parse --path-format=absolute --git-common-dir)"
# The session must outlive the detached automerge: claude -p ending kills the hook's children on Windows (gap, see shared brief).
# So the main session waits with a plain shell loop, no warmd command, until the batch file is gone.
keep="n=0; while [ -f '$COMMON/warmd-batch' ] && [ \$n -lt 570 ]; do sleep 5; n=\$((n+5)); done"
prompt="Start these two subagents with the Task/Agent tool ONE AFTER ANOTHER, never in parallel: start the first, wait until it has finished, then start the second. Use exactly the subagent_type, model and prompt of each line.
$lines
When both have finished, run this Bash command once with timeout 600000 and wait for it: $keep
Then reply with the word DONE and nothing else."
# Never start a live run on a starved machine: wait until tune_wait_ram sees ram_free_min (default 15) percent free, no 'run anyway'.
ramwait() { ( WARMD_HOME="$HERE"; . "$HERE/lib/platform.sh"; . "$HERE/lib/core.sh"; . "$HERE/lib/tune.sh"
  t=0; until [ "$(tune_free_pct)" -ge "${CFG_ram_free_min:-15}" ]; do [ $t -ge "${E2E_RAM_WAIT:-3600}" ] && return 1; WARMD_RAM_WAIT=60 tune_wait_ram >/dev/null; t=$((t+60)); done ) }
echo "live: waiting for 15% free RAM before claude -p"
ramwait || { no "RAM stayed under 15% free for ${E2E_RAM_WAIT:-3600}s, live run not started"; exit 1; }
# no --no-session-persistence: without the agent transcripts SubagentStop has no tokens and does nothing
echo "live: claude -p haiku, agents one after another, this takes several minutes"
t0=$SECONDS
echo "$prompt" | timeout 1200 claude -p --model haiku --permission-mode bypassPermissions > "$TMP/claude.out" 2>&1
echo "claude exit $?, $((SECONDS - t0))s: $(tail -n 2 "$TMP/claude.out" | tr '\n' ' ' | cut -c1-160)"
# ---- from here on no warmd command typed by hand: only watch the hooks work ----
n=0; while [ -f "$COMMON/warmd-batch" ] && [ $n -lt "$WAIT" ]; do sleep 2; n=$((n+2)); done
[ -f "$COMMON/warmd-batch" ] && no "batch still open after ${WAIT}s: $(tail -3 "$COMMON/warmd-hook.log" 2>/dev/null)" || ok "batch ended by itself"

led="$COMMON/warmd-ledger.tsv"
for t in mulfn brksub; do
  row="$(awk -F'\t' -v t="$t" '$2==t' "$led" 2>/dev/null | tail -1)"
  tok="$(echo "$row" | cut -f5)"
  case "$tok" in ''|-|*[!0-9]*) no "ledger $t: no real tokens (row: ${row:-none})";; *) [ "$tok" -gt 0 ] && ok "ledger $t: $tok real tokens" || no "ledger $t: 0 tokens";; esac
done
for t in mulfn brksub; do
  git ls-remote --exit-code --heads origin "warmd/$t" >/dev/null 2>&1 && ok "warmd/$t pushed to the remote" || no "warmd/$t not on the remote"
done
git ls-files | grep -q '^mul.sh$' && [ "$(git log --oneline | grep -c 'Merge warmd/mulfn')" = 1 ] && ok "green branch merged into main" || no "green branch not merged"
[ "$(git log --oneline | grep -c 'Merge warmd/brksub')" = 0 ] && [ "$(sh sub.sh >/dev/null 2>&1; . ./sub.sh; sub 9 4)" = 5 ] && ok "red branch rolled back" || no "red branch is in main"
[ -z "$(git status --porcelain -uno)" ] && [ -z "$(git rev-parse -q --verify MERGE_HEAD)" ] && ok "main checkout clean" || no "main checkout dirty or mid-merge"
sh test.sh >/dev/null 2>&1 && ok "main is green" || no "main is red"
grep -E '^(OK|FAIL|SKIP|WAIT)' "$COMMON/warmd-automerge.log" "$COMMON/warmd-automerge.log.seen" 2>/dev/null | head -8

echo
[ $fails = 0 ] && echo "e2e green" || echo "e2e: $fails failed (E2E_KEEP=1 keeps $TMP)"
[ $fails = 0 ]
