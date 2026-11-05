#!/usr/bin/env bash
# Hook self-test: real hook JSON in, rewritten command out; warmd run with byte counts; install and remove in a throwaway repo;
# a whole batch driven only by SubagentStop and SessionStart: ledger, push to a local bare origin, automatic merge. No network.
set -u
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WARMD="$HERE/bin/warmd"
FIX="$HERE/tests/fixtures/digest"
TMP="$(mktemp -d)"
# One path form on Windows: long names, no /tmp mount. A runner TEMP like RUNNER~1 otherwise differs from what git reports
command -v cygpath >/dev/null 2>&1 && TMP="$(cygpath -u "$(cygpath -l -m "$TMP")")"
export XDG_CACHE_HOME="$TMP/cache"
fails=0
ok() { echo "ok   $1"; }
no() { echo "FAIL $1"; fails=$((fails+1)); }
PY=python3; "$PY" -c 'import json' >/dev/null 2>&1 || PY=python

# hook input as Claude Code sends it (PreToolUse, Bash)
pre_json() { printf '{"session_id":"abc123","transcript_path":"/tmp/t.jsonl","cwd":"%s","permission_mode":"default","hook_event_name":"PreToolUse","tool_name":"Bash","tool_input":{"command":%s,"description":"run it"},"tool_use_id":"toolu_01"}' "$TMP" "$1"; }
jstr() { "$PY" -c 'import json,sys; print(json.dumps(sys.argv[1]))' "$1"; }
pre() { pre_json "$(jstr "$1")" | "$WARMD" hook-pre; }
updated() { printf '%s' "$1" | "$PY" -c 'import json,sys; print(json.load(sys.stdin)["hookSpecificOutput"]["updatedInput"]["command"])'; }

# ---- PreToolUse: known commands are wrapped, everything else stays untouched ----
for c in "npm test" "cargo build --release" "pytest -x tests/test_a.py" "dotnet test --no-build" "go test ./..." "make"; do
  out="$(pre "$c")"
  got="$(updated "$out" 2>/dev/null)"
  case "$got" in *" run -- $c") ok "wrapped: $c";; *) no "not wrapped: $c -> $out";; esac
done
for c in "ls -la" "git status" "npm test | tee out.txt" "cargo test && echo done" "npm run dev" "npm test -- --watch" "echo \"hi\"" "rm -rf build" "cat tests/a.log" "warmd test"; do
  out="$(pre "$c")"
  [ -z "$out" ] && ok "left alone: $c" || no "touched: $c -> $out"
done
out="$(pre_json '"npm test\nnpm run build"' | "$WARMD" hook-pre)"
[ -z "$out" ] && ok "left alone: multi-line command" || no "touched multi-line: $out"
out="$(printf '{"hook_event_name":"PreToolUse","tool_name":"Read","tool_input":{"file_path":"npm test"}}' | "$WARMD" hook-pre)"
[ -z "$out" ] && ok "left alone: other tool" || no "touched other tool: $out"
printf 'not json at all' | "$WARMD" hook-pre >/dev/null; [ $? = 0 ] && ok "garbage input exits 0" || no "garbage input fails"

# ---- warmd run: short output, exit code, raw log ----
for r in vitest pytest cargo go dotnet; do
  f="$FIX/$r.log"
  raw=$(wc -c < "$f")
  out="$("$WARMD" run -- sh -c "cat '$f'; exit 1")"; rc=$?
  new=$(printf '%s\n' "$out" | wc -c)
  [ "$rc" = 1 ] && ok "$r exit code kept" || no "$r exit code $rc"
  if [ "$(wc -l < "$f")" -le 20 ]; then   # short logs pass through whole, nothing is lost
    printf '%s\n' "$out" | grep -qF "$(head -1 "$f")" && ok "$r short log passes through ($raw B)" || no "$r short log changed"
    continue
  fi
  [ "$new" -lt "$raw" ] && printf '     %-7s before %5d B  after %4d B (%d%% less)\n' "$r" "$raw" "$new" $(( (raw - new) * 100 / raw )) || no "$r not smaller"
  [ $(( (raw - new) * 100 / raw )) -ge 70 ] && ok "$r saves at least 70%" || no "$r saves less than 70%"
  log="$(printf '%s' "$out" | sed -n 's/.*raw log //p' | head -1)"
  [ -f "$log" ] && cmp -s "$log" "$f" && ok "$r raw log kept byte for byte" || no "$r raw log missing or changed"
