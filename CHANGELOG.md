# Changelog

Each release has one section. The release job publishes the section of the tag as the notes of the release.

## Unreleased

- `yuke update` (also `yuke upgrade`) installs the newest release of your channel, or the release that you name.
- The installer takes `YUKE_VERSION` to install one release.
- The installer checks each download against `SHA256SUMS`.
- Better Markdown in the TUI: tables, code blocks, and quotes inside list items now render.
- `yuke:test`: `createHost({ frame })` gives each plugin under test a terminal on the frame, and the frame shows the
  notices of the host. A plugin under test can be a bundled plugin, `{ bundled: "chat" }`, and can get a `dataDir`.
- `yuke:test`: `FrameTest` has `rows()`, `click()`, and `drag()`.
- `Transcript.jobs` holds the running background jobs of the session.
- The chat pane no longer fails when its session closes while a page of history loads.
- A request of `sessions` or `catalog` with an argument that yuke refuses, such as a malformed session id, rejects its
  promise. Before, it threw at the call.
- The optional fields of the options of `yuke:test` take `undefined`.
- The built-in tools show a title in the chat: `Read`, `Write`, `Edit`, `Exec`, and `Stop`. A plugin tool shows one
  with `hints.title`.
- yuke keeps a connection open for 60 seconds after a request, and the next request to the same host uses it, so it
  skips the connection setup.
- On a network where IPv6 drops packets, a request goes over IPv4 after 250 ms. Before, it waited for the system to
  give up on IPv6, which takes about 75 seconds on macOS.

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
