# Customize yuke

yuke loads one JavaScript profile at startup. A profile can add commands, keys, status items, model tools, event listeners, engine hooks, optional plugins, and config.

## Documentation order

1. **Markdown guides** explain concepts and common recipes.
2. **`yuke.d.ts`** is the authoritative reference for exact public names, types, signatures, null values, and errors.
3. **`examples/`** contains complete patterns that CI type-checks against the declarations.
4. **Source inspection** is a last resort for undocumented behavior and implementation details.

An installed release puts these guides in `~/.local/lib/yuke/docs/`. The installer links `yuke.d.ts` into the [profile](profile.md). See [Types](types.md#find-a-declaration) for focused `grep` commands. Do not infer a public API from an implementation name that is absent from `yuke.d.ts`.

| Page | Read it to |
|---|---|
| [Profile](profile.md) | find the profile, learn its startup modes, and verify a change |
| [Providers](providers.md) | configure credentials, providers, and local model servers |
| [Plugins](plugins.md) | write a plugin and customize events, chat, or bundled plugins |
| [UI](ui.md) | add commands, keys, status items, styles, and dialogs |
| [Vim](vim.md) | enable composer Vim or transcript Vim |
| [Tools](tools.md) | define a model tool and return its result |
| [Engine](engine.md) | add hooks, subagents, and MCP servers |
| [Types](types.md) | find declarations and type custom events or capabilities |

Start with [`examples/plugin.js`](examples/plugin.js). Other complete examples cover a [Herdr lifecycle integration](examples/herdr.js), [chat APIs](examples/chat-api.js), [subagents](examples/agents.js), [MCP](examples/mcp.js), and a [replacement chat pane](examples/roomy-chat.js).