done
out="$("$WARMD" run -- sh -c 'seq 1 500; exit 0')"; rc=$?
[ "$rc" = 0 ] && echo "$out" | head -1 | grep -q '^OK exit 0, 500 lines' && ok "green run: one OK line" || no "green run: $out"
[ "$(echo "$out" | wc -l)" -le 5 ] && ok "green run output short" || no "green run output long"
out="$("$WARMD" run -- sh -c 'echo hi; exit 3')"; rc=$?
[ "$rc" = 3 ] && [ "$out" = "$(printf 'hi\nFAIL exit 3')" ] && ok "short output passes through" || no "short output changed: rc=$rc $out"
"$WARMD" run -- >/dev/null; [ $? = 2 ] && ok "run without command is usage" || no "run without command"

# ---- init --hooks / --no-hooks ----
mkdir -p "$TMP/proj/.claude"; cd "$TMP/proj" && git init -q -b main . || exit 1
S="$TMP/proj/.claude/settings.local.json"
echo '{"permissions":{"allow":["Bash(ls)"]},"hooks":{"PreToolUse":[{"matcher":"Edit","hooks":[{"type":"command","command":"./mine.sh"}]}]}}' > "$S"
before=$(cat "$S")
out="$("$WARMD" init --hooks)"; echo "$out" | grep -q '^OK' && ok "init --hooks" || no "init --hooks: $out"
"$PY" - "$S" <<'PYEOF' && ok "settings has all three hooks and keeps the user's" || no "settings content wrong"
import json, sys
d = json.load(open(sys.argv[1]))
pre = d["hooks"]["PreToolUse"]; ses = d["hooks"]["SessionStart"]; sub = d["hooks"]["SubagentStop"]
assert d["permissions"]["allow"] == ["Bash(ls)"]
assert any(g["matcher"] == "Edit" for g in pre)
assert any(g["matcher"] == "Bash|Agent|Task" and g["hooks"][0]["command"].endswith(" hook-pre") for g in pre)
assert "matcher" not in ses[0] and ses[0]["hooks"][0]["command"].endswith(" hook-session")
assert sub[0]["hooks"][0]["command"].endswith(" hook-subagent")
PYEOF
"$WARMD" init --hooks >/dev/null
[ "$(grep -c 'hook-pre' "$S")" = 1 ] && ok "second init --hooks adds no duplicate" || no "duplicate hook entries"
# hooks of an older warmd (PreToolUse only on Bash) are renewed at session start, once
"$PY" - "$S" <<'PYEOF'
import json, sys
d = json.load(open(sys.argv[1]))
for g in d["hooks"]["PreToolUse"]:
    if g["hooks"][0]["command"].endswith(" hook-pre"): g["matcher"] = "Bash"
json.dump(d, open(sys.argv[1], "w"), indent=2)
PYEOF
out="$(cd "$TMP/proj" && printf '{"source":"startup"}' | "$WARMD" hook-session)"
grep -q '"matcher": "Bash|Agent|Task"' "$S" && [ "$(grep -c 'hook-pre' "$S")" = 1 ] && echo "$out" | grep -q renewed   && ok "old Bash-only hooks renewed at session start" || no "old hooks not renewed: $out"
out="$(cd "$TMP/proj" && printf '{"source":"startup"}' | "$WARMD" hook-session)"
echo "$out" | grep -q renewed && no "current hooks renewed again" || ok "current hooks left alone"
"$WARMD" init --no-hooks >/dev/null
out="$(cd "$TMP/proj" && printf '{"source":"startup"}' | "$WARMD" hook-session)"
grep -q 'hook-pre' "$S" 2>/dev/null && no "session start added removed hooks back" || ok "removed hooks stay removed"
"$PY" -c 'import json,sys; assert json.load(open(sys.argv[1])) == json.loads(sys.argv[2])' "$S" "$before" && ok "init --no-hooks restores the file" || no "remove changed more than ours"
rm "$S"; "$WARMD" init --hooks >/dev/null; "$WARMD" init --no-hooks >/dev/null
[ ! -e "$S" ] && ok "remove deletes a file that held only our hooks" || no "empty settings file left"
"$WARMD" init --no-hooks | grep -q '^OK' && ok "remove with nothing installed is fine" || no "remove with nothing installed"
[ -z "$(git status --short -- . ':!.claude')" ] && ok "init --hooks touches nothing outside .claude" || no "init touched other files"

