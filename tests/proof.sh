#!/usr/bin/env bash
# Public proof: a real Vite and Vitest project, measured on a clean CI machine. Prints Markdown.
set -u
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP="$(mktemp -d)"; cd "$TMP" || exit 1
git init -q -b main .; git config user.name t; git config user.email t@example.com
echo '{ "name": "proof", "private": true, "type": "module", "scripts": { "test": "vitest run" } }' > package.json
mkdir src
for i in 1 2 3 4 5 6 7 8; do
  echo "export const f$i = (n) => n + $i;" > "src/m$i.js"
  printf 'import { expect, test } from "vitest";\nimport { f%s } from "./m%s.js";\ntest("adds", () => expect(f%s(1)).toBe(%s));\n' "$i" "$i" "$i" "$((i+1))" > "src/m$i.test.js"
done
printf 'node_modules\n.warmd\n' > .gitignore
npm i -D vitest --silent --no-fund --no-audit > /dev/null 2>&1
git add -A > /dev/null 2>&1; git commit -qm init
echo '### warmd bench, Vitest project with 8 test files'
echo '```text'
bash "$HERE/bin/warmd" bench
echo '```'
