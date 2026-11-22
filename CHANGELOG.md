# Changelog

Each release has one section. The release job publishes the section of the tag as the notes of the release.

## Unreleased

- `yuke update` (also `yuke upgrade`) installs the newest release of your channel, or the release that you name.
- The installer takes `YUKE_VERSION` to install one release.
- The installer checks each download against `SHA256SUMS`.
- Better Markdown in the TUI: tables, code blocks, and quotes inside list items now render.

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
