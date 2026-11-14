# Plugin operations for a personal profile

These public APIs support the personal Rust profile in `dotfiles/yuke-rust`.
Their declarations are in `crates/js/types` and `crates/js/modules/plugins.ts`.

## Chat service

`folder(view)` gives the folder of a chat pane: the folder of its session, else the folder of its next session.
It gives `undefined` for a view that is not a chat pane.

`newSession(options?)` shows no session in the focused chat pane, as `/new` does.
The session before keeps its work.
`options.cwd` sets the folder of the next session.
Without it, the next session starts in the folder of the session before.

`ensureSession()` creates the session of the focused chat pane, or opens it again, and gives its ID.
It sends no message, and the draft and the attachments stay.
It gives `undefined` when the user cancels the model choice.
A busy pane rejects the operation.

`setModelPicker(picker)` replaces the model picker of each chat pane and gives its remover.
`/model` and the first message without a saved choice use it.
`chooseModel(picker?)` opens the supplied picker, or the registered picker, in the focused pane.
The context holds the ready providers, the current and the saved choices, and the signal of the pane.
An `undefined` result cancels the choice.
The chat checks the model and the reasoning level against the ready providers before it saves the choice.

## Saved work and inspection

`SessionHandle.record({ display, text })` saves a completed local action as input of kind `record`.
No `input.before` handler runs.
It requests no answer of the model.
An idle session saves it at once.
A running turn reads it at its next round.
The promise confirms that the session accepted the record.

`Sessions.inspect(id)` reads the saved context of an open session.
It gives the settings, the blocks, the token counts, the prompt sections, and the registered tools.
It excludes drafts and pending input.
It runs the `prompt.build` handlers.
It runs no round handler, no tool, and no model request.
`inputTokens` is `null` when no provider count exists.
`contextTokens` is the estimate that a `round.before` handler gets.
Each tool is a protocol `ToolDefinition`, with its JSON `inputSchema` string.

`Sessions.fork(id, { through, cwd })` copies the history through a completed turn.
With `cwd`, the fork builds its system prompt from the instructions and the skills of that folder.
The source session does not change.
A folder that is not a directory rejects the operation.

## Tool selection

A `round.before` or `round.retry` answer can give `tools: string[]`.
The request then offers only the registered tools with those names in that round.
An empty list offers no tool.
Without the field, the request offers its usual tools.
A later handler replaces the list.
The list limits the request, not the calls.
A `tool.before` handler refuses a call that must not run.

## Source text of a clipped tool heading

A source mapping with `kind: "elision"` maps each shown unit to its source unit, except its last unit.
The last unit stands for the rest of the source range.
The tool heading uses this mapping for its final ellipsis, so a caret keeps its place across a fold and a reflow.
A raw copy keeps the complete source text.

## Provider metadata

A custom provider model accepts the fields `input`, `output`, and `tools`.
`input` and `output` list protocol modalities, such as `"text"` and `"image"`.
The boolean `tools` sets the support for model tools.
A bridge can then declare image input without the defaults of the catalog.

## Covered by the core

These operations of the earlier patch are now part of the core API:

- The view of an empty pane: `chat.setEmptyView((mount, pane) => view)`.
- A view next to the composer that reads the composer: `chat.addComposerView(place, (mount, pane) => view)`, with
  `pane.composer`.
- The completion list next to an editor: `chat.addCompletionProvider(provider)`.
- The version of the host: `tui.startup.version`.
