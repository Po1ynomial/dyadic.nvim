# dyadic.nvim

A native Neovim client for [pi](https://pi.dev), using its stock RPC mode. A conversation buffer owns a pi process; a companion draft buffer provides normal Neovim editing. No embedded terminal, buffer-context injection, or required UI libraries.

## Requirements

- Neovim 0.11 or newer. Runtime verification used Neovim 0.13-dev.
- `pi` on PATH, with provider authentication and pi configuration already set up.

Install this directory with your plugin manager or put it on Neovim's runtimepath. Setup is optional:

```lua
require('dyadic').setup({
  cmd = { 'pi' },
  args = {},
  draft_height = 6,
  completion = true,
  mappings = {},
})
```

`cmd` is an executable argv array. `args` contains ordinary pi startup options, such as `--model` or `--session-dir`. Dyadic adds `--mode rpc`; do not supply another CLI mode. Pi still loads its own configuration, tools, extensions, skills, and templates. There is no plugin cwd option: each conversation captures Neovim's effective cwd when activated, including window/tab-local cwd, and keeps it after later `:cd` commands.

## Open a conversation

Run `:Dyadic`. The default layout uses the current window for the transcript and a small split below it for the draft. Both are ordinary scratch buffers named `dyadic://<id>/transcript` and `dyadic://<id>/draft`. You can move or display them in other windows. Windows do not own processes.

Edit the draft in Insert or Visual mode using native Neovim keys. Return to Normal mode and press Enter to submit. The transcript is read-only, with native motions, search, yanking, and folds. Tool arguments and results are folded together; use `za` for individual details or the display-toggle actions for all tools/thinking.

The draft statusline shows runtime state, model, thinking level, context usage, total tokens, cost, and extension status entries. Usage details are available through `/session`.

Hiding a conversation does not interrupt it. Deleting its transcript buffer or running `:Dyadic close` ends its process and disposes its draft and pending extension dialogs. Exiting Neovim ends all owned processes. Saved pi session files are not deleted. Deleting only the draft leaves the conversation running; `:Dyadic show` recreates an empty draft.

## Normal-mode keys

These defaults are buffer-local. Application overrides apply to the draft, not Insert or Visual mode. The transcript also has the display toggles and the focus-draft shortcut.

| Draft key | Action |
|---|---|
| Enter | Submit; steer when pi is working |
| Alt+Enter | Submit as follow-up |
| Escape | Clear pending queues, restore their text, then abort |
| Alt+Up | Return queued messages to the draft |
| Ctrl+L | Select a model with `vim.ui.select` |
| Shift+Tab | Cycle thinking level |
| `<localleader>t` | Toggle thinking visibility |
| `<localleader>o` | Toggle tool details |
| `<localleader>s` | Select an RPC-supported setting |
| `<localleader>?` | Show local mappings |
| `<localleader>i` | Focus the draft |
| `<localleader>r` | Focus the transcript |

Critical native bindings such as Ctrl+O, Ctrl+T, Ctrl+D, Ctrl+W, and Ctrl+X are not replaced. Terminal support for modified Enter/Tab keys varies; remap their actions when necessary.

All actions also have buffer-local `<Plug>` mappings:

```text
(DyadicSubmit)           (DyadicFollowUp)       (DyadicAbort)
(DyadicDequeue)          (DyadicModel)          (DyadicThinking)
(DyadicCycleThinking)    (DyadicCycleModel)     (DyadicCopy)
(DyadicToggleThinking)   (DyadicToggleTools)    (DyadicSettings)
(DyadicNew)              (DyadicResume)         (DyadicHotkeys)
(DyadicFocusDraft)       (DyadicFocusTranscript)
```

For example, `<Plug>(DyadicCopy)` copies the last assistant response to the unnamed register and the clipboard when available. Configure defaults by action name; `false` disables a default:

```lua
require('dyadic').setup({
  mappings = {
    submit = '<leader><CR>',
    follow_up = '<leader>f',
    model = false,
    thinking = '<localleader>h',
    cycle_model = '<localleader>m',
    copy = '<localleader>y',
  },
})
```

Other mapping names are `abort`, `dequeue`, `cycle_thinking`, `toggle_thinking`, `toggle_tools`, `settings`, `new`, `resume`, `hotkeys`, `focus_draft`, and `focus_transcript`. Configuration applies to subsequently opened conversations.

In Insert mode, `<C-x><C-o>` completes slash commands and paths from the conversation's captured cwd. `@`-prefixed path references are supported. This does not automatically attach the current buffer or a selection.

## Pi commands

Type commands in the draft and submit them in Normal mode:

| Input | Behavior |
|---|---|
| `/model [provider/model or search]` | Model selection |
| `/thinking [level]` | Supported thinking-level selection |
| `/new` | Start a fresh session in the same process and buffer |
| `/resume [session-file or all]` | Native saved-session picker or explicit file; `all` includes other cwd groups |
| `/name [name]` | Set or display the session name |
| `/session`, `/stats` | Show session identity, file, usage, cost, and context |
| `/compact [instructions]` | Compact through pi |
| `/fork [entry-id]` | Fork from a selected user message; restore that message's text |
| `/clone` | Clone the active branch into a new session |
| `/export [HTML path]` | Export HTML through pi |
| `/copy` | Copy the last assistant response |
| `/settings` | Select auto-compaction, auto-retry, steering mode, or follow-up mode |
| `/hotkeys` | Show buffer-local action mappings |
| `/quit` | Close this conversation |
| `!command` | Run a shell command and include its output in pi's context |
| `!!command` | Run a shell command but exclude its output from model context |

Settings also accept direct input, such as `/settings auto-compaction off` or `/settings steering one-at-a-time`. They change the active pi session, not the user's settings files.

Extension commands, skills, and templates discovered through `get_commands` are forwarded to pi. Their expansion and execution remain pi's responsibility. Input submitted during compaction is queued locally, matching pi's terminal client, and delivered when compaction finishes. Abort returns both pi's queues and that local queue without discarding a newer unsent draft.

Session history uses pi's active branch and compaction boundaries. It displays raw conversation entries, not model-only `context_edit` replacements. It does not show the system prompt or extension messages marked hidden.

Pi owns persistence in its configured storage. The resume picker honors `--session-dir`, `PI_CODING_AGENT_SESSION_DIR`, project/user `sessionDir`, and `PI_CODING_AGENT_DIR`; an active session's file directory is authoritative. Dyadic does not maintain another conversation database.

## Neovim commands and Lua API

- `:Dyadic` or `:Dyadic new`: activate another conversation buffer and process.
- `:Dyadic show`: show the current conversation, or the most recently activated one.
- `:Dyadic sessions`: choose among live conversation buffers.
- `:Dyadic input`: focus the current conversation's draft.
- `:Dyadic submit`, `follow_up`, `dequeue`, `abort`, `close`: perform that action.
- `:Dyadic model`, `resume`, `compact`, and other supported slash-command names: run the equivalent operation on the current conversation without replacing its draft.

`:Dyadic new` creates another buffer; `/new` changes the session in an existing buffer.

```lua
local dyadic = require('dyadic')
local conversation = dyadic.open()
dyadic.show(conversation)
local current = dyadic.get() -- conversation for the current transcript/draft, or nil
local conversations = dyadic.list()
dyadic.action('submit')
dyadic.command('resume')
```

## Extensions and protocol limits

Supported extension UI requests use native equivalents:

- `select`, `confirm`: `vim.ui.select`.
- `input`: `vim.ui.input`.
- `editor`: native multiline floating buffer. In Normal mode, `g<Enter>` accepts; `q` or Escape cancels. Insert/Visual editing remains native. `<Plug>(DyadicEditorAccept)` and `<Plug>(DyadicEditorCancel)` are available in that buffer.
- Notifications, keyed status entries, string-array widgets, titles, and editor prefills are displayed.

Dialogs are serialized. RPC-provided timeouts and conversation/process disposal cancel pending requests; late callbacks cannot send a second response. No extra dialog timeout is imposed.

Only stock RPC is used. Unsupported TUI built-ins are rejected locally instead of becoming model prompts. This includes tree navigation, login/logout, reload, scoped-model configuration, share/bug workflows, and trust management. JSONL export, saved-session deletion/renaming inside a picker, custom extension renderers, terminal images, custom editor components, and terminal theme controls are not ported. Image content in messages is identified textually, not rendered as pixels.
