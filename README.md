# dyadic.nvim

A native Neovim client for [pi](https://pi.dev), using its stock RPC mode. Each conversation is one pi process and one read-only transcript buffer; a companion draft buffer is where you write, with normal Neovim editing. No embedded terminal and no required UI libraries.

The transcript holds only message text, so it stays plain markdown. Tool calls, thinking, shell commands, and queued input are overlay rows; activity collapses into a summary once the agent answers, and `K` opens any item in its own buffer.

## Requirements

- Neovim 0.11 or newer.
- `pi` on `PATH`, with provider authentication and pi configuration already set up.

## Installation

Install this repository with your plugin manager, or add it to `runtimepath`. Setup is optional:

```lua
require('dyadic').setup({
  cmd = { 'pi' },
  args = {}, -- pi startup options, such as { '--model', 'provider/id' }
  draft_height = 6,
  completion = true,
  mappings = {},
  layout = nil, -- function(session) to replace the default split
})
```

Run `:Dyadic` to open a conversation. Write in the draft, then press Enter in Normal mode to submit.

## Documentation

The full reference is in Neovim's help: `:help dyadic`. It covers the transcript and detail buffers (`:help dyadic-transcript`), mappings (`:help dyadic-mappings`), pi commands, the Lua API, file reloading, and protocol limits.

## Development

Tests run with [just](https://github.com/casey/just) and need nothing else: each case runs in its own headless Neovim against a scriptable fake pi, so they make no model calls.

```sh
just test                          # all tests
just test tests/test_render.lua    # selected files
just test-real-pi                  # smoke test against the real pi, still without model calls
just fmt                           # stylua
```

Set `DYADIC_NVIM` to test with another Neovim binary.
