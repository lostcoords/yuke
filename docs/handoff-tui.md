# TUI handoff — remaining work

Look-and-feel and multi-device decisions: `docs/tui-design.md`.

The chat pane talks to real sessions: the transcript is virtualized over the native replica
(`sessionOutline` + on-demand `sessionText`), streaming folds live via `{type:"session", kind, id}`
events, and a session subscribes on open (reconnect re-opens the last one). The composer now submits
(`client.sessionSendInput` → `chatSession.send`), `Ctrl+C` interrupts the run and flushes the queue
(`sessionCancelRun(id, true)`), and `Ctrl+Q` quits. A shared `TextInput` buffer (`yuke:core`) owns
single-line editing + caret for the composer, picker query, and `:` line. The codebase is the source
of truth for what is done; this lists only what is left.

## Rich parts + permissions
`sessionText` returns text parts only (`src/tui/session.odin`); reasoning/tool/permission parts are
dropped. Needs a part-renderer, and outline/`sessionText` extended to carry part kinds. Permission
parts are the unlock: with send/interrupt in place, an approval prompt (`permission.decide`) over the
active-draft `Tool_Part` in `Tool_State_Waiting_Permission` makes tool use usable.

## Activity + status line
Interrupt has no on-screen feedback — the run just stops. The replica does not expose the open
session's live activity (only `session.list` items carry it). Expose it (a native `sessionActivity()`)
and render a root status line with the activity verb ("Working…/Thinking…/Stopped"). This also lets
`Ctrl+C` decide interrupt-when-busy vs a Codex-style quit-when-idle if that is ever wanted.

## Picker consolidation (separate refactor)
`Picker` and `PickerContent` duplicate the keymap-dispatch + `closeOnAccept` block in `ui.js`.
Consolidating the two picker classes is larger — note, don't bundle.

## Transcript v2 (behind the `rowSource` seam)
- LRU-evict off-screen wrapped rows so JS holds ~viewport, not the whole resident window.
- Message-id scroll anchor: the raw row-index offset drifts on eviction/resize above the viewport.
- `hasMore` "load older": the resident window caps at `max_page_size`, so scroll-to-top is the
  window start, not the session start. The outline carries `hasMore`; JS ignores it.

## Other
- Full-screen chat: sidebar → overlay finder; per-pane footers → one root status line.
- Connection service → a plugin (still on `root.addService`).
- Reconnect: recovered on the ready-edge, but a resize *during* a disconnect blanks the transcript
  (cache cleared, no live replica) until reconnect.

## Design decisions (the why — not obvious from the code)

**Keymap — modeless default + opt-in vim ("Design 2").** Global commands live on Ctrl strokes so
they never collide with typing: `Ctrl+P` palette, `Ctrl+F` sessions, `Ctrl+K <h/j/k/l|arrows>`
window nav, `Ctrl+C` interrupt, `Ctrl+Q` quit. No bare-key leaders. `Ctrl+C`/`Ctrl+Q` are safe keys
(not signals) because raw mode clears `ISIG`/`IXON` (`src/term/tty_posix.odin`); `Esc` is left to vim
and overlays, not interrupt. This is the VS Code `when`-clause / Zed / herdr model — one prefix,
everything else free for the focused input. (VS Code when-clause contexts; Zed key bindings.)

**Vim (`yuke:vim`) — opt-in, Zed-consistent.** Off by default; enable via `config.vim` in
`yuke.js` or the `vim:toggle` palette command. Built as a bundled plugin — a self-contained module
layered over the base, mirroring Zed's `crates/vim` — with the composer `mode` as the
`vim_mode == normal` context. Normal disables composer input so bare keys become commands (`:`,
`j/k/gg/G`, `i/a`, `Esc`); non-text keys route to scroll/leaders. User-extensible via the `vim`
service + `vim:mode` event. Kept minimal (normal/insert only — not Zed's 8 modes). (Zed vim docs;
Zed defaults to emacs-style, vim is opt-in like readline `set -o vi`.)

**Transcript virtualization — Neovim single-source model.** The native replica owns the text once;
JS pulls the outline + each message's text on demand — Neovim's `nvim_buf_get_lines` shape (the
host owns the buffer, the script reads ranges, callbacks don't ship the data; the script holds a
handle, not a copy). Two options were weighed: **Option 1** native layout (Odin wraps and returns
finished rows — leanest memory, Neovim-literal, but wrapping/rendering moves into Odin) vs
**Option 2** JS layout + on-demand text (rendering stays in JS, future markdown/highlight-friendly).
Chose **Option 2** behind the `rowSource` seam (`rowCount`/`rows`); Option 1 is a clean,
pre-planned escape hatch if profiling ever demands it. (Neovim buffer management / `nvim_buf_get_lines`.)

## Build / drive
```
./build.py test tui        # unit tests
./build.py yuke            # build build/yuke
tmux new-session -d -s tui -x 110 -y 30
tmux send-keys -t tui './build/yuke' Enter
tmux send-keys -t tui Enter     # open the top session
tmux send-keys -t tui C-k l     # ctrl+k then l: focus the chat pane
tmux capture-pane -p -t tui
tmux kill-session -t tui
```
Live streaming needs a second client (`../yuke-client`, browser) sending into the open session.
