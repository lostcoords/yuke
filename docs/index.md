---
layout: home
title: Unleash your harness
titleTemplate: 'yuke: :title'
description: yuke is a local, hackable harness for LLM agents. Plugins add commands, keys, tools and hooks to a fast TUI, and every provider and local model plugs in.
kicker: Local / Open / Hackable
tagline: yuke is a local, hackable harness for LLM agents. A fast terminal UI that you reshape with plugins, with any model behind it.
---

## Run yuke

### Install it

```sh
curl -fsSL https://yuke.sh/install.sh | bash
```

The installer writes one binary to `~/.local/bin` and its library to `~/.local/lib/yuke`. It keeps your configuration.

### Connect a model

```sh
export ANTHROPIC_API_KEY=sk-ant-...
```

Set the API key of any built-in provider, or log in with an account: `yuke login openai-codex` for ChatGPT and `yuke login xai-grok` for Grok. A local model server is one entry in `providers.json`.

### Start it

```sh
cd your-project
yuke
```

yuke reads `AGENTS.md` and your skills, and opens the TUI.

### Add your first command

Save a plugin folder in your profile and list it in `config.json`:

```js
export default function (ctx) {
  const tui = ctx.get("tui");
  if (!tui) return;
  tui.command.add("hi", {
    desc: "Say hi",
    slash: true,
    run: () => { ctx.interaction.notify("hi from hello"); },
  });
}
```

Run `/reload` and type `/hi`. The same API adds keys, status items, dialogs, model tools and engine hooks.
