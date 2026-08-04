/*
The term package turns a terminal into something a TUI can drive: put it in raw
mode, ask what it supports, and translate the bytes it sends into events.

A `Session` is the setup and teardown half — it enters raw mode and the alternate
screen, negotiates the optional input modes (bracketed paste, in-band resize,
Kitty keyboard) with the terminal up front, and restores everything on leave.

The `Parser` and `Reader` are the input half. Terminals report keys, mouse, paste
and resize as escape sequences in the same byte stream as ordinary text, so the
parser is a state machine fed one byte at a time and the reader assembles its
output into whole `Event`s across read boundaries.

A key event answers "which key" and "what did it produce" as separate fields, because
terminals differ in how much of that they report. `Key` documents the split.

Resize is the one thing that is not uniform. Terminals that support in-band
resize report it as an escape sequence like any other event; on POSIX, everything
else needs the SIGWINCH notifier. Windows has neither.

The package does no I/O of its own: the caller owns the byte source and feeds the
reader. Wiring it to `core:nbio` lives in `src/termdrive`.
*/

package term
