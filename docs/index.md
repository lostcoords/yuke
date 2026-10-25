---
layout: home
title: Unleash your harness
titleTemplate: 'yuke: :title'
description: yuke is a terminal coding agent that you can reshape. Plugins add commands, keys, tools and hooks, and every provider and local model works from one TUI.
hero:
  text: Unleash your harness
  tagline: A terminal coding agent that you can reshape. Plugins add commands, keys, tools and hooks. Every model plugs into the same fast TUI.
  actions:
    - theme: brand
      text: Install yuke
      link: '#run-yuke'
    - theme: alt
      text: GitHub
      link: https://github.com/lostcoords/yuke
---

## Run yuke

### Install it

```sh
curl -fsSL https://yuke.sh/install.sh | bash
```

The installer writes one binary to `~/.local/bin` and its library to `~/.local/lib/yuke`. It keeps your configuration.

### Connect a model

```sh
yuke login
```

`yuke login` lists each provider and its state. Use an API key, or log in with a ChatGPT or Grok account. A local model server is one entry in `providers.json`.

### Start it

```sh
cd your-project
yuke
```

yuke reads `AGENTS.md` and your skills, and opens the TUI. `yuke resume <id>` opens a saved conversation again.

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
