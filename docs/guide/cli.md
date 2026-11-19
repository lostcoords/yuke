---
description: Every command and flag of the yuke command line, with its use and the guide that explains it.
---

# Command line

```text
yuke [OPTIONS]
yuke <COMMAND>
```

A flag and a command do not mix. Use a command alone. `yuke --help` and `yuke COMMAND --help` give the same lists.

## Run yuke

| Command | What it does |
|---|---|
| `yuke` | Start the TUI. See [Use the TUI](use.md). |
| `yuke -c` | Start the TUI with the newest session of the current folder. |
| `yuke -r ID` | Start the TUI with the session `ID`, in any folder. |
| `yuke -p PROMPT` | Run one task, print the last answer, and exit. See [One-shot tasks](one-shot.md). |
| `yuke --rpc` | Serve the yuke protocol on stdin and stdout. See [Embed with RPC](rpc.md). |
| `yuke --version` | Print the version. `-V` is the short form. |
| `yuke --help` | Print the help. `-h` is the short form. |

## Options

| Option | Use |
|---|---|
| `-p`, `--print PROMPT` | Run one task with `PROMPT`. `PROMPT` is not empty. |
| `--json` | With `-p`: print one JSON object with `sessionId`, `end`, and `text`, in place of the answer. |
| `--model PROVIDER/MODEL` | With `-p`: select the model, such as `anthropic/claude-sonnet-4-6`. A new session needs it. It needs `--reasoning` too. |
| `--reasoning LEVEL` | With `-p`: select the reasoning level: `default`, `off`, or an effort such as `low` or `high`. A new session needs it. |
| `-r`, `--resume ID` | Resume the session `ID`, in any folder. It works with the TUI and with `-p`. It does not mix with `-c`. |
| `-c`, `--continue` | Continue the session of the current folder with the newest event. It works with the TUI and with `-p`. |
| `--rpc` | Serve the protocol on stdin and stdout. It does not mix with `-p`, `--json`, `--model`, `--reasoning`, `-r`, or `-c`. |
| `--listen unix://PATH` | With `--rpc`: serve the clients of a Unix socket, one at a time. The sessions outlive each client. |
| `--connect unix://PATH` | With `--rpc`: join stdin and stdout to the server of a Unix socket. It does not mix with `--listen`. |

For the models and the credentials, see [Providers](providers.md). For the exit status of `-p`, see [One-shot tasks](one-shot.md#exit-status). For the socket and the protocol, see [Embed with RPC](rpc.md#transports).

## Connect a provider

| Command | What it does |
|---|---|
| `yuke login PROVIDER` | Log in with a device code, and save the login in `auth.json`. Only a provider with an account login has this flow: `openai-codex` and `xai-grok`. For an API key, run `/login` in the TUI, or set the variable of the provider. |
| `yuke logout PROVIDER` | Remove the login or the API key that `/login` stored for `PROVIDER`. A key in an environment variable stays. |

See [Providers](providers.md#credentials).

## Test a plugin

| Command | What it does |
|---|---|
| `yuke test [PATHS]...` | Run the tests of `yuke:test` in the `*.test.ts` files at `PATHS`. A path is a file or a folder. Without `PATHS`, yuke searches the current folder. The command fails when it finds no test file, and when a test fails. Each test runs in its own app with a fake model. |

See [Test and debug](plugins.md#test-and-debug).

## Manage plugins

| Command | What it does |
|---|---|
| `yuke plugin list` | Show each plugin of `config.json` and its state. It uses no network. |
| `yuke plugin sync [--locked]` | Install the commits of `plugins.lock`, and lock each new Git plugin. With `--locked`, fail when `plugins.lock` does not match `config.json`, and never write it. |
| `yuke plugin update [--all] [--yes] [NAME]...` | Move Git plugins to the newest commit of their ref. It shows the log and asks before it writes `plugins.lock`. Give `--all` or at least one `NAME`. `--all` selects every Git plugin, `--yes` skips the question, and `NAME` selects a plugin. |
| `yuke plugin add URL [NAME]... [--ref REF]` | Add the plugins of a Git repository to `config.json`, install them, and lock them. A repository with one plugin needs no `NAME`. `--ref` selects the branch, tag, or commit to follow. |
| `yuke plugin remove NAME` | Remove a plugin from `config.json` and `plugins.lock`. Its files stay on disk. |

`NAME` is the `name` of the `plugin.json` of the plugin. See [Plugins](plugins.md#install-plugins).

After a change, run `/reload` in the open sessions.
