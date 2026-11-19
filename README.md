# yuke

yuke is a fast, hackable coding agent. Its TUI is built from TypeScript plugins, and you can change each part of it.
Any model can run behind it.

- **One native binary.** yuke needs no Node, no Python, and no Electron.
- **Plugins all the way down.** Commands, key bindings, status items, themes, dialogs, and the transcript come from
  plugins. Replace a bundled part, such as the chat, with your own.
- **Engine hooks.** A hook sees each input, prompt, round, and tool call. It can deny a tool call or change its result.
- **Tools and MCP.** Give the model a new tool in a few lines of TypeScript, or connect MCP servers over stdio.
- **Any provider.** Set an API key, or log in with a ChatGPT or Grok account. Add a local server in `providers.json`.
- **Sessions.** yuke saves each session. Resume it, fork it, or compact it.
- **Headless.** Run one task with `yuke -p`, or embed yuke in your app with `yuke --rpc`. Your plugins work in each
  mode.

## Install

```sh
curl -fsSL https://yuke.sh/install.sh | bash
```

The installer writes `~/.local/bin/yuke` and `~/.local/lib/yuke`. It keeps your configuration.
yuke runs on macOS and Linux, on x86-64 and arm64. On Windows, use WSL.

## Quick start

Open the TUI in your project:

```sh
cd your-project
yuke
```

Type `/login` and choose a provider. Paste an API key, or log in with a ChatGPT or Grok account. In a script or CI,
set the variable of the provider instead, such as `ANTHROPIC_API_KEY`.

Type a task and press Enter. At the first task, yuke asks for a model and a reasoning level. `/model` changes them.
yuke reads `AGENTS.md` and your skills into the prompt of each new session.

## Your first plugin

A plugin is a folder with a `plugin.json` and an entry module:

```js
export function apply(ctx) {
  const tui = ctx.get("tui");
  if (!tui) return undefined;

  tui.commands.add({
    name: "hi",
    description: "Say hi",
    slash: "hi",
    run: () => ctx.notify("info", "hi from hello"),
  });
  tui.keys.add("ctrl+g", "hi");
  return undefined;
}
```

List the folder in `config.json`, run `/reload`, and type `/hi`. [Your first plugin](https://yuke.sh/docs/first-plugin)
gives each step.

## Documentation

- [Quick start](https://yuke.sh/docs/get-started)
- [Use the TUI](https://yuke.sh/docs/use) · [Command line](https://yuke.sh/docs/cli)
- [Configuration](https://yuke.sh/docs/config) · [Providers](https://yuke.sh/docs/providers) ·
  [AGENTS.md and skills](https://yuke.sh/docs/instructions) · [MCP servers](https://yuke.sh/docs/mcp) ·
  [Themes](https://yuke.sh/docs/themes)
- [One-shot tasks](https://yuke.sh/docs/one-shot) · [Embed with RPC](https://yuke.sh/docs/rpc)
- [Plugins](https://yuke.sh/docs/plugins) · [TUI plugin API](https://yuke.sh/docs/ui) ·
  [Tools](https://yuke.sh/docs/tools) · [Engine](https://yuke.sh/docs/engine)

The Markdown of each guide is in [docs/guide](docs/guide). See [CHANGELOG.md](CHANGELOG.md) for the changes of each
release.

## Development

yuke is a Rust workspace. [mise](https://mise.jdx.dev) installs the pinned Rust, TypeScript, and Biome. Run every tool
through it:

```sh
mise exec -- cargo run --package yuke
```

Run `mise run check` before you commit. To run the format checks at each commit, set the hooks folder:

```sh
git config core.hooksPath .githooks
```

See [Package tools](tools/README.md) for the build, install, and release commands.

## License

[MIT](LICENSE.md)
