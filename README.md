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

Tests use [mini.test](https://github.com/nvim-mini/mini.test) and a scriptable fake pi, so they make no model calls:

```sh
make test                              # clones mini.test into deps/ on first run
make test FILE=tests/test_render.lua   # one file
MINI_TEST_PATH=/path/to/mini.test make test
```

Rendering tests compare screenshots in `tests/screenshots/`. After an intended UI change, delete the affected files and rerun the tests to regenerate them, then review the new screenshots before committing.
