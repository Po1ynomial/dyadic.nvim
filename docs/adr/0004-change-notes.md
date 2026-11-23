# Change notes: tell the agent which files changed, let it read them

The user edits files while an agent works with them, and so do formatters, other agents and git. The bridge's `read` already returns the current text, and an `edit` written against an outdated view usually fails to match and makes the agent read again, so on-demand reading is the base. What it lacks is a signal: the agent doesn't know to read again, so it answers from an outdated view, or its edit still matches and lands in code the user has since changed. With `change_notes = true`, dyadic remembers the text each agent last saw of every file it read or changed through the bridge's tools. At the start of each run the user starts, the bridge injects one stored message naming the files that changed since, each with a diff of up to 20 changed lines, or only where and how much changed beyond that. An `edit` or `write` whose file ends up different from what the tool produced, from a formatter on save or the user's edits in a review, says the same in its result. The note says the current version stands. After a session switch or a move in the tree, the record is dropped, since what the agent saw belongs to the branch it left. The option is off by default.

Like review (ADR 0003), this goes beyond stock pi, whose own interface doesn't notice edits made in another editor either; dyadic adds it because it is what makes the user's unsaved text and the agent's view diverge.

## Considered options

- **Reading on demand only.** No cost and no new behaviour, but the agent rarely knows when to read, so outdated views go unnoticed until an edit fails, or not at all.
- **Keeping the agent in sync with every edit as it happens.** Costs tokens and cache misses on every keystroke-sized change, floods the context with irrelevant edits, and still misses changes made by `bash`.
- **Notes through pi's per-request `context` hook, also mid-run.** Not stored in the session, so later turns and the tree would disagree about what the agent was told.

## Consequences

- Only files read or changed through the bridge's tools are tracked; a file the agent saw through `bash` is not.
- Changes made during a run reach the agent in the result of its next `edit` or `write` to that file, or at the next run start.
- A review result no longer says "The user also edited the file" when change notes are on; the note's diff replaces it.
