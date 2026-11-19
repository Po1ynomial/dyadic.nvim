# Neovim used for tests. Not $NVIM: inside a Neovim terminal that is the server address.
nvim := env("DYADIC_NVIM", "nvim")

# Run all tests, or only the given files
test *files:
    {{nvim}} --clean --headless -l tests/run.lua {{files}}

# Run the smoke test against the real pi (no model calls)
test-real-pi:
    DYADIC_REAL_PI=1 {{nvim}} --clean --headless -l tests/run.lua tests/test_real_pi.lua

# Format Lua sources
fmt:
    stylua lua plugin tests
