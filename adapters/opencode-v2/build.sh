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
  echo "iamlazy: se necesita bun para construir el adaptador OpenCode V2 (https://bun.sh)" >&2
  exit 1
fi

if [ ! -d node_modules ]; then
  echo "instalando @opencode/plugin (solo para build; no queda en el bundle final)"
  bun install
fi

echo "chequeando tipos"
# Only the adapter itself gates a build; iamlazy.test.ts is still covered by
# tsconfig.json for editors, but a test-only type slip should not block
# shipping production code. -p and file arguments cannot be mixed, so this
# repeats tsconfig.json's compiler options explicitly for a single-file check.
./node_modules/.bin/tsc --noEmit --target ESNext --module ESNext --moduleResolution bundler \
  --types bun --strict --skipLibCheck iamlazy.ts

echo "empaquetando"
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

echo "listo: dist/iamlazy.js ($(wc -c < dist/iamlazy.js | tr -d ' ') bytes)"
echo
echo "Deploy: copia dist/iamlazy.js a ~/.config/opencode/plugins/iamlazy.js (un"
echo "archivo SUELTO ahi se auto-descubre) y elimina primero cualquier iamlazy.ts/"
echo "directorio iamlazy/ que quede en esa misma carpeta plugins/, para que el"
echo "daemon no intente cargar dos copias. No lo listes en el array \"plugins\""
echo "de opencode.jsonc como un path de archivo suelto -- V2 avisa \"configured"
echo "plugin path must be a directory\" para esa forma e ignora la entrada en silencio."
