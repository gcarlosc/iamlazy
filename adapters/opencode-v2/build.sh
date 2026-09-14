#!/usr/bin/env bash
# Builds iamlazy.ts into a single dependency-free dist/iamlazy.js.
#
# Why this exists at all: the V2 daemon cannot resolve a real npm import
# (`@opencode/plugin`) when it dynamically loads a local plugin file or
# directory -- confirmed against the actual v2.0.1 binary, not assumed from
# docs. Bundling removes every import statement from the deployed file, so
# there is nothing left for the daemon to resolve at load time. See README.md
# in this directory for the full story.
#
# Requires `bun` (https://bun.sh). Not wired into this repo's install.sh or
# test.sh: OpenCode V2 support is still a candidate, not a committed host
# (see DELTAS.md and PROJECT.md), so this stays an explicit, opt-in step.
set -eu
cd "$(dirname "$0")"

if ! command -v bun >/dev/null 2>&1; then
  echo "iamlazy: bun is required to build the OpenCode V2 adapter (https://bun.sh)" >&2
  exit 1
fi

if [ ! -d node_modules ]; then
  echo "installing @opencode/plugin (build-time only; not part of the deployed bundle)"
  bun install
fi

echo "typechecking"
# Only the adapter itself gates a build; iamlazy.test.ts is still covered by
# tsconfig.json for editors, but a test-only type slip should not block
# shipping production code. -p and file arguments cannot be mixed, so this
# repeats tsconfig.json's compiler options explicitly for a single-file check.
./node_modules/.bin/tsc --noEmit --target ESNext --module ESNext --moduleResolution bundler \
  --types bun --strict --skipLibCheck iamlazy.ts

echo "bundling"
mkdir -p dist
bun build iamlazy.ts --target=bun --outfile dist/iamlazy.js

# bun build strips top-level comments, including the `iamlazy-managed` marker
# every other generated file in this project carries. install.sh's write_file
# and uninstall.sh both key off that marker to tell a file this project wrote
# apart from one it must never touch -- without it, a re-run would see an
# unmarked file at the destination and skip it as "not ours", silently
# leaving a stale bundle in place forever. A leading `//` comment is valid
# anywhere in JS, so this is a no-op for the daemon that loads the file.
{ printf '// iamlazy-managed\n'; cat dist/iamlazy.js; } > dist/iamlazy.js.new \
  && mv dist/iamlazy.js.new dist/iamlazy.js

echo "done: dist/iamlazy.js ($(wc -c < dist/iamlazy.js | tr -d ' ') bytes)"
echo
echo "Deploy: copy dist/iamlazy.js to ~/.config/opencode/plugins/iamlazy.js (a"
echo "LOOSE file there is auto-discovered) and remove any loose iamlazy.ts/"
echo "iamlazy/ directory from that same plugins/ folder first, so the daemon"
echo "does not try to load two copies. Do not list it in opencode.jsonc's"
echo "\"plugins\" array as a bare file path -- V2 warns \"configured plugin path"
echo "must be a directory\" for that shape and silently ignores the entry."
