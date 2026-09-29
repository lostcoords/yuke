# Customize yuke

yuke loads one JavaScript profile at startup. The profile adds commands, keys, tools, hooks, and plugins, and it sets the config. You do not need the yuke source: the profile holds `yuke.d.ts`, which declares every public API with a summary.

| Page | Read it to |
|---|---|
| [Profile](profile.md) | find the profile, learn which files to edit, and check a change |
| [Plugins](plugins.md) | write a plugin: lifecycle, events, capabilities, advice, and bundled plugins |
| [UI](ui.md) | add commands, keys, status bar items, styles, and dialogs |
| [Engine](engine.md) | add model tools and hooks, set the config and the prompt, and add subagents and MCP servers |
| [Types](types.md) | type your own events and capabilities, and check the profile in an editor |

The examples in `examples/` are complete files. CI type-checks each one against `yuke.d.ts`.
