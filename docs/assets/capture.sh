#!/usr/bin/env bash
# Records the real warmd session shown in hero.html into hero.log, unchanged.
#   bash docs/assets/capture.sh [project dir, default C:/dev/cart-demo]
# Builds a throwaway Node project with one wrong function, runs warmd test (red), fixes the line, runs it again (green)
# and once more with time (answered from the green cache). The project is outside the repo and can be deleted afterwards.
set -u
HERE="$(cd "$(dirname "$0")" && pwd)"; P="${1:-C:/dev/cart-demo}"; LOG="$HERE/hero.log"
rm -rf "$P"; mkdir -p "$P/src" "$P/test"; cd "$P" || exit 1
printf '%s\n' '{ "name": "cart-demo", "version": "1.0.0", "private": true, "type": "module", "scripts": { "test": "node --test" } }' > package.json
printf '%s\n' 'export function count(items) {' '  return items.reduce((acc, it) => acc + 1, 0);' '}' \
  'export function total(items) {' '  return items.reduce((acc, it) => acc + it.qty * it.price, 0);' '}' > src/cart.js
printf '%s\n' 'import { test } from "node:test";' 'import assert from "node:assert/strict";' 'import { count, total } from "../src/cart.js";' \
  'const items = [{ qty: 2, price: 3 }, { qty: 3, price: 1 }];' \
  'test("count adds quantities", () => assert.equal(count(items), 5));' \
  'test("total sums prices", () => assert.equal(total(items), 9));' \
  'test("empty cart", () => assert.equal(count([]), 0));' > test/cart.test.js
date -u +%s > .capture-id  # fresh code key, so an older recording's green cache never answers this one
git init -q && git config core.autocrlf false && git add -A && git -c user.name=demo -c user.email=demo@example.invalid commit -qm init
run() { echo "\$ $*" >> "$LOG"; bash -c "$*" >> "$LOG" 2>&1; }
date -u +"# captured %Y-%m-%dT%H:%M:%SZ, $(warmd --version), node $(node --version), Windows, Git Bash, $P" > "$LOG"
run "npm test 2>&1 | wc -c"
run "warmd test"
sed -i 's/acc + 1, 0/acc + it.qty, 0/' src/cart.js
run "git diff --stat"
run "warmd test"
run "time warmd test"
echo "ok   $LOG"
