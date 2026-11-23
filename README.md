# dyadic.nvim

A native Neovim client for [pi](https://pi.dev), using its RPC mode and a small bundled pi extension, the bridge, for what stock RPC lacks. An agent is one pi process with two buffers: a read-only history of the session and a composer where you write the next message with normal Neovim editing. No embedded terminal and no required UI libraries.

By default the agent lives in a sidebar: the history on top, the composer below it, both kept in place while you work in the rest of the tab. The history holds only message text, so it stays plain markdown; tool calls, thinking, and shell commands are overlay rows that collapse once the agent answers, and `K` opens any of them in a float. The composer shows the agent's phase, queued messages, context use, cost, and model around your draft. `/tree`, or `<Esc><Esc>` while the agent is idle, opens pi's session tree in a float to move between branches, with pi's filters, search, labels, and Neovim folds.

The bridge also routes pi's `read`, `edit`, and `write` through your buffers: the agent reads unsaved text, and its changes land in open buffers as ordinary edits. With `review` on, every change waits in the file's buffer, hunk by hunk, until you accept or reject it, optionally with a reason for the agent. With `change_notes` on, the agent is told when files it has seen change, by you or anything else.

## Requirements

- Neovim 0.11 or newer.
- `pi` on `PATH`, with provider authentication and pi configuration already set up. The bridge needs pi 1.5.2 or newer.

## Installation

Install this repository with your plugin manager, or add it to `runtimepath`. Setup is optional:

```lua
require('dyadic').setup({
  cmd = { 'pi' },
  args = {}, -- pi startup options, such as { '--model', 'provider/id' }
  bridge = true, -- load dyadic's pi extension; false runs stock pi only
  review = false, -- true, or { default = false, paths = { ['~/work'] = true } }
  change_notes = false, -- tell the agent when files it has seen change
  placement = 'sidebar', -- or 'free'
  sidebar = { side = 'right', width = 0.35, min_width = 40, max_width = 120 },
  composer = { min_height = 3, max_height = 0.4 },
  statusline = true,
  completion = true,
  mappings = {},
  double_escape = 'tree', -- <Esc><Esc> while idle: 'tree', 'fork', or 'none'
})
```

Run `:Dyadic` to show an agent. Write in the composer, then press Enter in Normal mode to submit. `:Dyadic toggle` hides and shows the sidebar; `:Dyadic new` opens another agent.

## Documentation

The full reference is in Neovim's help: `:help dyadic`. It covers windows and placements (`:help dyadic-windows`), the history and details (`:help dyadic-history`), the composer, mappings, pi commands, the Lua API, file reloading, the tree picker (`:help dyadic-tree`), reviews (`:help dyadic-review`), change notes (`:help dyadic-change-notes`), the bridge (`:help dyadic-bridge`), and protocol limits. [GLOSSARY.md](GLOSSARY.md) defines the terms the code and docs use.

## Development

Tests run with [just](https://github.com/casey/just) and need nothing else: each case runs in its own headless Neovim against a scriptable fake pi, so they make no model calls.

```sh
just test                          # all tests
just test tests/test_history.lua   # selected files
just test-real-pi                  # smoke test against the real pi, still without model calls
just test-real-model               # a reviewed edit and change notes with pi's default model (makes model calls)
just check-ts                      # type-check the bridge against the installed pi (needs deno)
just test-ts                       # the bridge's tools against pi's own definitions (needs deno)
just fmt                           # stylua
just demo-review                   # try reviews by hand against the fake pi (--clean: without your config)
```

Set `DYADIC_NVIM` to test with another Neovim binary.
