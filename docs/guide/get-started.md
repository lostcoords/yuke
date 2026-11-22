---
description: Install yuke on macOS, Linux, or Windows (WSL), then connect a model.
---

# Quick start

yuke runs in your terminal. One binary holds the agent and the TUI.

## Platforms

- macOS and Linux, on x86-64 and arm64.
- Windows, through WSL. Install yuke inside the WSL distribution, as on Linux.

Native Windows is planned. It is not in 0.1.0.

## Install yuke

```sh
curl -fsSL https://yuke.sh/install.sh | bash
```

The installer writes `~/.local/bin/yuke` and its library to `~/.local/lib/yuke`. It also links the yuke agent skill at `~/.agents/skills/yuke`, so yuke and other coding agents know how to configure and extend yuke. It keeps your configuration. If `~/.local/bin` is not on your `PATH`, the installer tells you to add it.

The default channel installs the latest stable release. To select the nightly release instead:

```sh
curl -fsSL https://yuke.sh/install.sh | YUKE_CHANNEL=nightly bash
```

To install one release, such as an older one:

```sh
curl -fsSL https://yuke.sh/install.sh | YUKE_VERSION=0.1.0 bash
```

Check the installed version and commands:

```sh
yuke --version
yuke --help
```

### Update yuke

```sh
yuke update
```

The command installs the newest release of your channel. Restart the open sessions after an update. See [Command line](cli.md#update-yuke).

### Uninstall yuke

Remove the binary, the library, and the skill link:

```sh
rm -rf ~/.local/bin/yuke ~/.local/lib/yuke ~/.agents/skills/yuke
```

This keeps your configuration, sessions, and credentials. To remove them too, delete the config, data, and cache folders of [Configuration](config.md). With the default folders, run:

```sh
rm -rf ~/.config/yuke ~/.local/share/yuke ~/.cache/yuke
```

The data folder holds your sessions and `auth.json`. A deleted session cannot return.

## Connect a model

Start yuke, then type `/login` and press **Enter**:

```sh
yuke
```

Choose your provider. For an API key, paste the key. For a ChatGPT or Grok account, open the page that yuke shows and confirm the code. yuke stores the key or the login in `auth.json` in its data folder. Use `/logout` to remove it.

In CI or a script, set the provider variable instead, such as `ANTHROPIC_API_KEY`. See [Providers](providers.md) for the variables and local servers.

## Run your first task

Start in a project that you trust:

```sh
cd your-project
yuke
```

Type a small task and press **Enter**:

```text
Read this project and explain how to run its tests. Do not change files.
```

If yuke has no saved model choice, it asks for a model and a reasoning level. yuke saves the choice for new sessions. Use `/model` to change it.

Send a follow-up message to continue the task. **Esc** drops a selection or stops the active turn. **Ctrl+Q** exits yuke. See [Use the TUI](use.md) for the other keys and the slash commands.

yuke reads `~/.agents/AGENTS.md` and the `AGENTS.md` of the project. See [AGENTS.md and skills](instructions.md). Its tools run with your user rights, so a task can read or change files and run commands. A request such as "Do not change files" is an instruction to the model, not a sandbox.

## Continue a session

From the same project folder, continue the newest session:

```sh
yuke -c
```

To select a saved session by its ID, in any folder:

```sh
yuke --resume ID
```

## If the task does not start

- If the shell cannot find `yuke`, add `~/.local/bin` to `PATH`.
- If yuke says that no provider is ready, run `/login`. If a request fails with `no API key for PROVIDER` or `no login for PROVIDER`, run `/login PROVIDER`, or set the provider variable.
- If a profile file fails to load, fix the file that the error names. Unknown configuration fields are errors.

## Next steps

- [Use the TUI](use.md): learn the composer, the slash commands, and the keys.
- [Command line](cli.md): see each command and flag of `yuke`.
- [Configuration](config.md) and [Providers](providers.md): set up your profile and your models.
- [AGENTS.md and skills](instructions.md): give the model the rules of your project.
- [MCP servers](mcp.md): connect a local MCP server.
- [One-shot tasks](one-shot.md): run yuke in a script or a CI job.
- [Your first plugin](first-plugin.md): add a plugin after your first task works.
