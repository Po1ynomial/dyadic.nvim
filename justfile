# Neovim used for tests. Not $NVIM: inside a Neovim terminal that is the server address.
nvim := env("DYADIC_NVIM", "nvim")

# Run all tests, or only the given files
test *files:
    {{nvim}} --clean --headless -l tests/run.lua {{files}}

# Run the smoke test against the real pi (no model calls)
test-real-pi:
    DYADIC_REAL_PI=1 {{nvim}} --clean --headless -l tests/run.lua tests/test_real_pi.lua

# Type-check the bridge against the installed pi's declarations (needs deno)
check-ts:
    #!/usr/bin/env bash
    set -euo pipefail
    command -v deno >/dev/null || { echo "check-ts: deno not found, skipped"; exit 0; }
    # The package root is the nearest parent of pi's real executable with a package.json.
    pkg=$(dirname "$(readlink -f "$(command -v pi)")")
    while [ ! -f "$pkg/package.json" ]; do pkg=$(dirname "$pkg"); done
    # Resolve pi's own imports, and its dependencies, the way pi maps them for extensions.
    dir=$(mktemp -d)
    trap 'rm -rf "$dir"' EXIT
    mkdir -p "$dir/node_modules/@earendil-works"
    for p in "$pkg"/node_modules/*; do
        [ "$(basename "$p")" = "@earendil-works" ] || ln -s "$p" "$dir/node_modules/"
    done
    ln -s "$pkg"/node_modules/@earendil-works/* "$dir/node_modules/@earendil-works/"
    ln -s "$pkg" "$dir/node_modules/@earendil-works/pi-coding-agent"
    echo '{"type":"module"}' > "$dir/package.json"
    cp pi/*.ts "$dir/"
    cd "$dir" && deno check --quiet --node-modules-dir=manual ./*.ts

# Format Lua sources
fmt:
    stylua lua plugin tests