# ---- SessionStart compact: task and brief come back ----
M="$TMP/main"; mkdir -p "$M/.warmd/tasks"; cd "$M" && git init -q -b main . && git config user.name t && git config user.email t@example.com && git commit -q --allow-empty -m i || exit 1
git worktree add -q "$TMP/wt" -b w1 && git worktree add -q "$TMP/wt2" -b w2
. "$HERE/lib/platform.sh"
printf 'Task one. First run: cd "%s". Every command of this task runs there.\nGoal: build the thing\n' "$(native_path "$(cd "$TMP/wt" && pwd)")" > "$M/.warmd/tasks/one.md"
printf '# Shared brief\nFinding: x is in y.c:4\n' > "$M/.git/warmd-shared.md"
out="$(cd "$TMP/wt" && printf '{"hook_event_name":"SessionStart","source":"compact"}' | "$WARMD" hook-session)"
echo "$out" | grep -q 'Goal: build the thing' && echo "$out" | grep -q 'Finding: x is in y.c:4' && ok "compact restores task and shared brief" || no "compact output: $out"
printf '     compact reinjection %s B\n' "$(printf '%s\n' "$out" | wc -c)"
out="$(cd "$TMP/wt2" && printf '{}' | "$WARMD" hook-session)"
[ -z "$out" ] && ok "worktree without a task gets nothing" || no "foreign worktree got: $out"
out="$(cd "$TMP" && printf '{}' | "$WARMD" hook-session)"; [ $? = 0 ] && [ -z "$out" ] && ok "outside a repo: silent" || no "outside a repo: $out"

out="$(cd "$TMP/wt" && printf '{"hook_event_name":"SessionStart","source":"startup"}' | "$WARMD" hook-session)"
echo "$out" | grep -q 'session startup' && echo "$out" | grep -q 'Goal: build the thing' && ok "restart restores the task too" || no "restart output: $out"

# ---- a whole batch without one typed warmd command: split, agents stop, ledger, push, automatic merge ----
ms() { date +%s%N | cut -c1-13; }
fast() { # name, ms -> the hook returned within 2 s
  [ "$2" -lt 2000 ] && ok "$1 returns in $2 ms" || no "$1 took $2 ms, the limit is 2000"
}
# A detached job gets 20 s, then the test fails fast and shows the job logs instead of waiting for the CI timeout
waitfor() { local end=$((SECONDS + ${WAIT_MAX:-20})); until eval "$1"; do
  [ $SECONDS -ge $end ] && { echo "  waited ${WAIT_MAX:-20}s for: $1" >&2; tail -n 6 "$C/warmd-hook.log" "$C/warmd-automerge.log" 2>/dev/null | sed 's/^/  /' >&2; return 1; }
  sleep 0.2; done; }
