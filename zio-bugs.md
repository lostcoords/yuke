# zio bugs

Status: external dependency report.

Defects in the vendored `zio` dependency (`lalinsky/zio`). Report these upstream. Newest first.

## kqueue reports a failed registration as a failed operation

**Severity:** high. **Area:** `src/ev/backends/kqueue.zig` (`checkCompletion`, ~820 and ~849),
`src/ev/loop.zig` (~972), `src/ev/backends/common.zig` (`probePollable`, ~106).
**Platform:** macOS (Darwin) only. **Found:** 2026-08-29, from a yuke TUI failure.

### Summary

`kevent` returns two different kinds of event through one array. A notification says the fd is ready.
An `EV_ERROR` event says the changelist entry (the `EV_ADD`) failed, and puts the errno in
`event.data`. zio does not tell them apart. `checkCompletion` sees `EV_ERROR` with a non-zero
`event.data` and reports it as a failure of the pending read or write, but the syscall never ran.

The errno then goes to `fs.errnoToFileReadError` / `fs.errnoToFileWriteError`. Those tables hold the
errnos a `read` or a `write` can return. A registration errno is not in them. `EINVAL` misses the
table, falls to `unexpectedError`, and prints `unexpected error: .INVAL`, a full stack trace, and
"please file a bug report". The caller gets `error.Unexpected`.

So one refused registration looks like a crash.

### Repro

Open `/dev/tty` on macOS and do a streaming read or write through zio.

1. `probePollable` calls `lseek`, gets `ESPIPE`, and marks the fd pollable.
2. `loop.zig` routes the streaming op to the kqueue readiness path.
3. macOS refuses `EVFILT_READ` and `EVFILT_WRITE` on `/dev/tty` and returns `EV_ERROR` with
   `EINVAL`. This is a known, undocumented Darwin limit. The same test on the real device
   (`/dev/ttys004`) and on an inherited stdio fd registers with no error.
4. zio prints a stack trace and returns `error.Unexpected`.

A C probe under a pty confirms the kernel behavior:

```
/dev/tty      EVFILT_READ  -> EV_ERROR data=22 (EINVAL)
/dev/tty      EVFILT_WRITE -> EV_ERROR data=22 (EINVAL)
/dev/ttys004  EVFILT_READ  -> registered
/dev/ttys004  EVFILT_WRITE -> registered
fd 0 (tty)    EVFILT_READ  -> registered
```

The result is the same for a blocking fd and for an `O_NONBLOCK` fd, so `probePollable` cannot detect
the condition before it registers.

### Effect

Any zio user that reads or writes `/dev/tty` on macOS fails at the first operation with a stack dump.
A TUI is the common case. `probePollable` also sets `O_NONBLOCK` on the fd before the failure.

### Fix

Two parts, in order of value:

1. **Fall back when registration fails.** A changelist `EV_ERROR` means kqueue cannot drive the fd.
   Clear the cached pollable verdict, clear `O_NONBLOCK`, and send the completion to the thread pool
   (`submitFileOpToThreadPool`), the path a regular file already takes. Then `/dev/tty` works on macOS
   with no change in the caller.
2. **Separate the two error classes.** Do not send a registration errno through
   `errnoToFileReadError` / `errnoToFileWriteError`. Return a typed error such as
   `error.NotPollable`, so a caller can handle it. `unexpectedError` must stay for a true
   impossibility, not for a documented kernel refusal.

`handleKqueueError` (~663) has the same shape and needs the same review for the socket path.

### yuke status

yuke does not wait for the upstream fix. `lib/term/tty_posix.zig` opens the real device on Darwin:
it reads the device name from the first standard stream that is a terminal (`isatty` then
`fcntl(F_GETPATH)`), and opens that path. `/dev/tty` cannot name itself — `ttyname` and `F_GETPATH`
on a `/dev/tty` fd both answer `/dev/tty` — so the name must come from an inherited stream. The code
falls back to `/dev/tty` when no stream is a terminal; that fall-back path still hits this bug.

### Links

- https://github.com/lalinsky/zio/issues/new
- https://nathancraddock.com/blog/macos-dev-tty-polling/
- https://github.com/crossterm-rs/crossterm/issues/500
- https://github.com/tokio-rs/mio/issues/1377
