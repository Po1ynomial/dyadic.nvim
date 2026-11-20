# Reviewed changes stay unsaved

With review on, an agent's change to a file always goes into that file's buffer, opening it if needed, and is never saved: the user saves when ready. Commands that read from disk, such as tests, builds or git, don't see the change until then, and the model is told so once in the tool guidelines instead of in every result. With review off, a change to an open file is applied to the buffer and saved with a normal `:write`, including the user's unsaved changes and any save hooks such as formatters.
