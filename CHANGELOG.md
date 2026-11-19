# Changelog

Each release has one section. The release job publishes the section of the tag as the notes of the release.

## 0.1.0

The first release of yuke: a fast, hackable coding agent with a TUI that you change with TypeScript plugins.

### Highlights

- One native binary for macOS and Linux, on x86-64 and arm64. Windows works through WSL.
- Plugins add commands, key bindings, status items, themes, dialogs, panes, and transcript views. The bundled chat,
  sessions, login, and themes are plugins too, so you can replace each one.
- Engine hooks see each input, prompt, round, and tool call. A hook can deny a tool call or change its result.
- Model tools in TypeScript, and MCP servers over stdio with a trust question for project servers.
- Built-in providers with an API key: Anthropic, OpenAI, OpenRouter, DeepSeek, Groq, xAI, Mistral, Together AI,
  Cerebras, Fireworks AI, MiniMax, and OpenCode. Log in with a ChatGPT or Grok account. Add a local or other server in
  `providers.json`.
- Sessions save to disk. Resume a session with `-r` or `-c`, fork it, or compact it.
- `yuke -p` runs one task in a script or CI. `yuke --rpc` serves the JSON-RPC protocol on stdio or a Unix socket.
- `yuke plugin add` installs plugins from Git repositories, and `plugins.lock` pins each one to a commit.
- `AGENTS.md` and skills in `.agents/skills` go into the prompt.
- `yuke test` runs the tests of a plugin with the `yuke:test` module.

### Upgrade from an alpha or a nightly build

The alpha and nightly builds were previews. 0.1.0 changes their formats with no migration:

- yuke cannot read the sessions of an older build. Delete `~/.local/share/yuke/sessions` and
  `~/.local/share/yuke/sessions.jsonl`.
- The keys of `providers.json` are camelCase: `apiKeyEnv`, `baseUrl`, `sessionHeader`, `credentialHeader`,
  `upstreamId`, `reasoningLevels`, `contextWindow`, `maxOutputTokens`, `minPromptTokens`, `cacheRead`, `cacheWrite`,
  and the `flags` keys. The values stay as they were.
- `--model` needs `--reasoning`.
- The protocol and the plugin API name the folder of a session `folder`, not `cwd`. The `cwd` option of `Command`
  stays, as in Deno.
- Plugin API renames: `tui.input` is `tui.prompt`, `SessionHandle.cancel` is `cancelTurn`, a session id is
  `sessionId`, `Tui.focused` is `focusedView`, `Panes.active` is `activePane`, and `TextExtension.dispose` is
  `close`.
- `tui.styles.setTheme` and the `set*` methods of a text extension return a remover. `status.delete` is gone: call the
  remover of `status.set`.
- `yuke:chat` holds only the `chat` service. Its building blocks are internal.
- `ConnectionError` takes `(message, details)`, like `FileSystemError`.
- yuke no longer checks the shape of each plugin value. A wrong value fails where yuke uses it.
