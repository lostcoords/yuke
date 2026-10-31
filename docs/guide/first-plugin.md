# Your first plugin

This tutorial adds one TUI command. It needs an installed yuke and TypeScript (`tsc`). It does not need a model or provider credentials. Use the [isolated check](profile.md#isolated-check) first if you do not want to load your normal profile.

## 1. Find the profile

The default profile is `~/.config/yuke`. The [installer](profile.md#install-links) links its declarations and creates `jsconfig.json`. If you use another profile, install with that `YUKE_APPNAME` first so the type links exist there.

In a POSIX shell:

```sh
profile="${XDG_CONFIG_HOME:-$HOME/.config}/${YUKE_APPNAME:-yuke}"
mkdir -p "$profile/plugins"
mkdir "$profile/plugins/hello"
```

Use an unused folder and plugin name. If `hello` already exists, do not replace it. Choose another name and change the paths and manifest below.

## 2. Create the manifest and entry

The new files are:

```text
<profile>/
├── config.json
├── jsconfig.json
├── yuke.d.ts
├── yuke-modules.d.ts
├── yuke.jsconfig.json
└── plugins/
    └── hello/
        ├── plugin.json
        └── index.js
```

Create `plugins/hello/plugin.json`:

```json
{
  "name": "hello",
  "extensions": {
    "sh.yuke": {
      "entry": "./index.js",
      "uses": ["tui"]
    }
  }
}
```

Yuke reads its fields from `extensions["sh.yuke"]`. Top-level `entry` or `uses` fields do not configure this entry.

Create `plugins/hello/index.js`:

```js
/** Add a hello command when TUI is available. A failed registration throws. @param {import("yuke").Context} ctx */
export default function (ctx) {
  const tui = ctx.get("tui");
  if (!tui) return;
  tui.command.add("hi", {
    desc: "Say hi",
    slash: true,
    run: () => { ctx.interaction.notify("hi from hello"); },
  });
  ctx.print("hello loaded");
}
```

The same entry is in [`examples/hello.js`](examples/hello.js). CI type-checks that file. The plugin lists `tui` in `uses` before it calls `ctx.get("tui")`. The null check skips its TUI work in `yuke -p` and `yuke --rpc`.

## 3. List the plugin

If `config.json` does not exist, create it:

```json
{
  "plugins": ["./plugins/hello"]
}
```

If it exists, add `"./plugins/hello"` to its `plugins` list. Keep its other settings and plugin paths. Paths resolve against `config.json`, not the working directory.

## 4. Check the files

```sh
tsc -p "$profile/jsconfig.json"
yuke check
```

A successful type check exits without errors. A successful load prints `hello · debug: hello loaded` and finishes with `0 error(s), 0 warning(s)` when the rest of the profile is clean. A manifest or entry failure names the plugin. Fix that failure before reload.

`yuke check` runs all profile plugins and opens the session store. It is not read-only. The [isolated check](profile.md#isolated-check) verifies this example without using your normal profile files or credentials. It does not verify compatibility with your other plugins.

## 5. Load and run the command

Start yuke, or save a copy of your typed draft and run `/reload` after active runs and tool calls end. Reload reads the plugin files again. It replaces the JavaScript runtime and loses typed drafts. See the [reload rules](profile.md#check-a-change).

Open the ctrl+p palette. Run `hello:hi`, whose description is **Say hi**. The command posts **hi from hello**. You can also run `/hi`, because the command sets `slash: true`.

Change the notification text in the entry. Save the file. Run `/reload` again when work is idle. Run `hello:hi` and confirm the new text.

To remove the plugin, remove its path from `config.json` and reload. Reload removes its command. The files can stay on disk.

## Next step

Use the [mechanism chooser](customize.md#choose-a-mechanism) and [examples by task](customize.md#examples-by-task). Read [Plugins](plugins.md) before starting async work or sharing a capability. Read [Types](types.md) for exact declarations. Do not import `yuke:internal/*`.
