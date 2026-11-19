# The history holds only message text

The history buffer contains only the text of messages. Everything else (speaker rows, activities and groups, shell commands, compaction and branch summaries, usage, errors, queued messages) is drawn as overlay virtual text on real empty lines. This keeps the buffer valid markdown, so treesitter, markdown renderers, yanking, and motions see plain messages instead of plugin decorations, and it replaces the earlier folds over mixed text.

## Consequences

- `/` cannot find tool names or other overlay text; the detail view is the way to read and search an activity.
- Overlay text is cut off at the window edge instead of wrapping.
- Cursor-dependent actions such as toggling a group or opening a detail look up the overlay on the cursor's line, not the buffer text.
