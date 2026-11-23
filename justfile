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
    bash tests/pi-env.sh check

# Run the bridge's tests with the installed pi's tools and a fake dyadic (needs deno)
test-ts:
    bash tests/pi-env.sh test

# Format Lua sources
fmt:
    stylua lua plugin tests

# Try reviews by hand against the fake pi; pass --clean to skip your config
demo-review *args:
    {{nvim}} {{args}} -c "luafile scripts/review_demo.lua"
