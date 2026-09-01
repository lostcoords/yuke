# Terminal design — the yuke TUI native layer

Status: current architecture note.
Source of truth: `lib/term/`, `src/tui/`, and the bundled JavaScript modules.
Last verified: 2026-08-31.

The TTY, parser, two-grid render, owner channel, tick task, daemon client, `app.run`, `report.zig`,
the user entry `<config>/index.js`, and the `yuke` binary (`--tui` default, `--daemon`) are in tree.
The dedicated leftover-job wake is still open. The JS host is a separate document
(`docs/js-host-design.md`).

The terminal layer is native Zig. It owns the TTY, the cell buffer, the input parser, and the frame
transaction. It runs on the one zio reactor. It draws what the JS layer describes. It never runs a
second event loop.

## Locked decisions

- **libvaxis provides the sans-IO cores only.** Use `Screen`, `Window`, `Cell`, `Style`, `gwidth`,
  `Parser`, and `Vaxis.render`. Do not use `vaxis.Tty` or `vaxis.Loop`.
- **yuke owns the TTY and the IO.** yuke opens and restores `/dev/tty` (Windows: `CONIN$` /
  `CONOUT$`) through zio `std.Io`. `vaxis.Loop` is rejected because it starts its own input task
  with `std.Io.concurrent`; that is a second input owner and it fights the single reactor.
- **Two-grid cell diff.** The renderer keeps a current grid and a previous grid. It compares cells
  and writes only contiguous changed runs. It does not port lite-xl's pixel command cache.
- **Commit the grid swap only after the TTY flush succeeds.** A failed write keeps the frame and
  forces a full redraw. A failed write never marks the frame clean.
- **JS never writes escape sequences.** JS draws into the grid through `beginFrame`/`endFrame`. The
  native side owns cell comparison, output, and the failed-write invariant.
- **The reactor coalesces every wakeup.** Input, resize, the tick timer, leftover Promise jobs, the
  daemon socket, and a worker completion all fold into one owner dispatch path.
- **Only the owner turn runs QuickJS.** An IO coroutine copies a plain `Msg` onto the channel. It
  never calls `onEvent`. Odin called JS from the nbio read callback; that is rejected. A zio input
  task is a different coroutine even on `.exact(1)`. Calling JS from it re-enters the runtime if
  `serve` is in `drainJobs`. Neovim `vim.schedule`, Node poll phases, txiki.js job drain, and the
  libvaxis custom-loop docs all marshal IO to a main turn. `vaxis.Loop` stays out (second input
  owner; SIGWINCH has deadlocked their queue mutex).

## The libvaxis seam

libvaxis exports the cores from its root module. Each core is usable without a vaxis-owned loop.

- `Parser.parse(bytes)` converts a byte slice into a key, mouse, or resize event. It reports
  `event = null, n = 0` for an incomplete sequence. The caller keeps the pending bytes and passes a
  non-empty slice on the next read.
- `Screen` stores cells. `Window` writes clipped cells and prints grapheme-aware segments.
- `gwidth` computes grapheme display width. `Cell.Style` carries SGR state.
- `Vaxis.render(writer)` emits terminal control sequences into a caller-provided `std.Io.Writer`. It
  keeps the previous screen. Use it with a zio-backed writer.

What yuke keeps out of libvaxis: the TTY open and restore, termios, the resize signal, the input
read, the write and flush, and the frame policy. Those are reactor-owned.

## The input path

```text
zio std.Io reader on /dev/tty   (input task; POSIX SIGWINCH is a second task)
  -> Input parser (incomplete tail stays in the buffer)
  -> Msg: Event plus owned key text
  -> capacity-1 channel
  -> owner: loop.start / loop.step -> JS onEvent -> drainJobs -> commitIfDirty
```

Only the owner calls QuickJS. The input task never touches a `JSValue`. Key text is copied into
`Msg` so a later parse cannot overwrite `Event.text`. Paste and capability events stay off the
channel. Windows resize arrives in-band; POSIX resize is SIGWINCH. `Tty.shutdownInput` unblocks a
Windows `ReadConsoleInputW` before `group.cancel`.

`serve` today waits only on that channel. A tick, a leftover job drain, and a daemon frame must
enqueue the same `Msg` path. Do not call `loop.step` from the timer or the reader.

## The frame transaction

The paint model matches the Odin host: `beginFrame → fill/text/cursor → endFrame`.

1. `beginFrame` starts a UI buffer frame and marks the host dirty.
2. JS fills the background, draws the view tree, draws overlays, and places one cursor.
3. `endFrame` diffs the current grid against the previous grid and writes changed runs to the zio
   writer.
