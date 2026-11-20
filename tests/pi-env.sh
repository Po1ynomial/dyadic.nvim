#!/usr/bin/env bash
# Run deno against the bridge (pi/*.ts) and its tests (tests/*.test.ts) with the installed
# pi's packages, resolved the way pi maps them for extensions.
#   tests/pi-env.sh check   type-check
#   tests/pi-env.sh test    run tests/*.test.ts
set -euo pipefail
command -v deno >/dev/null || { echo "deno not found, skipped"; exit 0; }
root=$(cd "$(dirname "$0")/.." && pwd)
# The package root is the nearest parent of pi's real executable with a package.json.
pkg=$(dirname "$(readlink -f "$(command -v pi)")")
while [ ! -f "$pkg/package.json" ]; do pkg=$(dirname "$pkg"); done
dir=$(mktemp -d)
trap 'rm -rf "$dir"' EXIT
mkdir -p "$dir/node_modules/@earendil-works" "$dir/pi" "$dir/tests"
for p in "$pkg"/node_modules/*; do
    [ "$(basename "$p")" = "@earendil-works" ] || ln -s "$p" "$dir/node_modules/"
done
ln -s "$pkg"/node_modules/@earendil-works/* "$dir/node_modules/@earendil-works/"
ln -s "$pkg" "$dir/node_modules/@earendil-works/pi-coding-agent"
echo '{"type":"module"}' > "$dir/package.json"
cp "$root"/pi/*.ts "$dir/pi/"
cp "$root"/tests/*.test.ts "$dir/tests/" 2>/dev/null || true
cd "$dir"
case "${1:-check}" in
    check) deno check --quiet --node-modules-dir=manual pi/*.ts tests/*.test.ts ;;
    test) deno test --quiet --node-modules-dir=manual -A tests/ ;;
    *) echo "usage: $0 check|test" >&2; exit 2 ;;
esac
