---
name: yuke
description: Configures and extends the yuke coding agent. Use when the user wants to write or fix a yuke plugin, command, key binding, status item, theme, model tool, or engine hook; edit config.json, providers.json, or mcp.json; connect a provider; find out how to use the yuke TUI or its command line; or find out why a yuke change does not load.
---

# yuke

## Docs and API

The installed release keeps its guides and its API in `~/.local/lib/yuke/`. They match the installed binary, so read them and not the web.

- `docs/guide/index.md` lists the guides. Read the guide of the task before you edit a file.
- `docs/guide/use.md` lists the slash commands and the default keys of the TUI. `docs/guide/cli.md` lists each command and flag of `yuke`.
- `docs/guide/first-plugin.md` has a complete plugin: the manifest, the `config.json` entry, and the step "Check the types".
- `docs/guide/plugins.md` has the `plugin.json` reference (section "Plugin manifest"), the bundled plugins with their options and commands, and the rules of services.
- `docs/guide/tools.md` lists the built-in model tools. `docs/guide/instructions.md` has the rules of `AGENTS.md` and of skills.
- `modules/plugins.ts`, `modules/tools.ts`, and `types/*.d.ts` hold the exact API with doc comments. Search them for each name before you use it. The section "Find the API" of `docs/guide/plugins.md` tells which file holds which `yuke:*` module.
- `docs/guide/rpc.md` is the reference of `yuke --rpc`, and `protocol/bindings/` holds its TypeScript types.
- A guide line such as `<<< @/snippets/engine/approve.ts` includes the file `docs/snippets/engine/approve.ts`.

## Profile

The profile is `$XDG_CONFIG_HOME/$YUKE_APPNAME`, by default `~/.config/yuke`. `docs/guide/config.md` lists its files and the other folders. `auth.json` in the data folder holds the credentials. The data folder of a plugin is `plugins/<name>/` in the data folder: `ctx.dataDir`.

## Workflow

1. Edit `config.json`, or a plugin folder that `config.json` lists.
2. Run `tsc -p ~/.config/yuke/tsconfig.json`. Use TypeScript 7.0.2 or later: the section "Get `tsc`" of `docs/guide/first-plugin.md` tells how to get it. For a JavaScript plugin, do the step "Check the types" of that guide first.
3. To test behavior, write a `*.test.ts` file with `yuke:test` and run `yuke test PATH`. It uses a fake model and needs no credentials. Without `PATH`, it searches the current folder, and it fails when it finds no `*.test.ts` file.
4. Tell the user to type `/reload` in yuke when no turn runs. A plugin that does not load does not stop the others, and a notice reads "Plugin NAME did not load: REASON". A bad `config.json`, `plugins.lock`, or `providers.json` fails the reload and keeps the previous plugins and providers. After an edit of a Git plugin entry, run `yuke plugin sync`, because yuke downloads no plugin at startup.

## Rules

- Add model tools and engine hooks in the `session` export. Add UI in the `apply` export, and return when `ctx.get("tui")` is `undefined`, because `yuke -p` and `yuke --rpc` have no terminal.
- Use only the public `yuke:*` modules. Do not import `yuke:internal/*`, and do not reach a missing name through a cast or `any`.
- Pass `ctx.signal` or `s.signal` to async work. Return a cleanup function for work that the host does not own.
- Do not print `auth.json`, the header values of `providers.json`, or an API key.
- Do not edit `~/.local/lib/yuke/`. The installer replaces it at each update, and `yuke update` runs the installer. Keep the `extends` path of the profile `tsconfig.json`.

## Names

Use these names. An older name fails the type check.

- A session folder is `folder`, not `cwd`: `s.folder`, `context.folder`, `tui.startup.folder`, the `folder` option of `yuke:fs`, and the `folder` field of the protocol. The exceptions keep the name `cwd`: `Command` of `yuke:process` (as in Deno) and a server entry of `mcp.json`.
- A session id is `sessionId`: `s.sessionId`, `tui.startup.sessionId`, and the events of `ctx.addListener`.
- `SessionHandle.cancelTurn()` cancels a turn. `tui.prompt(options)` asks for a line of text. `tui.confirm(options)` asks a yes or no question.
- A registration returns a remover: `tui.status.set(id, entry)`, `tui.styles.setTheme(name)`, and the `set*` methods of a text extension. There is no `status.delete`: call the remover. `TextExtension.close()` removes a whole extension.
- `DisplayBlock` is in `yuke:protocol`. `yuke:chat` holds `ChatService` and the chat building blocks: `ChatSession`, `ChatComposer`, `ChatQuestions`, `ChatCompletions`, `ChatWorking`, `ChatDocument`, `slashCompletions`, and `composerRows`.
- `ConnectionError` takes `(message, details)`, as `FileSystemError` does: `new ConnectionError("text", { code: "ENOENT" })`.
- `yuke:test` has `folder()`: the scratch folder of one test.
- The keys of `providers.json` are camelCase, such as `apiKeyEnv`, `baseUrl`, and `reasoningLevels`. The values of an enum stay snake_case, such as `openai_chat`. A repeated provider or model id applies in file order, and the last wins. `apiKeyEnv` is an error on `openai-codex` and `xai-grok`.
- A plugin name is one folder name: not empty, not `.` or `..`, and with no `/` or `\`. It is the name in `plugin.json`.
- A skill name is any text that is not empty, and its `description` is required with at most 1024 characters. A skill with a bad front matter is skipped with a warning.
- `mcp.json` has stdio servers only. An entry with a `url` fails alone with "yuke supports only stdio servers".
- The terminal user interface is the TUI. A `message` is what a user sends. A `notice` is what a user reads.
