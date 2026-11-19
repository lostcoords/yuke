---
description: Add a TUI command with the public plugin API and check its types.
---

# Your first plugin

This tutorial adds one command to the TUI. It needs an installed yuke and TypeScript 7.0.2 or later (`tsc`). See [Get `tsc`](#get-tsc). It needs no model or provider credentials.

## 1. Find the profile

The default profile is `~/.config/yuke`. The installer creates `tsconfig.json` there. That file extends the public library configuration of the installed release.

In a POSIX shell:

```sh
profile="${XDG_CONFIG_HOME:-$HOME/.config}/${YUKE_APPNAME:-yuke}"
mkdir -p "$profile/plugins/hello"
```

If a plugin named `hello` exists, choose another name. Change the paths and manifest to match.

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

Copy this code into `plugins/hello/index.js`:

<<< @/guide/examples/hello.js

The entry exports a function named `apply`. It runs once per runtime. `ctx.get("tui")` returns `undefined` in `yuke -p` and `yuke --rpc`, so the early return skips TUI work in those modes. `ctx.notify` sends a notice with the plugin name as its source.

## 3. List the plugin

If the profile has no `config.json`, create it:

```json
{
  "plugins": ["./plugins/hello"]
}
```

Otherwise, add `"./plugins/hello"` to its existing `plugins` list. A relative path resolves against `config.json`.

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

A successful check exits without diagnostics. It checks types only. It does not load the plugin.

### Get `tsc`

The installed `tsconfig.json` uses recent options, such as `target: "es2025"` and `erasableSyntaxOnly`. Use TypeScript 7.0.2 or later. This is the version that yuke uses for its own checks. An older compiler can reject an option. Check the version with `tsc --version`.

TypeScript 7 has a native `tsc` binary. There are two ways to get it:

- Install it with npm in the profile folder: `npm install -D typescript`. Then run `npx tsc -p tsconfig.json`. The installed `tsconfig.json` excludes `node_modules`.
- Download the archive of your platform from the [TypeScript 7.0.2 release](https://github.com/microsoft/TypeScript/releases/tag/v7.0.2). The `tsc` binary is in the `lib` folder of the archive. Put it on your `PATH`.

## 5. Run the command

Start yuke:

```sh
yuke
```

Press `ctrl+g`. The command sends the notice **hi from hello**. You can also type `/hi` in the composer and press Enter.

yuke adds the plugin prefix `hello:` to the bare command name `hi` and to the key binding. The `slash` field gives the word that the composer lists. yuke removes both registrations when the plugin stops.

To change the notice, edit `index.js` and run `/reload` when work is idle. To remove the plugin, remove its path from `config.json` and run `/reload`.

## Next step

Read [Plugins](plugins.md) for session tools, hooks, services, and cleanup. Read [TUI plugin API](ui.md) for commands and views. Run `yuke test` to test the behavior of a plugin: see [Test and debug](plugins.md#test-and-debug). Read [Find the API](plugins.md#find-the-api) for the installed API reference.