B="$TMP/origin.git"; git init -q --bare "$B"
R="$TMP/repo"; mkdir -p "$R" && cd "$R" && git init -q -b main . && git config core.autocrlf false && git config user.name t && git config user.email t@example.com || exit 1
echo '{ "name": "t", "scripts": { "test": "true" } }' > package.json
printf '.warmd\n' > .gitignore
printf '[ ! -f red ]\n' > gate.sh; printf 'gate=sh gate.sh\nmid=sonnet-x\n' > warmd.conf
git add -A && git commit -qm init && git remote add origin "$B" && git push -q -u origin main || exit 1
printf 'a | add a | a.txt exists | a.txt\nb | add b | b.txt exists | b.txt\nc | add c | c.txt exists | c.txt\nd | add d | d.txt exists | d.txt\n' > "$TMP/tasks.txt"
WARMD_NO_PREWARM=1 "$WARMD" split "$TMP/tasks.txt" > "$TMP/split.out" || no "split: $(cat "$TMP/split.out")"
C="$(git rev-parse --path-format=absolute --git-common-dir)"
W="$(dirname "$R")/.warmd-worktrees/repo"
taskpath() { sed -n "s/^AGENT $1: .*prompt=\"Read \(.*\) and do it.\"/\1/p" "$TMP/split.out"; }
work() { (cd "$W/$1" && echo "$1" > "$2" && git add "$2" && git commit -qm "$1 $2"); }
transcript() { # file, prompt, last text
  local u='"usage":{"input_tokens":20,"cache_creation_input_tokens":200,"cache_read_input_tokens":2000,"output_tokens":7}'
  {
    printf '{"type":"user","message":{"role":"user","content":%s}}\n' "$(jstr "$2")"
    printf '{"type":"assistant","message":{"id":"m1","content":[{"type":"tool_use","id":"t1","name":"Bash","input":{}}],"usage":{"input_tokens":10,"cache_creation_input_tokens":100,"cache_read_input_tokens":1000,"output_tokens":5}}}\n'
    printf '{"type":"user","message":{"content":[{"type":"tool_result","tool_use_id":"t1","content":"see .warmd/tasks/zz.md"}]}}\n'
    printf 'not json, a torn line\n'
    printf '{"type":"assistant","message":{"id":"m2","content":[{"type":"tool_use","id":"t2","name":"Bash","input":{}}],%s}}\n' "$u"
    printf '{"type":"assistant","message":{"id":"m2","content":[{"type":"text","text":"working"}],%s}}\n' "$u"
    printf '{"type":"user","message":{"content":[{"type":"tool_result","tool_use_id":"t2","content":"ok"}]}}\n'
    printf '{"type":"assistant","message":{"id":"m3","content":[{"type":"text","text":%s}],"usage":{"input_tokens":3,"cache_creation_input_tokens":30,"cache_read_input_tokens":3000,"output_tokens":9}}}\n' "$(jstr "$3")"
  } > "$1"
}
stop() { # name, last text [, prompt]: the SubagentStop the session sends for that agent
  local t="$TMP/$1-$RANDOM.jsonl" t0
  transcript "$t" "${3:-Read $(taskpath "$1") and do it.}" "$2"
  t0=$(ms)
  printf '{"session_id":"s1","transcript_path":"%s","cwd":"%s","hook_event_name":"SubagentStop","stop_hook_active":false,"agent_id":"x","agent_transcript_path":"%s"}' \
    "$(native_path "$TMP/main.jsonl")" "$(native_path "$R")" "$(native_path "$t")" | "$WARMD" hook-subagent
  STOP_RC=$?; STOP_MS=$(( $(ms) - t0 ))
}
L="$C/warmd-ledger.tsv"
row() { grep "	$1	" "$L" 2>/dev/null | cut -f5,6,8; }
pushed() { git --git-dir="$B" rev-parse -q --verify "refs/heads/warmd/$1" >/dev/null; }
[ -n "$(taskpath a)" ] && [ -d "$W/d" ] && ok "split made the batch" || no "split: $(cat "$TMP/split.out")"

work a a.txt
stop a "All done.
DONE warmd/a" > "$TMP/stop.out"; fast "SubagentStop" "$STOP_MS"
[ "$STOP_RC" = 0 ] && [ ! -s "$TMP/stop.out" ] && ok "SubagentStop prints nothing and exits 0" || no "SubagentStop rc=$STOP_RC out=$(cat "$TMP/stop.out")"
waitfor 'grep -qF "$W/a	" "$C/warmd-batch-done" 2>/dev/null' || no "job for a never finished: $(tail -3 "$C/warmd-hook.log")"
[ "$(row a)" = "$(printf '6384\t2\tok')" ] && ok "ledger sums tokens over all 3 turns, a turn split in 2 lines once, and counts calls" || no "ledger row a: $(row a), want 6384 = 1115 + 2227 + 3042"
if [ "$OS" = win ]; then grep -q ' a stopped: .*(detached via cim)' "$C/warmd-hook.log" && ok "job started through Win32_Process.Create, outside the session's tree" || no "job not via cim: $(grep ' a stopped' "$C/warmd-hook.log")"; fi
waitfor '[ -z "$(ls "$C"/warmd-job-*.sh 2>/dev/null)" ]' && ok "job script removed after the run" || no "job script left: $(ls "$C"/warmd-job-*.sh)"
pushed a && ok "branch of a pushed" || no "a not pushed: $(tail -3 "$C/warmd-hook.log")"
[ -s "$C/warmd-batch" ] && [ ! -f "$R/a.txt" ] && ok "first of four stops: no merge yet" || no "merged too early"

