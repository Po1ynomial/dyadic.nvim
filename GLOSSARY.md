# dyadic.nvim

A Neovim client for the pi coding agent. It shows pi's work as editor buffers and windows, so a person and an agent work side by side in one editor.

## Agents and sessions

**Agent**:
One pi process together with its history and composer. It shows one session at a time.
_Avoid_: conversation, session, instance, thread, chat

**Session**:
Pi's saved conversation tree, identified by its session ID and session file. An agent can start or resume a different session without becoming a different agent.
_Avoid_: thread, chat, history

**Run**:
One user message and all of the agent's work in reply, up to the next user message.
_Avoid_: turn, exchange

**Phase**:
What an agent is doing at the moment, such as idle, streaming, compacting, or retrying.
_Avoid_: state, status

**Steer**:
A queued message delivered to the agent during the current run.
_Avoid_: interrupt, queued prompt

**Follow-up**:
A queued message delivered after the current run ends.
_Avoid_: queued prompt, next prompt

**Quit guard**:
The rule that refuses to quit Neovim while an agent has work in progress.
_Avoid_: exit lock

## Screen

**History**:
The read-only buffer that shows the messages of an agent's current session.
_Avoid_: transcript, log, output

**Composer**:
The editable buffer, and its window, where the next message is written. It belongs to one history window.
_Avoid_: input, prompt, editor

**Draft**:
The unsent text in the composer. It outlives the composer window and is cleared on submit.
_Avoid_: input, buffer contents

**Footer**:
The lines below the draft that show context use, cost, model, thinking level, and extension statuses.
_Avoid_: status block, metadata lines

**Placement**:
Where a history window goes on screen: in the sidebar or free.
_Avoid_: layout, mode

**Sidebar**:
The placement that keeps one history window, and its composer, in a column at the edge of a tab.
_Avoid_: panel, drawer

**Free**:
The placement that shows a history window wherever the user puts it.
_Avoid_: current, floating

**Main area**:
The windows of a tab outside the sidebar.
_Avoid_: editor area, code window

## History contents

**Speaker row**:
The line that starts a message and names who wrote it.
_Avoid_: role row, header

**Activity**:
A tool call or a thinking block in a run.
_Avoid_: step, action, item

**Group**:
Consecutive activities in a run, shown either expanded or collapsed.
_Avoid_: summary, block

**Detail**:
The full view of one activity.
_Avoid_: preview, hover, popup

**Entry**:
One node of a session's tree, such as a message, a summary, or a setting change.
_Avoid_: node, item, turn

**Branch**:
The entries from the root of a session's tree to one entry. The history shows the active branch, the one that ends at the current entry.
_Avoid_: thread, path

**Label**:
A name the user gives to an entry.
_Avoid_: bookmark, tag

## Bridge

**Bridge**:
The pi extension that dyadic loads into each agent, through which pi's file tools and session commands reach the editor.
_Avoid_: plugin, adapter, injected extension

**Review**:
The user's decision on a change an agent proposes to a file, made hunk by hunk in that file's buffer before the agent continues.
_Avoid_: approval, diff preview, patch session

**Hunk**:
One contiguous changed region of a proposed change, accepted or rejected on its own.
_Avoid_: block, chunk

**Edited hunk**:
An undecided hunk whose lines the user changed. Editing never decides a hunk; accepting an edited hunk accepts the user's version.

**Change note**:
A message dyadic gives an agent about files it has seen that changed since, by the user or anything else: at the start of a run, or in the result of an edit or write.
_Avoid_: sync, diff notification

**Review rule**:
A path with a review setting; the nearest rule above a file decides whether changes to it are reviewed.
_Avoid_: scope, policy

**Tree picker**:
The float that shows a session's tree of entries and moves the agent to another entry in it.
_Avoid_: tree view, tree selector, navigator
