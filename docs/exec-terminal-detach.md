# Exec terminal detach: investigation and record

Status: implemented on 2026-09-11 with option A. This file records the decision and the evidence.

## Problem

The model sometimes runs `sudo` through the `exec` tool. The call then freezes.
The sudo password prompt appears on the TUI screen and corrupts it.
The user cannot type the password, because the keys go to the TUI.

## Root cause

The old spawn used `std.process.spawn` with `.stdin = .ignore` and `.pgid = 0`.
The child got a new process group, but it stayed in the TUI's session.
So the child kept the TUI terminal as its controlling terminal.

`sudo` does not read the password from stdin. It opens `/dev/tty`.

- The prompt text goes to `/dev/tty`, so it lands on the TUI screen.
- The child is in a background process group. A read from the controlling terminal sends SIGTTIN to
  a background group, and the kernel stops the process. This is the freeze.
- The stopped child stays stopped until the exec deadline (120 s by default) kills the group.
- The TUI owns the foreground group, so the user's keys go to the TUI, not to `sudo`.

The same fault applies to every program that opens `/dev/tty`: `ssh` password prompts, the Git
credential prompt, `gpg` pinentry-curses, and full-screen programs. It also applies to `--rpc` when a
user starts it from a terminal.

## Fix in one sentence

Spawn the exec child in a new session (`setsid`), so it has no controlling terminal and `/dev/tty`
fails at once with ENXIO.

Evidence on this machine:

```
$ setsid -w sh -c 'sudo -k true; echo rc=$?' </dev/null
sudo: a terminal is required to read the password; either use the -S option to read from standard input or configure an askpass helper
sudo: a password is required
rc=1
```

The model reads that error and can ask the user to run the command.

## Survey of other agents

We read each project's source in shallow clones on 2026-09-11.

| Agent | Shell tool spawn | Result for `sudo` |
|---|---|---|
| pi (`packages/coding-agent/src/core/tools/bash.ts:94`) | Node `spawn`, `detached: true` (setsid), stdin `ignore` | Fails at once |
| opencode (`packages/opencode/src/tool/shell.ts:303`) | Effect `ChildProcess`, `detached: true` on POSIX, stdin `ignore` | Fails at once (we did not trace the Effect layer) |
| codex (`codex-rs/core/src/spawn.rs:96`, `codex-rs/utils/pty/src/process_group.rs:49`) | `pre_exec` calls `setsid()`. On EPERM it falls back to `setpgid`. Stdin is null | Fails at once |
| gemini-cli, default (`packages/core/src/services/shellExecutionService.ts:603`) | `detached: true`, stdin `ignore`; env sets `GIT_TERMINAL_PROMPT=0`, `SSH_ASKPASS=''` | Fails at once |
| gemini-cli, `tools.shell.enableInteractiveShell` | Each command runs in a node-pty; the user focuses the shell and types | `sudo` works; echo is off, so the password stays out of the output |
| vercel-labs/fx, Zig 0.16 (`src/core/execution/command_runner.zig:118`) | Re-executes its own binary with a `__fx_foreground_session__` token; that process calls `setsid()` and then runs the command; a ready/release byte handshake | Fails at once |

The common behavior: a detached session, closed stdin, and a fast failure. No agent lets the model
type a password. Only the opt-in Gemini PTY mode makes `sudo` work. Yuke takes the fail-fast route.

## Toolchain constraints (read in source)

- Zig 0.16 `std.process.SpawnOptions` (`lib/std/process.zig:360`) has `pgid`, `uid`, `gid`, and
  `start_suspended`. It has no session option and no pre-exec hook.
- `spawnPosix` (`lib/std/Io/Threaded.zig:14871`) uses `fork()` and a fixed child sequence. A caller
  cannot add a step.
- zio v0.16.0 and v0.17.0 `processSpawnImpl` (`src/io.zig`) create a temporary `Io.Threaded` for each
  spawn and call the std spawn. zio adds no session option.
- `std.process.Child` (`lib/std/process/Child.zig:22`) is a plain struct with public fields: `id`,
  `thread_handle`, `stdin`, `stdout`, `stderr`, `request_resource_usage_statistics`.
- zio `childWait` (`src/process.zig:15`) needs only `child.id`. Every backend reaps with `waitid` or
  `waitpid`, so the pid must be a direct child. A `Child` that Yuke builds itself works with `child.wait(io)`.
