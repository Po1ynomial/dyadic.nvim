# dyadic ships a pi extension

Stock RPC cannot move within a session's tree or let pi's file tools see editor buffers, so dyadic loads its own extension, the bridge (`pi/dyadic.ts`), into every agent with `-e`, unless `bridge = false`. The bridge talks to Neovim through pi's extension UI dialogs on the existing stdio, with JSON in the dialogs' string fields. The tree picker is drawn by dyadic from stock `get_tree`; the bridge adds thin commands for what pi offers to extensions alone (`navigateTree`, `setLabel`, `reload`), and a `before_agent_start` hook that adds change notes when they are on (ADR 0004). The replaced `read`, `edit` and `write` are pi's own tool definitions with editor-backed file operations, so pi keeps its matching, result format and rendering. Beyond one tool call's plan, the bridge keeps no state: dyadic decides, and the bridge passes the answer on.

## Considered options

- A `vim.uv` socket with a token: more code, and Neovim never needs to push to the extension unprompted.
- `nvim --remote-expr` with file polling, as in coact: a process start and a poll per call, and it needs a server address although `$NVIM` is stripped on purpose.
- `select` dialogs carrying objects: works today, but relies on pi not checking option types, which its docs say are strings.

## Consequences

- dyadic depends on pi's extension API and needs a minimum pi version. If the bridge is missing, dyadic falls back to stock behaviour.
- Bridge requests arrive as `extension_ui_request` messages and must be recognised before they reach the extension dialog UI.
- pi does not tell the client when an abort cancels a dialog; dyadic closes open reviews itself when a run ends.
