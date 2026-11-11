---
description: Install yuke on macOS, Linux, or Windows (WSL), then connect a model.
---

# Quick start

yuke runs in your terminal on macOS, Linux, and Windows (WSL). One binary holds the agent and the terminal UI. You need no plugin to run a task.

## Install yuke

```sh
curl -fsSL https://yuke.sh/install.sh | bash
```

The installer writes `~/.local/bin/yuke` and its library to `~/.local/lib/yuke`. It keeps your configuration. If `~/.local/bin` is not on your `PATH`, the installer tells you to add it.

The default channel installs the latest stable release. To select the nightly release instead:

```sh
curl -fsSL https://yuke.sh/install.sh | YUKE_CHANNEL=nightly bash
```

Check the installed version and commands:

```sh
yuke --version
yuke --help
```

These pages describe the current Rust and QuickJS implementation. An older release can have different commands and profile files. Check the help of your installed binary before you use a command from these pages.

## Connect a model

Set the API key of your provider in the shell that starts yuke:

```sh
export ANTHROPIC_API_KEY=sk-ant-...
```

For OpenAI, use `OPENAI_API_KEY`. See [Providers](providers.md) for the other variables and local servers. `yuke login` does not ask for API keys.

For an account login, run one of these commands instead:

```sh
yuke login openai-codex   # a ChatGPT account
yuke login xai-grok      # a Grok account
```

Open the URL that yuke prints. Confirm the code on that page. Wait for yuke to report a successful login. yuke stores the login in `auth.json` in the [data folder](config.md). `yuke logout <provider>` removes the stored credential. It does not unset an environment variable or revoke a token at the provider.

## Run your first task

Start in a project that you trust:

```sh
cd your-project
yuke
```

Type a small task, such as:

```text
Read this project and explain how to run its tests. Do not change files.
```

Press **Enter**. If the pane has no saved model choice, yuke asks for a model and a reasoning level. Select a model from your connected provider. Select `default` to let the model endpoint choose its reasoning behavior.

Read the answer and the tool results. Send a follow-up message to continue the task. **Esc** clears a selection or stops the active turn. **Ctrl+Q** exits yuke.

yuke reads `AGENTS.md` and lists the available skills in the model instructions. See [AGENTS.md and skills](instructions.md). Its tools run with your user rights. A task can read or change files and run commands. A request such as “Do not change files” is an instruction to the model, not a sandbox.

## Continue a conversation

From the same project directory, continue the conversation with the newest saved event:

```sh
yuke -c
```

To select a saved conversation by its ID:

```sh
yuke --resume ID
```

## Run one task without the UI

A new headless session needs both a model and a reasoning choice. For example, with `ANTHROPIC_API_KEY` set:

```sh
yuke -p 'Explain how to run the tests. Do not change files.' \
  --model anthropic/claude-sonnet-4-6 --reasoning default
```

yuke prints the final answer and exits. See [One-shot tasks](one-shot.md) for JSON output, follow-ups, and plugins in this mode.

## If the task does not start

- If the shell cannot find `yuke`, add `~/.local/bin` to `PATH`.
- If yuke reports no API key, set the provider variable in the shell that starts yuke.
- If an account login is missing or expired, run `yuke login <provider>` again.
- If a profile file fails to load, fix the file that the error names. Unknown configuration fields are errors.
- If a command is absent, check `yuke --help` and the installed version.

## Next steps

- Configure your profile: [Configuration](config.md).
- Add a local server or change a provider route: [Providers](providers.md).
- Give the model the rules of your project: [AGENTS.md and skills](instructions.md).
- Connect a local MCP server: [MCP servers](mcp.md).
- Run yuke in a script or a CI job: [One-shot tasks](one-shot.md).
- Learn the terminal controls: [Terminal UI](ui.md).
- Add a plugin after your first task works: [Your first plugin](first-plugin.md).