touch -d "-5 hours" "$C/warmd-batch"
t0=$(ms); out="$(cd "$R" && printf '{"hook_event_name":"SessionStart","source":"startup"}' | "$WARMD" hook-session)"; fast "SessionStart" $(( $(ms) - t0 ))
[ -n "$(find "$C/warmd-batch" -mmin -1)" ] && ok "restart with open agents renews an old batch marker" || no "old batch marker not renewed"
echo "$out" | grep -q 'agents of the old session are gone' && echo "$out" | grep -q '^- warmd/a: done (ok), 1 ahead' && echo "$out" | grep -q '^- warmd/b: open' && ok "restart shows the batch state" || no "batch state: $out"
echo "$out" | grep -qF "AGENT b: subagent_type=warmd-worker model=sonnet-x prompt=\"Read $(taskpath b) and do it. State: warmd/b at" && ! echo "$out" | grep -q 'AGENT a:' && ok "restart gives AGENT lines for the open tasks only" || no "AGENT lines: $out"
echo "$out" | grep -q '^3 of 4 open' && ok "open count" || no "open count: $out"
out="$(cd "$R" && printf '{"source":"compact"}' | "$WARMD" hook-session)"
echo "$out" | grep -q 'agents may still run' && ok "compact warns that agents may still run" || no "compact batch: $out"
printf '## Handoff 1\nDone: half of b\n' > "$C/warmd-handoff/b.md"
out="$(cd "$W/b" && printf '{"source":"compact"}' | "$WARMD" hook-session)"
echo "$out" | grep -q '^Goal: add b' && echo "$out" | grep -q 'Done: half of b' && echo "$out" | grep -q '^- d: d.txt' && ok "batch worktree gets task, handoff note and brief" || no "worktree b: $out"
out="$(cd "$R" && printf '{}' | "$WARMD" hook-session)"
echo "$out" | grep -qF "Read $(taskpath b), then " && ok "open task with a handoff note continues from it" || no "handoff AGENT: $out"
rm "$C/warmd-handoff/b.md"

work d d1.txt
stop d "Half done.
AGENT d: subagent_type=warmd-worker model=sonnet prompt=\"Read x and continue\""
waitfor 'pushed d' && ok "handoff: branch pushed" || no "handoff not pushed"
waitfor 'grep -q " d stopped: handoff" "$C/warmd-hook.log"'
[ -z "$(row d)" ] && ! grep -qF "$W/d	" "$C/warmd-batch-done" && ok "handoff is not done and not in the ledger" || no "handoff counted as done"
waitfor 'grep -q "OK nothing warm" "$C/warmd-hook.log"' && ok "a stopped agent's engine is stopped" || no "engine left warm: $(tail -3 "$C/warmd-hook.log")"

stop zz "ok" "Find where foo is defined" > "$TMP/stop.out"; [ "$STOP_RC" = 0 ] && [ ! -s "$TMP/stop.out" ] && ok "agent without a warmd task: nothing" || no "foreign agent: $(cat "$TMP/stop.out")"
out="$(printf 'garbage' | "$WARMD" hook-subagent)"; [ $? = 0 ] && [ -z "$out" ] && ok "SubagentStop garbage: exit 0" || no "garbage: $out"
out="$(printf '{"agent_transcript_path":"%s"}' "$(native_path "$TMP/none.jsonl")" | "$WARMD" hook-subagent)"; [ $? = 0 ] && [ -z "$out" ] && ok "SubagentStop missing transcript: exit 0" || no "missing transcript: $out"
grep -q 'zz' "$C/warmd-hook.log" && no "a job ran for a foreign agent" || ok "no job for foreign agents"

