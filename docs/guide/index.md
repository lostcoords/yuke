---
description: Install yuke, connect a model, and extend the terminal coding agent with plugins.
---

# Documentation

yuke is a fast, hackable coding agent for your terminal. These docs show how to use it, configure it, run it headless, and extend it with plugins.

New to yuke? Start with the [Quick start](get-started.md) to install yuke, connect a model, and run a first task.

## Configure

- [Configuration](config.md): the profile, its files, and plugin sources.
- [Providers](providers.md): credentials, built-in providers, and local model servers.
- [AGENTS.md and skills](instructions.md): give the model project rules with `AGENTS.md`, and reusable instructions with skills.
- [MCP servers](mcp.md): connect local MCP servers, and approve the servers of a project.
- [Themes](/docs/themes): change colors and text styles.

## Headless

- [One-shot tasks](one-shot.md): run one task with `-p` in a script or a CI job.
- [Embed with RPC](rpc.md): drive yuke from your own app over the JSONL protocol.

## Extend

- [Customize yuke](customize.md): choose the right extension point for a task.
- [Your first plugin](first-plugin.md): add a command and check it against the public API.
- [Plugins](plugins.md): runtime and session entry points, cleanup, events, and services.
- [UI](ui.md): commands, keys, views, status items, and dialogs.
- [Tools](tools.md): define a model tool and return its result.
- [Engine](engine.md): hooks, model requests, forks, and subagents.
- [Types](types.md): find public types and check a plugin.
