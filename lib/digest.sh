#!/usr/bin/env bash
# digest_log <file>: boil a red test log down to cause lines. Per failure: the test name, file:line,
# expected and actual. Stack frames, passing tests and banners are dropped.
# Runner is detected from the log itself. Returns 1 and prints nothing when it knows no runner,
# so the caller can fall back to a generic filter.

DIGEST_MAX_FAILS="${DIGEST_MAX_FAILS:-5}"

digest_runner() { # file -> runner name or empty
  local f="$1"
  if grep -qE "panicked at [^ ]+:[0-9]+" "$f"; then echo cargo
  elif grep -qE '^_{3,} .* _{3,}$|^E {2,}[^ ]' "$f"; then echo pytest
  elif grep -qE '^ *Failed [A-Za-z_][^ ]* \[[0-9<]+ ?m?s\]|^ *Error Message:' "$f"; then echo dotnet
  elif grep -qE '^ *--- FAIL: ' "$f"; then echo go
  elif grep -qE '^ *● .+' "$f" && grep -qE '^ *(Expected|Received|at )|expect\(' "$f"; then echo jest
  elif grep -qE '^ *FAIL +[^ ]' "$f" && grep -qE '^ *(❯|×|Failed Tests|AssertionError|Error)' "$f"; then echo vitest
  fi
}

digest_log() {
  local f="$1" runner out
  [ -s "$f" ] || return 1
  runner="$(sed 's/\x1b\[[0-9;]*[A-Za-z]//g' "$f" | tr -d '\r' > "$f.plain"; digest_runner "$f.plain")"
  [ -n "$runner" ] || { rm -f "$f.plain"; return 1; }
  out="$("_digest_$runner" "$f.plain" | cut -c1-160)"
  rm -f "$f.plain"
  [ -n "$out" ] || return 1
  printf '%s\n' "$out"
}

# All parsers cap output at DIGEST_MAX_FAILS failures and say how many were left out.

_digest_vitest() {
  awk -v max="$DIGEST_MAX_FAILS" '
    function trim(s) { sub(/^[ \t]+/, "", s); sub(/[ \t]+$/, "", s); return s }
    /^ *FAIL +[^ ]/ { n++; st = 1; msg = 0; loc = 0; d = 0
      if (n <= max) print "FAIL " trim(substr($0, index($0, "FAIL") + 4)); next }
    n > max || !st { next }
    !msg && /^[A-Za-z]*(Error|Exception)[: ]/ { print trim($0); msg = 1; next }
    /^- Expected/ || /^\+ Received/ { next }
    d < 6 && /^[-+] / && msg { print trim($0); d++; next }
    !loc && /^ *❯ / && !/node_modules/ { l = $0; sub(/^ *❯ +/, "", l); print "at " trim(l); loc = 1; next }
    END { if (n > max) print "(+" n - max " more failures)" }' "$1"
}

_digest_jest() {
  awk -v max="$DIGEST_MAX_FAILS" '
    function trim(s) { sub(/^[ \t]+/, "", s); sub(/[ \t]+$/, "", s); return s }
    /^ *● / && !/Console/ { n++; st = 1; msg = 0; loc = 0
      l = $0; sub(/^ *● +/, "", l); if (n <= max) print "FAIL " trim(l); next }
    n > max || !st { next }
    !msg && NF { if ($0 !~ /^ *(Expected|Received)/) { print trim($0) } msg = 1 }
    /^ *(Expected|Received)/ { print trim($0); next }
    !loc && /^ *at / && !/node_modules|node:internal|<anonymous>/ { print trim($0); loc = 1 }
    END { if (n > max) print "(+" n - max " more failures)" }' "$1"
}

_digest_pytest() {
  awk -v max="$DIGEST_MAX_FAILS" '
    function trim(s) { sub(/^[ \t]+/, "", s); sub(/[ \t]+$/, "", s); return s }
    /^_{3,} .* _{3,}$/ { n++; e = 0; st = 1
      s = $0; gsub(/^_+ | _+$/, "", s); if (n <= max) print "FAIL " s; next }
    /^=+ short test summary/ { st = 0 }
    n > max || !st { next }
    /^E +/ && e < 4 { print trim(substr($0, 2)); e++; next }
    /^[^ ]+:[0-9]+: / { print "at " $0 }
    END { if (n > max) print "(+" n - max " more failures)" }' "$1"
}

_digest_cargo() {
  awk -v max="$DIGEST_MAX_FAILS" '
    function trim(s) { sub(/^[ \t]+/, "", s); sub(/[ \t]+$/, "", s); return s }
    /^---- .* stdout ----$/ { n++; st = 0; s = $0; sub(/^---- /, "", s); sub(/ stdout ----$/, "", s)
      if (n <= max) print "FAIL " s; next }
    n > max { next }
    /panicked at [^ ]+:[0-9]+/ { s = $0; sub(/^.*panicked at /, "", s); sub(/:$/, "", s); print "at " s; st = 1; next }
    st && (/^stack backtrace/ || /^note:/ || /^$/) { st = 0 }
    st { print trim($0) }
    END { if (n > max) print "(+" n - max " more failures)" }' "$1"
}

_digest_go() {
  awk -v max="$DIGEST_MAX_FAILS" '
    function trim(s) { sub(/^[ \t]+/, "", s); sub(/[ \t]+$/, "", s); return s }
    /^ *=== (RUN|PAUSE|CONT)/ { buf = ""; next }
    /^ +[^ ]+\.go:[0-9]+:/ { buf = buf trim($0) "\n"; next }
    /^ *--- FAIL: / { n++; if (n <= max) { s = trim($0); sub(/^--- FAIL: /, "", s); print "FAIL " s; printf "%s", buf }; buf = ""; next }
    /^panic: / && !p { p = 1; print trim($0); next }
    /^[^ ]+\.go:[0-9]+:[0-9]+: / { print $0 }
    END { if (n > max) print "(+" n - max " more failures)" }' "$1"
}

_digest_dotnet() {
  awk -v max="$DIGEST_MAX_FAILS" '
    function trim(s) { sub(/^[ \t]+/, "", s); sub(/[ \t]+$/, "", s); return s }
    /^ *Failed [A-Za-z_][^ ]* \[/ { n++; st = 1; loc = 0; e = 0; m = 0
      s = trim($0); sub(/^Failed /, "", s); sub(/ \[.*$/, "", s); if (n <= max) print "FAIL " s; next }
    /error [A-Z]+[0-9]+:/ && !seen[$0]++ && b++ < 8 { print trim($0); next }
    n > max || !st { next }
    /^ *Error Message:/ { m = 1; next }
    /^ *Stack Trace:/ { m = 0; next }
    /^ *Standard Output/ { st = 0 }
    m && NF && e < 5 { print trim($0); e++; next }
    !loc && /^ *at .* in .*:line [0-9]+/ { s = $0; sub(/^.* in /, "", s); print "at " s; loc = 1 }
    END { if (n > max) print "(+" n - max " more failures)" }' "$1"
}
