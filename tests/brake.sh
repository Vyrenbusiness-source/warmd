#!/usr/bin/env bash
# warmd brake / brakes: the machine-wide brake log. warmd note "BRAKE: ..." lands there too, brakes ranks causes by
# minutes lost, report and finish show the batch's brake minutes in one line. No engine.
set -u
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP="$(mktemp -d)"
export XDG_CACHE_HOME="$TMP/cache"
fails=0
ok() { echo "ok   $1"; }
no() { echo "FAIL $1"; fails=$((fails+1)); }
expect() { if echo "$3" | grep -qE "$2"; then ok "$1"; else no "$1: wanted /$2/, got: $(echo "$3" | head -3)"; fi; }
w() { "$HERE/bin/warmd" "$@" 2>&1; }
LOG="$TMP/cache/warmd/brakes.tsv"

mkdir -p "$TMP/proj"; cd "$TMP/proj" || exit 1
git init -q -b main .; git config user.name t; git config user.email t@example.com
echo x > a.txt; git add a.txt; git commit -qm init; git checkout -qb warmd/lint

expect "brake records a row" '^OK brake recorded' "$(w brake "CI wait for godot" 11 "cache the godot download")"
row="$(tail -n 1 "$LOG" 2>/dev/null)"
expect "row holds project, task, cause, minutes, fix" $'^[0-9]+\tproj\tlint\tCI wait for godot\t11\tcache the godot download$' "$row"
w brake "ci wait for Godot!" "~4 min" >/dev/null
expect "brake without a cause is refused" 'warmd brake "<what>"' "$(w brake "")"

# A BRAKE note goes to the brief and the log, once; without a brief it still lands in the log
common="$(git rev-parse --path-format=absolute --git-common-dir)"
printf '# Shared brief\n\n## Findings\n' > "$common/warmd-shared.md"
out="$(w note "BRAKE: PR conflicted with main | ~3 | merge base before push")"
expect "a BRAKE note is noted in the brief" '^OK noted' "$out"
expect "a BRAKE note lands in the log" $'\tPR conflicted with main\t3\tmerge base before push$' "$(tail -n 1 "$LOG")"
w note "BRAKE: PR conflicted with main | ~3 | merge base before push" >/dev/null
expect "a repeated note is not counted twice" '^1$' "$(grep -c 'PR conflicted' "$LOG")"
w note "plain fact lib/x.sh:3" >/dev/null
expect "a plain note stays out of the log" '^0$' "$(grep -c 'plain fact' "$LOG")"
rm -f "$common/warmd-shared.md"
expect "a BRAKE note without a brief is still recorded" '^OK brake recorded' "$(w note "BRAKE: python stub hung | ~2 | doctor flags it")"

# Ranking: same words in any case or punctuation are one group, ranked by total minutes
out="$(w brakes)"
expect "brakes sums all minutes" '^20 min lost in 4 brakes' "$out"
expect "the top cause groups case and punctuation" '^  15 min  2x  CI wait for godot \(lint\)  fix: cache the godot download' "$(echo "$out" | sed -n 2p)"
expect "the next cause follows" '^   3 min  1x  PR conflicted with main' "$(echo "$out" | sed -n 3p)"
printf '946684800\tproj\told\tancient brake\t99\t-\n' >> "$LOG"
expect "--days leaves old rows out" '^20 min lost' "$(w brakes --days 7)"
expect "without --days old rows count" '^119 min lost' "$(w brakes)"
for i in 1 2 3 4 5 6 7 8 9 10 11; do printf '%s\tproj\tt\tcause number %s %s\t1\t-\n' "$(date +%s)" "$i" "$(printf '%*s' "$i" '' | tr ' ' x)" >> "$LOG"; done
expect "brakes prints the top 10 only" '^11$' "$(w brakes | wc -l | tr -d ' ')"
expect "a bad --days is refused" '^FAIL --days takes a number' "$(w brakes --days x)"

# report shows the brake minutes of the batch, in one line
printf '%s\tlint\tmid\tlib\t100\t5\t60\tok\n' "$(date +%s)" > "$common/warmd-ledger.tsv"
: > "$common/warmd-batch"; touch -d "1 hour ago" "$common/warmd-batch"
expect "report shows the batch brake minutes" '^brakes: 31 min in 15 entries this batch' "$(w report | tail -n 1)"
expect "finish shows the task and batch brake minutes" "brakes: lint 20 min, 31 min in 15 entries this batch" "$(WARMD_BASE=1 w finish | grep "^brakes:")"
rm -f "$common/warmd-batch"


# The PreToolUse hook stops python calls that hang on Windows: the Store stub, python reading a stdin nobody closes,
# a Git Bash /tmp path inside python code. Commands are plain JSON strings here, no python needed to build them.
mkdir -p "$TMP/WindowsApps"; printf '#!/bin/sh\nexit 9\n' > "$TMP/WindowsApps/python3"; chmod +x "$TMP/WindowsApps/python3"
hk() { printf '{"session_id":"b1","transcript_path":"%s/none.jsonl","cwd":"%s","hook_event_name":"PreToolUse","tool_name":"Bash","tool_input":{"command":"%s"}}' "$TMP" "$TMP" "$1" \
  | PATH="$TMP/WindowsApps:$PATH" WARMD_TEST_WIN=1 "$HERE/bin/warmd" hook-pre 2>&1; }
expect "hook denies the Windows Store python stub" 'deny.*python3 is the Windows Store stub' "$(hk 'python3 x.py')"
expect "hook denies python - with no input" 'deny.*reads stdin' "$(hk 'cd /x && python - 2>/dev/null; ls')"
expect "hook denies a Git Bash /tmp path in python code" 'deny.*does not see the Git Bash /tmp' "$(hk "python -c \\\"open('/tmp/a')\\\"")"
expect "hook leaves python with a script alone" '^$' "$(hk 'python x.py')"
expect "hook leaves python fed by a pipe alone" '^$' "$(hk 'cat a.py | python -')"
expect "doctor flags the Windows Store python stub" "WARN python3 is the Windows Store stub" "$(PATH="$TMP/WindowsApps:$PATH" "$HERE/bin/warmd" doctor)"

rm -rf "$TMP" 2>/dev/null
echo; [ $fails = 0 ] && echo "brake: all green" || echo "brake: $fails failed"
exit $fails
