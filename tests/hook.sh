#!/usr/bin/env bash
# Hook self-test: real hook JSON in, rewritten command out; warmd run with byte counts; install and remove in a throwaway repo.
set -u
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WARMD="$HERE/bin/warmd"
FIX="$HERE/tests/fixtures/digest"
TMP="$(mktemp -d)"
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
"$PY" - "$S" <<'PYEOF' && ok "settings has both hooks and keeps the user's" || no "settings content wrong"
import json, sys
d = json.load(open(sys.argv[1]))
pre = d["hooks"]["PreToolUse"]; ses = d["hooks"]["SessionStart"]
assert d["permissions"]["allow"] == ["Bash(ls)"]
assert any(g["matcher"] == "Edit" for g in pre)
assert any(g["matcher"] == "Bash" and g["hooks"][0]["command"].endswith(" hook-pre") for g in pre)
assert ses[0]["matcher"] == "compact" and ses[0]["hooks"][0]["command"].endswith(" hook-session")
PYEOF
"$WARMD" init --hooks >/dev/null
[ "$(grep -c 'hook-pre' "$S")" = 1 ] && ok "second init --hooks adds no duplicate" || no "duplicate hook entries"
"$WARMD" init --no-hooks >/dev/null
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

rm -rf "$TMP"
[ "$fails" = 0 ] && echo "ALL OK" || { echo "$fails FAILED"; exit 1; }
