/*
The term package turns a terminal into something a TUI can drive: put it in raw
mode, ask what it supports, translate the bytes it sends into events, and deliver
those events on a `core:nbio` event loop.

A `Session` is the setup and teardown half — it enters raw mode and the alternate
screen, negotiates the optional input modes (bracketed paste, in-band resize, SGR
mouse, Kitty keyboard) with the terminal up front, and restores everything on leave.

The `Parser` and `Reader` are the input half. Terminals report keys, mouse, paste
and resize as escape sequences in the same byte stream as ordinary text, so the
parser is a state machine fed one byte at a time and the reader assembles its
output into whole `Event`s across read boundaries. Both take plain byte slices.

A key event answers "which key" and "what did it produce" as separate fields, because
terminals differ in how much of that they report. `Key` documents the split. A mouse
event splits the same way, into `Mouse_Event` and `Mouse_Button`.

Resize is the one thing that is not uniform. Terminals that support in-band
resize report it as an escape sequence like any other event; on POSIX, everything
else needs the SIGWINCH notifier. Windows has neither — see the drive section.

# Driving it

A `Drive` puts the reader on an `nbio` loop. A terminal cannot be watched by a
Windows IOCP operation, but POSIX reactors can poll the descriptor directly.

POSIX:

  tty / inject FD ──► nbio.poll ──► bounded read ──► Reader → Event_Handler

  SIGWINCH (no DEC 2048) ──► self-pipe ──► nbio.poll (same loop thread)
                                                         │
                                                         ▼
                                      get_size → Resize → Event_Handler

Windows: a console HANDLE cannot be associated with an IOCP and `nbio.poll` is
socket-only there, so there is no completion-based way to watch the terminal. The
reader blocks in `ReadFile` and hands over one bounded batch:

  console / inject HANDLE ──► reader thread ──► one slot ──► nbio.next_tick
                                                            │
                                                            ▼
                                                     Reader → Event_Handler

The slot is bounded and the reader waits until the loop has copied it, so a paste is
never torn mid-sequence and exactly one dispatch is outstanding. A drive also
keeps one idle operation in flight, because `nbio.tick` returns immediately when
nothing is outstanding and the caller's loop would spin. That heartbeat is also the
Windows resize path: no SIGWINCH exists and DEC 2048 is unrecognized there, so the size
is sampled each beat. Resize latency is one heartbeat, not POSIX's immediate signal.

The drive owns its in-flight source operation, ESC timeout via `nbio.timeout`, optional
SIGWINCH poll when in-band resize was not negotiated, and session enter/leave when
requested. On POSIX it temporarily makes the borrowed input descriptor nonblocking and
restores its exact original flags on stop. On Windows it owns and joins the reader thread.

Callbacks run only on the nbio I/O thread. The Windows reader thread only fills the
handoff slot and never touches the Reader, event handler, QuickJS, or paint.

`drive_stop` must run on the nbio I/O thread. POSIX stop removes the source and resize
polls before restoring descriptor and terminal state. On Windows the reader may be parked
in `ReadFile` or waiting on the occupied slot, so stop broadcasts to the slot and re-issues
`CancelIoEx` until the thread is out: the cancel is
edge-triggered, so a single attempt races a reader that has not entered the read
yet. It never abandons the thread, which holds pointers into the Drive.

When the peer closes or recv fails, input is marked closed (`drive_is_input_open`
false) and an `Input_Closed` event is delivered, but the drive stays live until
`drive_stop` so session leave still runs. A Reader allocation failure is stream-fatal:
the same event is delivered with `.Reader_Failed`, then the drive restores and stops.

Harness mode (`enter_session = false` + custom `source` FD) feeds VT bytes
through a pipe without raw mode, so automated tests do not need a real TTY.
No SIGWINCH notifier in harness mode.
*/
package term