- zio does not need a non-blocking pipe from the spawn. Its `probePollable`
  (`src/ev/backends/common.zig:106`) sets `O_NONBLOCK` itself on the first streaming read of an unknown fd.
  `Io.Threaded` maps `EAGAIN` to `error.WouldBlock` and does not poll, so the spawn must leave the pipes blocking.
- Yuke links libc already: QuickJS and zio both set `link_libc`.
- Zig ships `spawn.h` for every release target under `lib/libc/include`: `generic-musl`,
  `generic-glibc`, and `any-darwin-any`. `std.c` has posix_spawn bindings for Darwin only, without
  `posix_spawnattr_setsigmask`, `getsid`, or `getpgid`.

### Upstream state (checked 2026-09-11)

- Zig master (Codeberg) has the same `SpawnOptions` as 0.16.0. Issue ziglang/zig#19205 "detached
  process" (setsid on POSIX) is open since 2024-03 with one abandoned PR (#19226). Codeberg #31746
  proposes a `preexec_fn` hook. Its one comment raises portability concerns.
- zio PR #694 (open) adds a native fork+exec spawn with `setpgid` only. It cannot express setsid,
  because the option surface is `std.process.SpawnOptions`.
- Rust has an unstable `CommandExt::setsid` (tracking issue #105376). It uses the `posix_spawn` fast
  path with `POSIX_SPAWN_SETSID`.
- Go (`SysProcAttr.Setsid`), Node (`detached`), and Python (`start_new_session`) call `setsid()` in
  the child after `fork`.
- Zig projects that need setsid write their own `fork()` child path: Ghostty (`src/Command.zig`,
  pre-exec hook), river (`river/process.zig`), libvaxis (`src/widgets/terminal/Command.zig`). They
  build terminals, so they also need `TIOCSCTTY`. Bun used libc posix_spawn with SETSID on macOS only,
  then replaced it with its own vfork shim. No portable posix_spawn Zig package exists.

### libc support for `POSIX_SPAWN_SETSID` and `addchdir_np`

| libc | `POSIX_SPAWN_SETSID` | `posix_spawn_file_actions_addchdir_np` | Feature guard |
|---|---|---|---|
| glibc (≥ 2.26 for SETSID, ≥ 2.29 for addchdir_np) | `0x80` | yes | SETSID needs `__USE_GNU` (`_GNU_SOURCE`) |
| musl (bundled with Zig) | `128` | yes | addchdir_np needs `_GNU_SOURCE` or `_BSD_SOURCE` |
| macOS | `0x0400` (`sys/spawn.h:61`) | yes, 10.15+. macOS 26 deprecates it in favor of `posix_spawn_file_actions_addchdir` | none |

- musl `posix_spawn.c` calls `setsid` (line 69) before the file actions (line 86). Its `adddup2` with
  the same source and target clears `FD_CLOEXEC`.
- musl and glibc spawn with `clone(CLONE_VM|CLONE_VFORK)`. That copies no page tables, unlike the std
  `fork()` path.
- `posix_spawnattr_t` is a target-specific value struct on glibc and musl and a pointer on macOS. A
  hand-written extern cannot express both, so the binding comes from translate-c.
- The release targets are `x86_64-linux-musl`, `aarch64-linux-musl`, `x86_64-macos`, and
  `aarch64-macos` (`.github/workflows/release-nightly.yml`). Native dev builds use the host glibc
  (2.39 here).

## Options

| Option | Precedent | For | Against |
|---|---|---|---|
| A. `posix_spawn` with `POSIX_SPAWN_SETSID` | Rust `setsid`, Bun on macOS | Small libc glue; no copy of std internals; vfork-style clone; exec errors return as a value; no post-fork hazards; `SETSIGMASK` resets the signal mask | A translate-c shim for `spawn.h`; feature macros; `addchdir_np` |
| B. Copy the std fork path and add `setsid()` | Go, Node, Python, codex, Ghostty, river, libvaxis | Full control; a future PTY can take a controlling terminal with `TIOCSCTTY` in the same path | About 80 lines of child code; only async-signal-safe calls after `fork`; `fork` copies page tables that grow with the session |
| C. Re-execute the Yuke binary as a setsid trampoline | fx | The std spawn stays unchanged | One more exec of a large binary per command; a hidden argv mode in `main`; a handshake to close the kill race before `setsid`; a replaced binary runs the new version on macOS |
| D. Add a session option to Zig std | ziglang/zig#19205 | The correct long-term fix; zio inherits it | Yuke pins 0.16, so A or B is still necessary now |
| E. Wrap the command in `setsid(1)` | none | No code | macOS has no `setsid(1)`; on Linux it forks when the caller leads a group, which breaks the wait |
| F. Job control: `TOSTOP`, detect the SIGTTIN stop, hand the terminal over with `tcsetpgrp` and SIGCONT | POSIX shells | `sudo` works with no PTY | zio waits report only exits, not stops; no use under `--rpc` or a daemon in another session; complex |

## Decision

Option A. B was the only close rival, and its one advantage is a pre-exec hook for a future PTY
exec mode. Yuke does not plan a PTY mode, so A wins on size, speed, and child safety. When Zig std
lands the detached option, the shim and the private spawn go away in one step.

## Implementation

### Build

- On Linux, `src/c/spawn.h` defines `_GNU_SOURCE`, then includes `<spawn.h>`, `<fcntl.h>`, `<signal.h>`,
  and `<unistd.h>`. `<unistd.h>` gives `getsid` and `getpgid` to the tests.
- On Apple the shim declares the thirteen prototypes itself and includes no Apple header. Apple's
  `spawn.h` pulls `<mach/port.h>` and its bitfield structs, which translate-c turns into opaque
  types that a union cannot size. The types and values come from the Zig-bundled `sys/_types.h`,
  `sys/spawn.h`, `sys/fcntl.h`, and `signal.h`.
- `build.zig` runs `b.addTranslateC` on the shim with `.link_libc = true` and adds the module as
  `spawn_c` to `app_imports`. translate-c gives the correct struct layout for each target libc.

### Spawn

`spawnDetached` in `src/js/host/process.zig` replaces the `std.process.spawn` call. It returns a
`std.process.Child`, so the drains, `awaitDrains`, `terminate`, and `child.wait` stay as they are.

1. A null-terminated argv from `scratch`: `{ shell, "-c", command, null }`.
2. The environment block from `context.env.createPosixBlock(scratch, .{ .zig_progress_fd = -1 })`.
   This matches the std path, which removes `ZIG_PROGRESS`.
3. Two pipes from `std.Io.Threaded.pipe2` with `O_CLOEXEC`. The parent closes the write ends after
   the spawn. The pipes stay blocking. zio sets `O_NONBLOCK` on the first read. `Io.Threaded` needs
   blocking reads.
4. A write end at fd 0, 1, or 2 moves above fd 2 with `F_DUPFD_CLOEXEC`. A launcher that closed a
   standard stream hands out those numbers. A `dup2` onto its own number would need the CLOEXEC flag
   cleared, and a `dup2` onto the other write end would clobber it.
5. File actions: `addopen(0, "/dev/null")`, `adddup2` for stdout and stderr, `addchdir_np(cwd)`.
6. Attributes: `POSIX_SPAWN_SETSID | POSIX_SPAWN_SETSIGMASK` with a set from `sigemptyset`.
   `SETSIGDEF` is not needed. No code in Yuke or zio sets a signal to `SIG_IGN`. Exec resets caught
   signals.
7. `posix_spawn` with the absolute shell path. A non-zero return maps to `error.HostFailure`. glibc,
   musl, and macOS report an exec failure as the return value and leave no child behind.
8. `killGroup(-pid)` stays correct, because `setsid` makes pid, pgid, and sid equal. The old
   `.pgid = 0` is gone. `setsid` fails with EPERM for a group leader, so the two cannot coexist.
9. A one-line TODO at the function names the std option that deletes the shim.

Option A has no kill race: `posix_spawn` returns after the child calls `setsid`, so the group exists
before the first `killGroup`.

### Tool description

The `exec` description in `src/js/app/builtins.js` now names the working directory, the fresh shell
per call, the three outputs, and the timeout bounds. The `cwd` parameter is gone. The model writes
`cd dir && command`. The description does not mention the missing terminal. The model tries once,
reads the error, and asks the user. The `yuke:exec` JS API keeps its `cwd` option for extensions.

## Tests

All tests are in `src/js/host/process.zig`. `src/tests.zig` now registers the file in its test block, because
a file reached only through a plain import loses its tests under `-Dtest-filter`.

1. "the child leads a new session apart from the test runner": `spawnDetached` with `exec sleep 30`,
   then `getsid(pid) == pid`, `getpgid(pid) == pid`, and `getsid(pid) != getsid(0)`. A group kill
   and a wait clean up. Mutation: remove `POSIX_SPAWN_SETSID`, the test fails with a different sid.
2. "a command that opens the terminal is refused": `( : </dev/tty ) 2>/dev/null && echo opened ||
   echo refused` expects `refused`. The runner may have no terminal, so test 1 carries the proof.
3. "a missing shell fails the call with HostFailure": a shell path that does not exist gives
   `error.HostFailure`. The test observes only the error, not the absence of a child.
4. "the child starts with an empty signal mask" (needs `/bin/bash`): block SIGTERM on the calling
   thread, run `kill -TERM $$; echo survived` through Bash, expect a SIGTERM exit and no output. A
   blocked SIGTERM stays pending and the echo runs. `sh` (dash) clears the inherited mask on start,
   so the test cannot use the default shell. Mutation: remove `POSIX_SPAWN_SETSIGMASK`, the test
   fails with exit code 0 and `survived`.
5. All previous process tests stay green. The JS host exec tests run the same path on a zio runtime,
   with one 200000-byte stream that fills the pipe and proves the blocking-pipe drain there.
6. On 2026-09-11, Linux glibc passed all tests. Native macOS 26 on arm64 passed all tests. The
   `x86_64-linux-musl` target compiled.

## Performance

We measured 500 warm runs of `:` through `process.run` on WSL2 with ReleaseFast on 2026-09-11. We
used both Io backends, three rounds each, and alternated the binaries.

| Round | Before, Threaded | Before, zio | After, Threaded | After, zio |
|---|---|---|---|---|
| 1 | 1.78 ms | 1.70 ms | 1.34 ms | 1.34 ms |
| 2 | 2.00 ms | 1.84 ms | 1.44 ms | 1.10 ms |
| 3 | 2.55 ms | 1.68 ms | 1.26 ms | 1.50 ms |

The new path is faster in every round. The machine is noisy, so the ratio is approximate. The test
binary is small. The fork path has a page-table cost that can grow with the parent size. This
benchmark does not measure that effect.

Allocator requests, from source: the old path built a std arena for argv and the environment block
on each spawn, and under zio a temporary `Io.Threaded` per spawn. The new path requests three
null-terminated strings and the environment block from `scratch`, the caller's arena, which lives
until the exec worker ends. libc allocates its own attribute and file-action storage on macOS. No
allocation counter covers this path, so this is a source read, not a measurement.

## Risks and open questions

- macOS 26 deprecates `addchdir_np` in favor of `addchdir`. The deprecation gives a warning only,
  and translate-c emits no warning for an extern. Check the minimum macOS version when a release
  build first targets macOS 26.
- A full-screen program (`vim`, `less`, `top`) now gets "not a terminal" and does not take over the
  TUI. That is the intended behavior.
- A future PTY exec needs `setsid` plus a controlling terminal. With `posix_spawn`, an `addopen` of
  the PTY slave after `SETSID` can make it the controlling terminal on Linux. macOS needs an
  explicit `TIOCSCTTY`, which `posix_spawn` cannot do. That work would move to option B.
- Option F (job control) stays rejected while exec can move to another session.

## Related

- `docs/shell-execution-plan.md` covers the shell selection and the execution context. This change
  touches only the spawn step inside `process.run`.

## Sources

- [Rust `process_setsid` tracking issue #105376](https://github.com/rust-lang/rust/issues/105376)
- [rust-lang/libc#2983: POSIX_SPAWN_SETSID](https://github.com/rust-lang/libc/pull/2983)
- [ziglang/zig#19205: detached child process](https://github.com/ziglang/zig/issues/19205)
- [ziglang/zig#22504: `std.process.Child` overhaul](https://github.com/ziglang/zig/issues/22504)
- [Codeberg ziglang/zig#31746: `preexec_fn` hook](https://codeberg.org/ziglang/zig/issues/31746)
- [lalinsky/zio#694: native POSIX fork/exec spawn](https://github.com/lalinsky/zio/pull/694)
- [setsid(2)](https://chuck.stanford.edu/planetccrma/man/man2/setsid.2.html)
- Source reads: Zig 0.16.0 `lib/std`, Zig master on Codeberg, zio v0.16.0, v0.17.0 and master, musl
  `src/process/posix_spawn.c`, pi-mono, opencode, codex, gemini-cli, vercel-labs/fx, Bun, Ghostty,
  river, libvaxis.
