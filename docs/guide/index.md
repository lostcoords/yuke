---
description: Install yuke, connect a model, and extend the terminal coding agent with plugins.
---

# Documentation

yuke is a fast, hackable coding agent for your terminal. Start with the [Quick start](get-started.md).

## Configure

- [Configuration](config.md): choose a profile, edit its files, and add plugin sources.
- [Providers](providers.md): add credentials, change a built-in provider, or connect a local model server.
- [AGENTS.md and skills](instructions.md): give the model project rules and reusable instructions.
- [MCP servers](mcp.md): connect local MCP servers and approve project servers.
- [Themes](themes.md): change colors and text styles.

## Run headless

- [One-shot tasks](one-shot.md): run one task with `-p` in a script or a CI job.
- [Embed with RPC](rpc.md): drive yuke from your own app over JSON-RPC.

## Extend

- [Your first plugin](first-plugin.md): add a command and check it against the public API.
- [Plugins](plugins.md): runtime and session entry points, cleanup, events, and services.
- [UI](ui.md): commands, keys, status items, and styles.
- [Tools](tools.md): define a model tool and return its result.
- [Engine](engine.md): engine hooks and the prompt.