work b red; work c c.txt; work d d.txt
stop b "DONE warmd/b"; stop c "Tried twice.
ESCALATE: the API is missing"
waitfor '[ "$(wc -l < "$C/warmd-batch-done")" = 3 ]'
[ -s "$C/warmd-batch" ] && [ ! -f "$R/a.txt" ] && ok "three of four stopped: still no merge" || no "merged before the last agent"
stop d "DONE warmd/d"
waitfor '[ -f "$C/warmd-automerge.log" ] && grep -qE "^(OK|STOP) .*batch" "$C/warmd-automerge.log"' || no "automerge never ended: $(tail -5 "$C/warmd-hook.log")"
[ "$(row c)" = "$(printf '6384\t2\tescalated')" ] && ok "escalation recorded" || no "ledger c: $(row c)"
[ -f "$R/a.txt" ] && [ -f "$R/d.txt" ] && [ -f "$R/d1.txt" ] && ok "last stop merged the green branches" || no "not merged: $(cat "$C/warmd-automerge.log")"
[ ! -f "$R/red" ] && grep -q '^FAIL merge warmd/b' "$C/warmd-automerge.log" && ok "red branch rolled back" || no "red branch: $(cat "$C/warmd-automerge.log")"
[ -z "$(git -C "$R" status --porcelain -uno)" ] && ! git -C "$R" rev-parse -q --verify MERGE_HEAD >/dev/null && ok "shared checkout clean after the merges" || no "checkout dirty"
[ ! -f "$R/c.txt" ] && grep -q '^WAIT warmd/c' "$C/warmd-automerge.log" && [ "$(cat "$C/warmd-batch")" = "$W/c" ] && ok "escalated task stays in the batch, unmerged" || no "escalated: $(cat "$C/warmd-batch")"
[ "$(git -C "$R" log -1 --format=%s)" = "Merge warmd/d" ] && ok "merges are commits of warmd merge" || no "last commit: $(git -C "$R" log -1 --format=%s)"
out="$(cd "$R" && printf '{}' | "$WARMD" hook-session)"
echo "$out" | grep -q 'last automatic merge' && echo "$out" | grep -q '^- warmd/c: open' && ok "next session sees the merge result" || no "merge result: $out"
out="$(cd "$R" && printf '{}' | "$WARMD" hook-session)"
echo "$out" | grep -q 'last automatic merge' && no "merge result shown twice" || ok "merge result shown once"

stop c "DONE warmd/c"
waitfor '[ ! -f "$C/warmd-batch" ] && [ ! -d "$C/warmd-automerge.lock" ]' && [ -f "$R/c.txt" ] && ok "relaunched escalation merges and ends the batch" || no "batch not ended: $(cat "$C/warmd-automerge.log")"
[ "$(row c)" = "$(printf '6384\t2\tok')" ] && ok "second attempt replaces the row of the same tier" || no "ledger c: $(row c)"
out="$(cd "$R" && printf '{}' | "$WARMD" hook-session)"; out="$(cd "$R" && printf '{}' | "$WARMD" hook-session)"
[ -z "$out" ] && ok "no batch: SessionStart is silent" || no "no batch output: $out"

# lock held by another merge, then a shared checkout that is not ready
(cd "$W/c" && git merge -q main && echo 2 > c2.txt && git add c2.txt && git commit -qm c2)
printf '%s\n' "$W/c" > "$C/warmd-batch"; printf '%s\tok\n' "$W/c" > "$C/warmd-batch-done"; rm -f "$C/warmd-automerge.log"
mkdir "$C/warmd-automerge.lock"
(cd "$R" && "$WARMD" hook-merge)
[ ! -f "$R/c2.txt" ] && [ ! -f "$C/warmd-automerge.log" ] && ok "a held lock means someone else merges" || no "merged under a held lock"
echo 999999 > "$C/warmd-automerge.lock/pid"; echo dirty >> "$R/gate.sh"
(cd "$R" && "$WARMD" hook-merge)
grep -q '^STOP the shared checkout is not ready' "$C/warmd-automerge.log" && [ -s "$C/warmd-batch" ] && [ ! -d "$C/warmd-automerge.lock" ] && ok "lock of a dead merge taken over; dirty shared checkout: batch stays, lock freed" || no "dirty checkout: $(cat "$C/warmd-automerge.log")"
git -C "$R" checkout -q -- gate.sh
(cd "$R" && "$WARMD" hook-merge)
[ -f "$R/c2.txt" ] && [ ! -f "$C/warmd-batch" ] && ok "retry after the fix merges" || no "retry: $(cat "$C/warmd-automerge.log")"

