# term

The terminal of the yuke coding agent, with no terminal library. Unix only.

- `Terminal` puts the device in raw mode on the alternate screen. It probes the terminal, and the wait for the
  answers ends after 100 ms. Then it turns on scheme reports when the terminal has them, and xterm modifyOtherKeys
  unless the terminal reports kitty flags. `Terminal::background` gives the startup background color. Its drop
  tries to restore the device.
- `Terminal::start_reader` starts the input thread. The thread parses the bytes into `Event`s: legacy keys, kitty
  keys, xterm modifyOtherKeys, SGR mouse, bracketed paste, focus, scheme changes, and later background answers. The
  first reader gets the input that came during the probe.
- The terminal has one reader at a time. A second start fails, also after the thread ended by itself.
  `Terminal::stop_reader` stops the thread, waits for it, and gives how it ended. Then a new reader can start.
- The drop stops the reader before it restores the device. A callback that blocks for ever blocks `stop_reader` and
  the drop.
- `Screen` is a cell grid. `Screen::render` writes only the changed cells, inside a synchronized update. The first
  render, a resize, and a repaint write every cell.

`mise exec -- cargo run -p yuke-term --example events` shows the background color and each event.
