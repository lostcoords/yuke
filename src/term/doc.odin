/*
The term package provides cross-platform terminal control: raw-mode entry/exit, the
alternate screen, input-mode negotiation, a VT/ANSI escape-sequence input parser,
an input-event assembler, and resize detection.

The package is layered as:

  - `escapes.odin`: centralized ANSI/DEC escape-sequence constants, so callers
    never scatter escape byte literals through terminal-control logic. Ported from
    the mibu catalog used by the Zig reference.
  - `events.odin`: a byte-at-a-time terminal input parser — a VT/ANSI
    escape-sequence state machine (DEC/ANSI VT500 model; credit Paul Williams,
    vt100.net/emu/dec_ansi_parser). Absorbed from mibu's `event.zig` — yuke-odin
    owns this code now, no external dependency. Quirks here are load-bearing
    terminal-compatibility behavior; deviations from the reference are called out
    inline.
  - `reader.odin`: the input event assembler. Drives the byte-level `parse`/
    `flush` state machine and turns the raw stdin stream into whole terminal
    events. Beyond the parser it carries a partial escape sequence across reads
    and assembles bracketed paste — the parser emits `Paste_Start`/`Paste_End`
    markers; this reader captures the raw bytes between them as one uninterpreted
    `Paste` event. Caller-driven contract: the caller owns the stdin read. It reads
    bytes and calls `reader_push`, drains `reader_next` until it returns a `nil`
    event, and calls `reader_flush` only on the ESC-disambiguation timeout or at
    EOF. Ownership: the Reader owns two growable buffers (`tail`, `paste`), freed
    in `reader_destroy`. A returned `Paste` event borrows the `paste` buffer and
    stays valid only until the next paste begins.
  - `session.odin`: the terminal session guard. Enters raw mode plus the alternate
    screen and the input modes the terminal supports (bracketed paste, in-band
    resize, Kitty keyboard), negotiated up front via DECRQM; `session_leave`
    restores everything. Ownership: the Session borrows `tty` (the fd) and `out`
    (the writer); both must outlive the session. The Session owns no heap memory,
    so `session_leave` is a terminal-state restore, not a destructor: it is safe
    to call from a panic path and is idempotent. The `Reader` handed to
    `session_enter` is borrowed only for negotiation, to preserve any unrelated
    tty input typed during the probe window. Mode writes go through `core:io`;
    negotiation reads and console-output setup use the per-OS `poll_readable` /
    `read_byte` / `output_mode_*` primitives (session_posix.odin /
    session_windows.odin), so this file itself is platform-independent.
  - `resize_posix.odin`: SIGWINCH resize notifier for terminals without in-band
    resize (mode 2048): signal -> self-pipe (the one async-signal-safe step) -> a
    readable FD. POSIX only (macOS + Linux). `resize_notifier_init` borrows `tty`
    for the notifier's lifetime. Callers either block in `resize_notifier_wait` or
    poll `read_fd` themselves (termdrive arms `nbio.poll` on it) and call
    `resize_notifier_consume` to drain and re-query size via `get_size`. The event
    itself carries no dimensions: SIGWINCH only means "at least one resize
    happened since the last consume", so the real size always comes from the
    TIOCGWINSZ ioctl, never from event count.
  - `resize_windows.odin`: Windows resize strategy — intentionally no notifier.
    Windows has no SIGWINCH (nor any async signal for a console size change), so
    the POSIX self-pipe notifier has no analogue here. A polling notifier was
    considered and rejected: this package deliberately ships no resize notifier on
    Windows. How resize is observed instead: modern terminals (Windows Terminal)
    negotiate in-band resize (DEC mode 2048) in `session_enter`; legacy conhost
    degrades to opportunistic re-query at natural points. Why not the
    event-driven console API: `ReadConsoleInputW` delivers
    `WINDOW_BUFFER_SIZE_EVENT` records, but consuming input records would steal
    the key/mouse bytes the VT byte-stream reader depends on. API asymmetry
    (intentional and compile-time visible): the POSIX notifier surface has no
    Windows definition, turning any Windows caller that assumes it into a compile
    error rather than a silent no-op.
  - `session_posix.odin` / `session_windows.odin`: per-OS negotiation-read
    primitives for `session.odin`.
  - `tty.odin`: cross-platform terminal handle, size query, and raw-mode contract.
    `Tty_Handle` names the terminal: a `posix.FD` on POSIX, a `windows.HANDLE` on
    Windows. HANDLE-MEANING WARNING (Windows only): the handle `enable_raw_mode`
    needs (console INPUT) is NOT the handle `get_size` needs (console screen-buffer
    OUTPUT). On POSIX both are the same tty fd.
  - `tty_posix.odin` / `tty_windows.odin`: per-OS raw-mode terminal control, plus
    the console screen-buffer size query on Windows. Windows raw mode sets
    ENABLE_VIRTUAL_TERMINAL_INPUT, so the console driver translates keys, mouse,
    and in-band resize into the same VT/ANSI byte stream xterm emits, read as plain
    bytes — which is what keeps the reader and event layers platform-independent.
  - `tty_size_darwin.odin` / `tty_size_linux.odin`: the POSIX `get_size`, split per
    OS because C's `ioctl` is variadic and Apple's arm64 ABI passes variadic
    arguments on the stack. A fixed 3-arg `foreign` binding therefore mis-passes
    the `winsize` pointer on Darwin (EFAULT), so that side calls the XNU syscall
    wrapper directly; AAPCS64 and SysV pass variadic arguments in the same
    registers as named ones, so Linux keeps the plain libc binding.

I/O onto `core:nbio` lives in `src/termdrive` (reader thread → socketpair →
`nbio.recv`). This package stays sans-IO: callers own the byte source.
*/

package term