# ---- warmd init installs the hooks by default, --no-hooks removes them, old entries are replaced ----
mkdir -p "$R/.claude"; S2="$R/.claude/settings.local.json"
printf '{"hooks":{"SessionStart":[{"matcher":"compact","hooks":[{"type":"command","command":"/old/bin/warmd hook-session"}]}]}}\n' > "$S2"
out="$(cd "$R" && "$WARMD" init)"
echo "$out" | grep -q '^OK hooks installed' && [ "$(grep -c 'hook-session' "$S2")" = 1 ] && grep -q 'hook-subagent' "$S2" && grep -q 'hook-pre' "$S2" && ! grep -q '/old/bin' "$S2" && ok "warmd init installs all hooks and replaces old ones" || no "init: $out"
(cd "$R" && "$WARMD" init --no-hooks >/dev/null); [ ! -e "$S2" ] && ok "warmd init --no-hooks removes them" || no "no-hooks left: $(cat "$S2")"
cd "$TMP" || exit 1

# ---- path forms: an 8.3 short name and the long name are the same worktree ----
if command -v cygpath >/dev/null 2>&1; then
  mkdir -p "$TMP/a long worktree name"; sn="$(cygpath -u "$(cygpath -s -m "$TMP/a long worktree name")" 2>/dev/null)"
  if [[ $sn == *'~'* ]]; then
    a="$(OS=win; . "$HERE/lib/hook.sh"; hook_abs "$sn"; echo "$REPLY")"; b="$(OS=win; . "$HERE/lib/hook.sh"; hook_abs "$TMP/a long worktree name"; echo "$REPLY")"
    [ "$a" = "$b" ] && ok "short and long name give one path" || no "short name $a, long name $b"
  else ok "8.3 names off on this drive, path form check skipped"; fi
fi

# ---- automatic merge with full=ci: no local gate, warmd ship is queued; work already on origin is skipped ----
M="$TMP/fullci"; mkdir -p "$M"; git init -q --bare -b main "$M/o.git"; git clone -q "$M/o.git" "$M/r" 2>/dev/null
( cd "$M/r" && git config user.name t && git config user.email t@example.com && printf 'test=exit 1\nfull=ci\n' > warmd.conf && printf '.warmd\n' > .gitignore \
  && git add -A && git commit -qm init && git push -q origin main \
  && for n in new old; do git worktree add -q -b "warmd/$n" "$M/$n" main; (cd "$M/$n" && echo "$n" > "$n.txt" && git add -A && git commit -qm "$n"); done \
  && git push -q origin warmd/old && git push -q origin warmd/old:main && git reset -q --hard )   # old is on origin/main, the local main is stale
MC="$(git -C "$M/r" rev-parse --path-format=absolute --git-common-dir)"
printf '%s\n%s\n' "$M/new" "$M/old" > "$MC/warmd-batch"; printf '%s\tok\n%s\tok\n' "$M/new" "$M/old" > "$MC/warmd-batch-done"
(cd "$M/r" && "$WARMD" hook-merge)
mlog="$(cat "$MC/warmd-automerge.log" 2>/dev/null)"
echo "$mlog" | grep -q '^SHIP full=ci, no local merge: warmd/new$' && ok "full=ci: no local merge, the branch goes to ship" || no "full=ci automerge: $mlog"
[ ! -f "$M/r/new.txt" ] && [ "$(git -C "$M/r" log -1 --format=%s)" = init ] && ok "full=ci: the shared checkout stays untouched" || no "full=ci merged locally: $(git -C "$M/r" log -1 --format=%s)"
echo "$mlog" | grep -q '^SKIP warmd/old: already on origin/main$' && ok "a branch already on origin is skipped although the local base is stale" || no "stale base: $mlog"
grep -q 'SHIP batch done, full=ci merges through CI: warmd ship warmd/new' "$MC/warmd-auto/queue" 2>/dev/null && ok "watch gets the ship line" || no "queue: $(cat "$MC/warmd-auto/queue" 2>/dev/null)"

rm -rf "$TMP"
[ "$fails" = 0 ] && echo "ALL OK" || { echo "$fails FAILED"; exit 1; }
