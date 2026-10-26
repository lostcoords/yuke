---
description: Install yuke, connect a model, and start the terminal UI in your project.
---

# Get started

yuke runs in your terminal on macOS and Linux. One binary holds the agent and the terminal UI.

## Install yuke

```sh
curl -fsSL https://yuke.sh/install.sh | bash
```

The installer writes `~/.local/bin/yuke` and its library to `~/.local/lib/yuke`. It keeps your configuration. If `~/.local/bin` is not on your `PATH`, the installer tells you to add it.

To install the latest build of `main` instead of the latest release, set the channel:

```sh
curl -fsSL https://yuke.sh/install.sh | YUKE_CHANNEL=nightly bash
```

## Connect a model

Give yuke an API key in an environment variable, such as `ANTHROPIC_API_KEY` or `OPENAI_API_KEY`:

```sh
export ANTHROPIC_API_KEY=sk-ant-...
```

Or log in with an account. The provider ID is the first part of a model name:

```sh
yuke login openai-codex   # a ChatGPT account
yuke login xai-grok       # a Grok account
```

yuke saves the login in `auth.json`, and `yuke logout <provider>` removes it. To use a local model server, add it to `providers.json`. See [Providers](providers.md).

## Start yuke

```sh
cd your-project
yuke
```

yuke opens the terminal UI in the current directory. It reads `AGENTS.md` and your skills as instructions for the model.

## Next steps

- Add a command, a key, or a model tool: [your first plugin](first-plugin.md).
- Learn what a profile holds: [Profile](profile.md).
- Choose the right extension point: [Customize yuke](customize.md).
