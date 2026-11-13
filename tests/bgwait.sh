#!/usr/bin/env bash
# An agent that ends its turn to wait for its own background command (run_in_background, no warmd run) has not stopped:
# the SubagentStop of that turn records nothing, so the batch does not end and the automatic merge never takes the
# half-done branch while the other tasks finish. Driven by hook JSON as Claude Code sends it. No network.
set -u
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WARMD="$HERE/bin/warmd"
TMP="$(mktemp -d)"
# One path form on Windows: long names, no /tmp mount. A runner TEMP like RUNNER~1 otherwise differs from what git reports
command -v cygpath >/dev/null 2>&1 && TMP="$(cygpath -u "$(cygpath -l -m "$TMP")")"
export XDG_CACHE_HOME="$TMP/cache" AUTO_EVERY=0 WARMD_TRANSCRIPTS="$TMP/transcripts"
fails=0
ok() { echo "ok   $1"; }
no() { echo "FAIL $1"; fails=$((fails+1)); }
PY=python3; "$PY" -c 'import json' >/dev/null 2>&1 || PY=python
. "$HERE/lib/platform.sh"
jstr() { "$PY" -c 'import json,sys; print(json.dumps(sys.argv[1]))' "$1"; }
# A detached job gets 20 s, then the test fails fast and shows the job logs instead of waiting for the CI timeout
waitfor() { local end=$((SECONDS + ${WAIT_MAX:-20})); until eval "$1"; do
  [ $SECONDS -ge $end ] && { echo "  waited ${WAIT_MAX:-20}s for: $1" >&2; tail -n 6 "$C/warmd-hook.log" "$C/warmd-automerge.log" 2>/dev/null | sed 's/^/  /' >&2; return 1; }
  sleep 0.2; done; }

B="$TMP/origin.git"; git init -q --bare "$B"
R="$TMP/repo"; mkdir -p "$R" && cd "$R" && git init -q -b main . && git config core.autocrlf false && git config user.name t && git config user.email t@example.com || exit 1
echo '{ "name": "t", "scripts": { "test": "true" } }' > package.json
printf '.warmd\n' > .gitignore
printf 'gate=true\nmid=sonnet-x\n' > warmd.conf
git add -A && git commit -qm init && git remote add origin "$B" && git push -q -u origin main || exit 1
C="$(git rev-parse --path-format=absolute --git-common-dir)"
W="$(dirname "$R")/.warmd-worktrees/repo"
: >> "$C/warmd-hook.log"
# Two splits, the second while the task of the first is still open: one batch with both tasks
printf 'a | add a | a.txt exists | a.txt\n' > "$TMP/t1.txt"
printf 'b | add b | b.txt exists | b.txt\n' > "$TMP/t2.txt"
WARMD_NO_PREWARM=1 "$WARMD" split "$TMP/t1.txt" > "$TMP/split.out" || no "split 1: $(cat "$TMP/split.out")"
WARMD_NO_PREWARM=1 "$WARMD" split "$TMP/t2.txt" >> "$TMP/split.out" || no "split 2: $(cat "$TMP/split.out")"
[ "$(grep -c . "$C/warmd-batch")" = 2 ] && grep -qx "$W/a" "$C/warmd-batch" && grep -qx "$W/b" "$C/warmd-batch" && ok "a second split while a task is open keeps it in the batch" || no "batch after two splits: $(cat "$C/warmd-batch")"

taskpath() { sed -n "s/^AGENT $1: .*prompt=\"Read \(.*\) and do it.\"/\1/p" "$TMP/split.out"; }
work() { (cd "$W/$1" && echo "$1" > "$2" && git add "$2" && git commit -qm "$1 $2"); }
# transcript <file> <task> <last text> <bg>: bg = open (a background command started, no notification yet),
# closed (its notification arrived), killed (the agent stopped it itself), none
transcript() {
  local u='"usage":{"input_tokens":20,"cache_creation_input_tokens":200,"cache_read_input_tokens":2000,"output_tokens":7}'
  {
    printf '{"type":"user","message":{"role":"user","content":%s}}\n' "$(jstr "Read $(taskpath "$2") and do it.")"
    printf '{"type":"assistant","message":{"id":"m1","content":[{"type":"tool_use","id":"t1","name":"Bash","input":{"command":"true"}}],%s}}\n' "$u"
    printf '{"type":"user","message":{"content":[{"type":"tool_result","tool_use_id":"t1","content":"ok"}]}}\n'
    if [ "$4" != none ]; then
      printf '{"type":"assistant","message":{"id":"m2","content":[{"type":"tool_use","id":"t2","name":"Bash","input":{"command":"bash matrix.sh","run_in_background":true}}],%s}}\n' "$u"
      printf '{"type":"user","message":{"content":[{"type":"tool_result","tool_use_id":"t2","content":[{"type":"text","text":"Command running in background with ID: bkw6lxc89. Output is being written to: C:\\\\Temp\\\\tasks\\\\bkw6lxc89.output. You will be notified when it completes."}]}]}}\n'
      printf '{"type":"assistant","message":{"id":"m3","content":[{"type":"text","text":"Matrix runs in background; waiting for its notification."}],%s}}\n' "$u"
    fi
    if [ "$4" = closed ]; then
      printf '{"type":"user","isMeta":true,"origin":{"kind":"task-notification"},"message":{"role":"user","content":%s}}\n' "$(jstr "[SYSTEM NOTIFICATION - NOT USER INPUT]
<task-notification>
<task-id>bkw6lxc89</task-id>
<tool-use-id>t2</tool-use-id>
<status>completed</status>
<summary>Background command completed (exit code 0)</summary>
</task-notification>")"
    fi
    if [ "$4" = killed ]; then
      printf '{"type":"assistant","message":{"id":"m4","content":[{"type":"tool_use","id":"t3","name":"KillShell","input":{"shell_id":"bkw6lxc89"}}],%s}}\n' "$u"
      printf '{"type":"user","message":{"content":[{"type":"tool_result","tool_use_id":"t3","content":"killed"}]}}\n'
    fi
    [ -z "$3" ] || printf '{"type":"assistant","message":{"id":"m9","content":[{"type":"text","text":%s}],%s}}\n' "$(jstr "$3")" "$u"
  } > "$1"
}
N=0
stop() { # name, last text, bg: the SubagentStop for that agent, then wait until its detached job logged the stop
  N=$((N+1)); local t="$TMP/$1-$N.jsonl" n
  n="$(grep -c " $1 stopped: " "$C/warmd-hook.log" 2>/dev/null)"; n=$(( ${n:-0} + 1 ))
  transcript "$t" "$1" "$2" "$3"
  printf '{"session_id":"s1","hook_event_name":"SubagentStop","agent_id":"x","agent_transcript_path":"%s"}' "$(native_path "$t")" | "$WARMD" hook-subagent
  waitfor "[ \"\$(grep -c ' $1 stopped: ' '$C/warmd-hook.log' 2>/dev/null)\" -ge $n ]" || no "job for $1 never ran: $(tail -3 "$C/warmd-hook.log" 2>&1)"
}
jobs_gone() { waitfor '[ -z "$(ls "$C"/warmd-job-*.sh 2>/dev/null)" ]'; sleep 1; }
finished() { grep -qF "$W/$1	" "$C/warmd-batch-done" 2>/dev/null; }

