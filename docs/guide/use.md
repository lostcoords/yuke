---
description: Send messages, complete files and commands, and use the default slash commands and keys of the yuke TUI.
---

# Use the TUI

Run `yuke` in a project folder to start the TUI. The screen has three parts:

- The transcript shows the session: your messages, the answers, and the tool calls.
- The composer is the text field below the transcript. You type there.
- The status bar in the last row shows the folder, the model with its reasoning level, the token share of the last answer, and the number of running commands. While you type a key sequence, it shows the keys so far.

A notice appears in the top right corner. `/messages` shows the last notices.

To start, a model must be ready. See [Quick start](get-started.md#connect-a-model). For the flags of the `yuke` command, see [Command line](cli.md).

## Send a message

Type in the composer and press `enter`. The model answers in the transcript.

- `shift+enter`, `alt+enter`, or `ctrl+j` adds a new line.
- A paste of more than 300 characters shows as a label, such as `[Pasted text · 1200 chars]`. yuke sends the whole text.
- `ctrl+v` puts the image of the clipboard in the message. The composer shows `[image 1]`. yuke scales the image before it stores the image.
- If yuke has no saved model choice, it asks for a model and a reasoning level at the first message. It saves the choice for new sessions.

You can send a message while the model works. The message waits, and it joins the turn at its next round. While a message waits, `up` takes it back into the composer, so you can edit it.

## Send an old message again

With an empty composer, press `up` to show an older message of yours. Press `up` again for an older one, and `down` for a newer one. After the newest message, `down` shows the empty composer. Edit the text, and press `enter` to send it again.

## Mention a file with `@`

Type `@` at the start of the draft or after a space. A list shows the files and folders that match the text after `@`.

- `up` and `down` select an item.
- `tab` or `enter` writes the path in the draft. For a file, yuke adds a space. For a folder, the list goes on into the folder.
- `esc` hides the list.

A path with whitespace goes in double quotes. The draft keeps the path as plain text. The model reads the file with its tools.

In a Git folder, the list holds the tracked files and the untracked files that no ignore rule takes. In another folder, the list holds the files below it. It skips hidden entries, `node_modules`, and `target`. The list shows at most 50 items.

## Run a slash command

Type `/` at the start of the draft. A list shows the commands that match. `up` and `down` select a command. `tab` writes its word, and `enter` runs it.

Some commands take text after the word, such as `/login anthropic`. A draft that starts with `/` and names no command stays a message.

| Command | What it does |
|---|---|
| `/login [PROVIDER]` | Connect a provider. For an API key, paste the key. For an account, open the page that yuke shows and confirm the code. In that dialog, `o` opens the page, `c` copies the code, and `u` copies the URL. |
| `/logout [PROVIDER]` | Remove the API key or the login that yuke stored for a provider. A key in an environment variable stays: unset the variable. |
| `/mcp [SERVER \| logout SERVER]` | List the MCP servers of the session with their states. Choose a server that needs a login to open its dialog. `/mcp SERVER` picks a server by name, and `/mcp logout SERVER` removes its stored login. See [MCP servers](mcp.md#oauth-login). |
| `/model` | Choose the model and the reasoning level of the session. It fails while a turn runs or a message waits. |
| `/new` | Start a new session in the pane. The old session keeps its work, and `/sessions` finds it. |
| `/rename` | Rename the session in a dialog. |
| `/sessions` | Show the recent sessions of this folder, and show one in the pane. `tab` switches between this folder and every folder. Type to filter. |
| `/plugins` | Manage your plugins. See [Plugins](plugins.md#install-plugins). |
| `/themes` | Choose a theme. The arrow keys show a theme, `enter` keeps it, and `esc` goes back. See [Themes](themes.md). |
| `/messages` | Show the last notices, newest first. |
| `/reload` | Read the configuration, the providers, and the plugins again. Wait for active turns to end first. |
| `/quit` | Quit yuke, as `ctrl+q` does. |

A plugin can add more commands. See [TUI plugin API](ui.md#commands).

## Stop work

- `ctrl+c` clears the draft. With an empty composer, it stops the turn.
- `esc` drops the selection in the transcript. Without a selection, it stops the turn.
- `ctrl+b` moves the tool calls that wait for a command, such as a running `exec`, to the background. The turn goes on.

The working row above the composer shows the key that stops the turn, as `esc to interrupt`. After a tool call has waited for two seconds, it shows `ctrl+b to background` too. A stop keeps the session: send the next message to go on.

## Answer a question

A plugin or a hook can ask you a question. For example, an [approval hook](engine.md#approve-a-tool-call) asks before it lets a tool run. The question replaces the composer.

- `up` and `down` select an option.
- `space` ticks an option, when the question takes more than one.
- `enter` goes to the next question, or sends the answers.
- `left` or `shift+tab` goes back.
- `esc` or `ctrl+c` cancels the question.

## Read the transcript

- `pageup` and `pagedown` scroll one page, and `ctrl+home` and `ctrl+end` go to the top and the bottom. The mouse wheel scrolls too.
- `ctrl+o` opens or folds the tool calls.
- Drag the mouse to select text. yuke copies the selection when you release the button.

## Use panes

The TUI can show more than one session. Each pane has its own session, composer, and scroll place. Press `ctrl+k`, then one key:

| Keys | Action |
|---|---|
| `ctrl+k v` | Split the pane to the right. |
| `ctrl+k s` | Split the pane down. |
| `ctrl+k c` | Close the pane. |
| `ctrl+k w` | Focus the next pane. |
| `ctrl+k h`, `ctrl+k j`, `ctrl+k k`, `ctrl+k l` | Focus the pane on the left, below, above, or on the right. |
| `ctrl+k left`, `ctrl+k down`, `ctrl+k up`, `ctrl+k right` | The same, with the arrow keys. |

`esc` after `ctrl+k` cancels the sequence.

## Continue a session

yuke saves each session. Start yuke with `-c` to continue the newest session of the folder, or with `-r ID` to continue a session by its ID. See [Command line](cli.md). In the TUI, `/sessions` shows a saved session in the pane.

When you quit, yuke prints `To resume this session, run: yuke -r ID` for each session that the panes show.

## Quit

Press `ctrl+q` or type `/quit`. If a turn or a job runs, yuke asks "Stop everything and quit?". `enter` or `ctrl+q` stops the work and quits. `esc` stays.

`ctrl+z` suspends yuke to the shell.

## Keys

This list holds the default keys of yuke. A plugin can add more. See [TUI plugin API](ui.md#keys).

### Chat pane

| Key | Action |
|---|---|
| `enter` | Send the message. |
| `shift+enter`, `alt+enter`, `ctrl+j` | Add a new line. |
| `up`, `down` | Show an older or a newer message of yours, or take back a waiting message. |
| `ctrl+v` | Put the image of the clipboard in the message. |
| `ctrl+c` | Clear the draft, or stop the turn. |
| `esc` | Drop the selection, or stop the turn. |
| `ctrl+b` | Move the waiting tool calls to the background. |
| `ctrl+o` | Open or fold the tool calls. |
| `pageup`, `pagedown` | Scroll one page. |
| `ctrl+home`, `ctrl+end` | Scroll to the top or to the bottom. |
| `ctrl+k m` | Choose the model (`/model`). |
| `ctrl+k n` | Start a new session in the pane (`/new`). |

### Everywhere

| Key | Action |
|---|---|
| `ctrl+q` | Quit. |
| `ctrl+z` | Suspend yuke to the shell. |
| `ctrl+l` | Dismiss the notices on screen. |
| `ctrl+k v`, `ctrl+k s`, `ctrl+k c` | Split right, split down, and close a pane. |
| `ctrl+k w`, `ctrl+k h`, `ctrl+k j`, `ctrl+k k`, `ctrl+k l` | Move the focus between panes. |
| `esc` | Close the dialog on top. |

### Text field

The composer and each text field of a dialog take these keys:

| Key | Action |
|---|---|
| `left`, `right`, `up`, `down`, `home`, `end` | Move the caret. `ctrl+a` and `ctrl+e` go to the start and the end of the line. With an empty composer, `up` and `down` work on the old messages first. |
| `alt+b`, `alt+f`, `ctrl+left`, `ctrl+right` | Move by one word. |
| `shift` with a move key | Select text. |
| `backspace`, `delete` | Delete a character, or the selection. |
| `ctrl+w`, `alt+backspace` | Delete the word before the caret. |
| `alt+d` | Delete the word after the caret. |
| `ctrl+u` | Delete to the start of the line. |

### Lists and dialogs

| Key | Action |
|---|---|
| `up`, `down` | Select an item. |
| `enter` | Choose the selected item. |
| `esc` | Close the list. |
| `tab` | In the composer list, write the selected item. In `/sessions`, switch the folder scope. |

For the keys of the `/plugins` dashboard, see [Plugins](plugins.md#install-plugins).
