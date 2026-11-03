---
description: Add a terminal command with the public plugin API and check its types.
---

# Your first plugin

This tutorial adds one terminal command. It needs an installed yuke and TypeScript (`tsc`). It needs no model or provider credentials.

## 1. Find the profile

The default profile is `~/.config/yuke`. The [installer](profile.md) creates `tsconfig.json` there. That file extends the public library configuration of the installed release.

In a POSIX shell:

```sh
profile="${XDG_CONFIG_HOME:-$HOME/.config}/${YUKE_APPNAME:-yuke}"
mkdir -p "$profile/plugins"
mkdir "$profile/plugins/hello"
```

Use an unused folder and plugin name. If `hello` exists, choose another name. Change the paths and manifest to match.

## 2. Create the plugin

Create `plugins/hello/plugin.json` in the profile:

```json
{
  "name": "hello",
  "extensions": {
    "sh.yuke": {
      "entry": "./index.js"
    }
  }
}
```

Yuke reads `entry` from `extensions["sh.yuke"]`. The built-in `tui` service needs no `uses` entry.

Copy this code into `plugins/hello/index.js`:

<<< @/guide/examples/hello.js

The entry exports named `apply`. The loader does not call a default export. `apply` runs once per runtime.

`ctx.get("tui")` returns `undefined` in `yuke -p` and `yuke --rpc`. The early return skips terminal work in those modes. `ctx.notify` sends a notice with the plugin name as its source.

## 3. List the plugin

If the profile has no `config.json`, create it:

```json
{
  "plugins": ["./plugins/hello"]
}
```

Otherwise, add `"./plugins/hello"` to its existing `plugins` list. Keep the other settings and plugin paths. A relative path resolves against `config.json`.

## 4. Check the types

The installer configuration includes TypeScript files. This example uses JavaScript with JSDoc. Add JavaScript checks to the profile's `tsconfig.json`:

```jsonc
{
  // Keep the absolute "extends" path that the installer wrote.
  "extends": "/absolute/path/to/lib/yuke/tsconfig.json",
  "compilerOptions": {
    "allowJs": true,
    "checkJs": true
  },
  "include": ["./**/*.ts", "./**/*.js"],
  "exclude": ["./node_modules"]
}
```

Run the type check:

```sh
tsc -p "$profile/tsconfig.json"
```

A successful check exits without diagnostics. This checks types. It does not load the plugin or test the terminal.

## 5. Run the command

Start yuke:

```sh
yuke
```

Press `ctrl+g`. The command sends the notice **hi from hello**. You can also type `/hello:hi` in the composer. Press Enter to run the selected command.

The bare command name `hi` gets the plugin prefix `hello:`. The key binding uses the same prefix. Yuke removes both registrations when the plugin stops.

Change the notice text in `index.js`. Save the file. Run `/reload` when work is idle. Press `ctrl+g` again. Confirm that the new notice appears.

To remove the plugin, remove its path from `config.json`. Run `/reload`. The files can stay on disk.

## Next step

Read [Plugins](plugins.md) for session tools, hooks, services, and cleanup. Read [Terminal UI](ui.md) for commands and views. Read [Public types](types.md) for the installed API reference.
