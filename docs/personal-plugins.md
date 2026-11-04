# Plugin operations for chat customization

These public APIs support the personal Rust profile in `dotfiles/yuke-rust`.
Their declarations are in `crates/js/types` and `crates/js/modules/plugins.ts`.

## Chat service

`setEmptyView(factory)` replaces the content area of each empty, unsent chat pane.
The composer keeps keyboard focus.
Saved sessions, typed drafts, and attachments show their usual content.
The view stays below notices and dialogs.
Its context supplies the composer, working directory, current saved model choice, and a lifetime signal.
The last registration wins.
The signal aborts when the registration ends or the pane closes.
The returned disposer restores the default only while its registration is current.

`ctx.get("chat").newChat(cwd?)` replaces the active chat pane with an unsent draft.
Other panes and saved sessions stay in place.
`cwd` sets the draft directory.
`folder(view)` returns the directory of a chat pane, including an unsent draft.

`start()` creates or reopens the active session and returns its ID.
It preserves the draft and attachments.
It sends no input or model request.
A busy pane rejects the operation.

`setModelPicker(picker)` registers a picker for each pane and returns its disposer.
`chooseModel(picker?)` opens that picker or the supplied picker in the active pane.
The context contains ready providers, current and saved choices, and the pane signal.
An `undefined` result cancels the choice.
The chat validates the model and reasoning level before it saves the choice.

A composer row source receives its pane's `composer` widget.
The source runs during layout and must remain synchronous and cheap.

## Saved work and inspection

`SessionHandle.record(display, text)` saves a completed local action as input of kind `record`.
It bypasses input-admission hooks.
It does not request an assistant reply.
If a turn is active, the turn consumes the record at its next input boundary.
A record after a final answer stays available to the next user turn.
The returned promise confirms admission, not completion of another active turn.

`Sessions.inspect(id)` reads the saved context of an open session.
It returns settings, blocks, token counts, prompt sections, and registered tools.
It excludes live drafts and pending input.
It runs prompt hooks for the preview.
It does not run round hooks, tools, or a model request.
`inputTokens` is null when no valid provider count exists.
`contextTokens` uses the same estimate as a round hook.
Each tool uses the protocol `ToolDefinition`, including its JSON `inputSchema` string.

`Sessions.fork(id, through?, cwd?)` copies history through an inclusive completed event.
A destination directory rebuilds the system prompt from that directory's instructions and skills.
The source session stays unchanged.
An invalid directory or event rejects the operation.

## Tool selection

A `round.before` or `round.retry` answer can return `tools: string[]`.
The request offers only registered tools with those names for that round.
An empty list offers none.
Without the field, the request offers its usual tools.
A later handler replaces the list.
This option controls the request, not execution.
Use `tool.before` to reject calls that must not run.

## Widget geometry and source text

`WidgetMount.rect` holds the widget's last screen rectangle.
The mount keeps its identity while layout updates its rectangle.
Use it to anchor completion lists to an editor.

A source mapping with `kind: "elision"` maps a visible prefix to the same source offsets.
Its final displayed UTF-16 unit represents the remaining source range.
The tool heading uses this mapping for its final ellipsis.
Raw-copy operations retain the complete source text.

## Host identity and provider metadata

`PluginContext.version` is the version of the running native host.
It does not run a command from `PATH`.

A custom provider model accepts `input`, `output`, and `tools` fields.
The first two fields list protocol media types.
The boolean `tools` sets support for model tools.
These fields let a bridge advertise image input without relying on catalog defaults.
