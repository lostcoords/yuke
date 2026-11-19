---
name: yuke
description: Configures and extends the yuke coding agent. Use when the user wants to write or fix a yuke plugin, command, key binding, status item, theme, model tool, or engine hook; edit config.json, providers.json, or mcp.json; connect a provider; or find out why a yuke change does not load.
---

# yuke

## Docs and API

The installed release keeps its guides and its API in `~/.local/lib/yuke/`. They match the installed binary, so read them and not the web.

- `docs/guide/index.md` lists the guides. Read the guide of the task before you edit a file.
- `docs/guide/first-plugin.md` has a complete plugin: the manifest, the `config.json` entry, and the step "Check the types".
- `modules/plugins.ts`, `modules/tools.ts`, and `types/*.d.ts` hold the exact API with doc comments. Search them for each name before you use it. The section "Find the API" of `docs/guide/plugins.md` tells which file holds which `yuke:*` module.
- `docs/guide/rpc.md` is the reference of `yuke --rpc`, and `protocol/bindings/` holds its TypeScript types.
- A guide line such as `<<< @/snippets/engine/approve.ts` includes the file `docs/snippets/engine/approve.ts`.

## Profile

The profile is `$XDG_CONFIG_HOME/$YUKE_APPNAME`, by default `~/.config/yuke`. `docs/guide/config.md` lists its files and the other folders. `auth.json` in the data folder holds the credentials.

## Workflow

1. Edit `config.json`, or a plugin folder that `config.json` lists.
2. Run `tsc -p ~/.config/yuke/tsconfig.json`. For a JavaScript plugin, do the step "Check the types" of `docs/guide/first-plugin.md` first.
3. To test behavior, write a `*.test.ts` file with `yuke:test` and run `yuke test PATH`. It uses a fake model and needs no credentials.
4. Tell the user to type `/reload` in yuke when no turn runs. A plugin that does not load does not stop the others, and a notice names it. A bad `config.json`, `plugins.lock`, or `providers.json` fails the reload and keeps the previous plugins and providers. After an edit of a Git plugin entry, run `yuke plugin sync`, because yuke downloads no plugin at startup.

## Rules

- Add model tools and engine hooks in the `session` export. Add UI in the `apply` export, and return when `ctx.get("tui")` is `undefined`, because `yuke -p` and `yuke --rpc` have no terminal.
- Use only the public `yuke:*` modules. Do not import `yuke:internal/*`, and do not reach a missing name through a cast or `any`.
- Pass `ctx.signal` or `s.signal` to async work. Return a cleanup function for work that the host does not own.
- Do not print `auth.json`, the header values of `providers.json`, or an API key.
- Do not edit `~/.local/lib/yuke/`. The installer replaces it at each update. Keep the `extends` path of the profile `tsconfig.json`.