4. The host swaps the grids only after the flush succeeds.

A dirty bitset or a row interval is an optimization. Full cell comparison is the correctness
fallback after a resize, a desync, a failed write, or a forced refresh.

## The tick model

Ticks are demand-driven. A script calls `setNeedsTick(periodMs)`. The host clamps the period between
50 ms and 2 s, with a 450 ms default. Flags live on `Host.paint`. A zio timer (`timer.zig`) is not
in tree yet. When it lands, it fires a `tick` event only while some script wants ticks. An idle UI
arms no timer. A timer callback enqueues an owner event; it never calls QuickJS from the timer
context.

`drainJobs` stops at a job budget so a Promise chain cannot starve TTY input. Leftover jobs stay
queued. The owner must wake again without waiting for a key (the tick timer, or a 0-delay wake).
Odin's `nbio.tick` and txiki's idle handle both keep poll from blocking while jobs remain. Zig
does not yet.

## Theme and color

yuke is monochrome. Emphasis is inversion and weight, not hue. `danger` is the only chroma, and only
for errors. The palette names match the web tokens (`ink`, `surface`, `surface-hi`, `line`, `fg`,
`muted`, `faint`, `danger`). v1 paints `Normal` with `reset` foreground and background, so the
terminal background shows through. Named ANSI 16 colors follow the user's terminal palette. Indexed
256 and truecolor hex do not. A later layer may detect dark or light with OSC 11. See the Odin
`main:docs/tui-design.md` for the visual pass; it stays the source of truth for look.

## Teardown

On shutdown, or on a fatal fault, restore the terminal before the process exits.

1. The JS host reaches `drained` (see `js-host-design.md`).
2. Leave the alternate screen and reset the terminal state through the caller-owned writer.
3. Restore termios. Close the TTY.
4. Write any deferred error to stderr only after the alternate screen is gone.

A recoverable script fault does not tear down the terminal. It renders a short error in the status
area and keeps the cell buffer, the reactor, and the alternate screen alive. `serve` already
absorbs `JavaScriptFault`. It does not keep the exception text or paint it. Odin stored `last_err`
and printed it after alt-screen teardown, but any report also exited the process. Zig keeps the
print-after-restore path for a fatal host error only.

## File layout

```
lib/term/                     # native terminal primitives (xvaxis sans-IO)
  tty.zig                     # POSIX /dev/tty or Windows CONIN$/CONOUT$; zio std.Io
  tty_posix.zig
  tty_windows.zig
  input.zig                   # bytes or Win32 records -> typed events
  render.zig                  # frame transaction; Vaxis.render over a zio writer
  xvaxis/                     # stripped libvaxis fork

src/main.zig                  # yuke entry: --tui (default) or --daemon
src/cli.zig                   # flag parse
src/daemon/app.zig            # daemon run()
src/tui/                      # the TUI owner
  app.zig                     # run: TTY, alt screen, input/winch tasks, serve until quit
  loop.zig                    # one turn: map event -> onEvent -> drainJobs -> commitIfDirty
  host.zig                    # QuickJS runtime, limits, interrupt, default baked modules
  loader.zig                  # yuke:* baked table + config-root containment
  modules/term.zig            # native yuke:term
  modules/client.zig          # native yuke:client-native transport and replicas
  js/core.js                  # baked policy: style, clip/wrap, command, keymap, RootView
```

There is no separate `timer.zig`; the tick task lives in `app.zig`. The leftover-job wake is not in
tree. `main.zig` resolves the config directory, so there is no `config.zig`. `lib/term` owns the
cells and the IO. `src/tui/host.zig` owns the JS engine. There is no top-level `src/js/` or `src/term/`.

## Tests

- The parser retains an incomplete tail and completes a split escape sequence across two reads.
- The diff writes only changed runs and keeps the frame on a failed write.
- `Host.resize` does not update JS size when the grid did not swap. A write failure after swap
  keeps `dirty` so the next commit can flush.
- A queued `Msg` keeps key text after a later parse overwrites `Input.text_buf`.
- `q` with no `onEvent` sets `quit_requested`. After `import "yuke:core"`, `q` runs `quit`.
- Teardown closes the channel, shuts down Windows CONIN$, then `group.cancel`. `render.deinit`
  leaves the alternate screen. Termios restore is `Tty.deinit`.
- A `tick` arrives while `needs_tick` is set and does not call QuickJS from the timer task.
- The daemon client owns its socket tasks and delivers copied messages to the TUI owner.