# ---- a waits for its own background command: its turn ended, the task did not ----
work a mid.txt
stop a "" open
jobs_gone
grep -q ' a: its own background command still runs (bkw6lxc89), no stop recorded' "$C/warmd-hook.log" && ok "a turn that ends waiting for a background command is logged as waiting" || no "hook log: $(tail -3 "$C/warmd-hook.log")"
finished a && no "the waiting agent counts as finished: $(cat "$C/warmd-batch-done")" || ok "the waiting agent is not finished"
[ ! -e "$C/warmd-auto/paused/a" ] && [ ! -e "$C/warmd-auto/done/a" ] && ok "no pause and no done mark for the waiting agent" || no "marks left for a: $(ls "$C/warmd-auto/paused" "$C/warmd-auto/done" 2>&1)"
grep -q "	a	" "$C/warmd-ledger.tsv" 2>/dev/null && no "the waiting agent got a ledger row" || ok "no ledger row for a turn that only waits"

# ---- the other task finishes meanwhile: no merge, the batch stays open ----
work b b.txt
stop b "DONE warmd/b" open   # declared DONE: a background command it left behind does not hold the task open
waitfor 'finished b' && ok "a DONE with a background command left behind still counts as finished" || no "b not finished: $(tail -3 "$C/warmd-hook.log")"
jobs_gone
[ -s "$C/warmd-batch" ] && grep -qx "$W/a" "$C/warmd-batch" && ok "the batch stays open while a waits" || no "batch ended: $(cat "$C/warmd-batch" 2>&1)"
[ ! -f "$R/mid.txt" ] && [ ! -f "$R/b.txt" ] && [ ! -f "$C/warmd-automerge.log" ] && ok "no automatic merge while a task is open" || no "merged with a open: $(cat "$C/warmd-automerge.log" 2>&1)"
out="$(cd "$R" && "$WARMD" watch --once 2>&1)"
echo "$out" | grep -qE 'batch ended|no batch running' && no "watch says the batch is over: $out" || ok "warmd watch does not report the batch as over"

# ---- the notification arrived, a went on and finished: now the batch ends and both branches merge ----
work a a.txt
stop a "DONE warmd/a" closed
waitfor 'finished a' && ok "after the notification the stop is recorded" || no "a not finished: $(tail -3 "$C/warmd-hook.log")"
waitfor '[ -f "$C/warmd-automerge.log" ] && grep -q "^OK batch ended" "$C/warmd-automerge.log"' || no "automerge never ended: $(cat "$C/warmd-automerge.log" 2>&1)"
[ -f "$R/mid.txt" ] && [ -f "$R/a.txt" ] && [ -f "$R/b.txt" ] && ok "the last real stop merged both branches, a with its whole work" || no "not merged: $(cat "$C/warmd-automerge.log" 2>&1)"
[ ! -f "$C/warmd-batch" ] && ok "the batch ended" || no "batch left: $(cat "$C/warmd-batch")"

# ---- a background command the agent stopped itself is not waited for ----
printf 'c | add c | c.txt exists | c.txt\n' > "$TMP/t3.txt"
WARMD_NO_PREWARM=1 "$WARMD" split "$TMP/t3.txt" >> "$TMP/split.out" || no "split 3: $(tail -2 "$TMP/split.out")"
work c c.txt
stop c "All good." killed
waitfor 'finished c' && ok "a killed background command does not hold the stop back" || no "c not finished: $(tail -3 "$C/warmd-hook.log")"

[ $fails = 0 ] && echo "bgwait: all ok" || { echo "bgwait: $fails failed"; exit 1; }
