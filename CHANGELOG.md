# Changelog

Each release has one section. The release job publishes the section of each tag as its release notes.

## Unreleased

### Fixes and speed

- `read`, `write`, and `edit` resolve a path that starts with `~/` against the home folder, not the workspace.

## 0.3.0

### Breaking changes

- The TUI shows one session and its subagents. The panes and their `ctrl+k` keys are gone: run yuke in more terminals.
- `/new` and `/sessions` close the old session, so its commands and subagents stop. While work runs, yuke asks first.

### Plugin API

- `tui.setMain` replaces `tui.panes` and `tui.views.add`.
- `chat.sessionId()` replaces `chat.sessionIdOf(view)`, and `chat.addChildLabel` replaces `chat.addReadOnly`.
- `ChatPane` is `ChatView`, and `addPaneWatcher` is `addViewWatcher`.

### Fixes and speed

- A question of the main session shows while you watch a subagent.

## 0.2.0

### Breaking changes

- A tool result keeps the `bytes` of its media without a copy, and a tool keeps its `inputSchema` without a copy. Do
  not change them after you give them to yuke.
- `sessions` and `catalog` reject the promise when yuke refuses an argument, such as a malformed session id. Before,
  they threw at the call.
- `McpServerState` has the new kind `needsLogin`. A `switch` over all kinds needs a case for it.
- A TUI or chat listener that you add twice runs twice. Each remover removes only its own add. Before, yuke kept one
  entry, and one remover removed both.

### Features

- `yuke update` (also `yuke upgrade`) installs the newest release of your channel (stable or nightly), or the
  release that you name.
- The installer takes `YUKE_VERSION` to install one release. It checks each download against `SHA256SUMS`.
- MCP servers can be remote. An entry with `url` connects over Streamable HTTP and sends its `headers` on each
  request, with `${NAME}` expanded.
- Remote MCP servers can use OAuth. In the TUI, `/mcp` lists the servers and logs in to them, and
  `/mcp logout <server>` removes a login. RPC clients use `mcp/login` and the related methods.
- The chat shows a title for each built-in tool (`Read`, `Write`, `Edit`, `Exec`, `Stop`). A plugin tool sets its
  title with `hints.title`.
- The TUI renders tables, code blocks, and quotes inside list items.

### Plugin API

- `yuke:test`: `createHost({ frame })` gives each plugin under test a terminal on the frame. The frame shows host
  notices. A test can load a bundled plugin (`{ bundled: "chat" }`) and give it a `dataDir`.
- `yuke:test`: `FrameTest` has `rows()`, `click()`, and `drag()`.
- `yuke:test` options accept `undefined` for optional fields.
- `Transcript.jobs` holds the running background jobs.

### Fixes and speed

- The chat pane no longer fails when its session closes while history loads.
- yuke reuses an HTTP connection for 60 seconds, so repeated requests to a host start faster.
- On networks where IPv6 drops packets, yuke falls back to IPv4 after 250 ms. Before, it could hang for about 75
  seconds.

## 0.1.1

- `yuke:chat` exports the chat building blocks again: `ChatSession`, `ChatComposer`, `ChatQuestions`,
  `ChatCompletions`, `ChatWorking`, `ChatDocument`, `slashCompletions`, and `composerRows`.
- `TextEditor.screenAt` and `TextView.screenAt` give the cell of a position again.

## 0.1.0

The first release of yuke: a fast, hackable coding agent with a TUI that you change with TypeScript plugins.

- One native binary for macOS and Linux, on x86-64 and arm64. Windows works through WSL.
- TypeScript plugins add commands, keys, themes, panes, tools, and hooks. The bundled chat is a plugin too, so you can
  replace it.
- MCP servers over stdio.
- Built-in providers with an API key, ChatGPT and Grok account logins, and other servers in `providers.json`.
- Sessions save to disk. Resume, fork, or compact a session.
- `yuke -p` runs one task in a script or CI. `yuke --rpc` serves the JSON-RPC protocol to other frontends.
- `yuke plugin add` installs plugins from Git, and `plugins.lock` pins each one to a commit.

### Upgrade from a preview build

The alpha and nightly builds were previews, and 0.1.0 breaks their formats:

- Delete `~/.local/share/yuke/sessions` and `~/.local/share/yuke/sessions.jsonl`.
- Write the keys of `providers.json` in camelCase, such as `baseUrl`. The values stay as they were.
- Many plugin API names changed, such as `cwd` to `folder`. Run `tsc` on a plugin to find them.
