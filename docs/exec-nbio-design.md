# yuke:exec — loop-driven rewrite (nbio + SIGCHLD reaper)

Design note for replacing the worker-thread `yuke:exec` with an event-loop-driven
implementation. Grounded in a four-agent survey of the current exec mechanism, the
in-tree SIGWINCH self-pipe pattern, the daemon threading model, and how libuv /
Bun / Tokio wait on child exit. Marks **Keep / Change / Add** and calls out the
one spike to run before committing.

---

## 1. Why

Today one `yuke:exec` call holds an offload **worker thread for the command's
entire timeout** (up to 10 min), draining both pipes in a blocking loop with a
`time.sleep(EXEC_POLL_INTERVAL = 2ms)` between empty rounds and polling-reaping
during termination (`src/js/exec.odin:275-302, 231-248`). That is why
`exec_pool` must be a *separate* 4-worker pool from the fs pool — a long command
would otherwise starve `yuke:fs` (guarded by `test_exec_does_not_block_a_file_read`).

No mature runtime does this. libuv, Bun, and Tokio all drive child stdio as
non-blocking fds on the event loop and learn about exit from an **event**
(SIGCHLD / pidfd / kqueue `EVFILT_PROC`), never a per-process thread. The repo
already proves the whole mechanism for a different signal: SIGWINCH → self-pipe →
`nbio.poll` (`src/term/resize_posix.odin`, `src/term/relay_posix.odin`).

Two payoffs:
1. **Delete the worker-per-command model and the 2 ms poll-sleep.** The dedicated
   `exec_pool` (`d.exec_workers`, 4 threads) disappears entirely — the reason it
   exists (a held worker) evaporates.
2. **Unblock streaming tool output.** On the loop thread each pipe read can emit a
   `Tool_Output_Delta` into `Tool_State_Running.output` (both already modeled in
   `src/wire`); a worker returning one final blob can never do this. This is the
   real motivation — see §9.

---

## 2. Platform decision

**v1: SIGCHLD self-pipe + `waitpid(WNOHANG)` reap loop.** One code path for
Linux + macOS, exactly libuv's portable path, and a near-clone of the existing
SIGWINCH notifier. All bindings exist (`posix.sigaction`, `posix.pipe` + `fcntl`,
`posix.waitpid`, `Wait_Flags{.NOHANG}`, `WIF*`).

**v2 (only if the global SIGCHLD disposition ever collides with something else
in-process):** per-fd watchers, both already bindable with zero manual syscalls —
Linux `linux.pidfd_open` (`core/sys/linux/sys.odin:3354`) polled **level-triggered**
(the Bun v1.3.14 lesson: `EPOLLONESHOT` drops simultaneous exits), macOS kqueue
`Filter.Proc` + `Proc_Flag.Exit` (`core/sys/kqueue/kqueue.odin:60,84`). Each is a
separate platform path, so not the first cut.

**Windows:** unchanged — `yuke:exec` stays refused (`exec_windows.odin`). New posix
files are `#+build linux, darwin`; Windows gets empty-struct stubs like
`resize_windows.odin`.

---

## 3. Where it lives

**`src/js/`, not the daemon.** `exec.odin` is in the shared host and the TUI client
embeds the same `yuke:exec` on its own nbio loop. Key everything off the Host's
loop (`h.exec_pool.loop` today; becomes `h.loop` once the pool is gone). Both
binaries benefit; no daemon-only code. The SIGCHLD disposition is process-global,
so each binary (separate process) installs its own once.

Files:
- `src/js/exec.odin` — rewritten (`#+build !windows` stays; logic moves loop-side).
- `src/js/exec_posix.odin` — `exec_spawn` **Keep** (posix_spawn + SETPGROUP +
  killpg is correct and load-bearing); `exec_reap`/blocking helpers **removed**
  (reaping centralizes in the reaper).
- `src/js/sigchld_posix.odin` — **new**, the global reaper (mirror of
  `resize_posix.odin`).
- `src/js/sigchld_windows.odin` — **new**, empty stub.

---

## 4. Components

### 4a. Global SIGCHLD notifier (`sigchld_posix.odin`)

Direct analog of `resize_notifier_*`, with the same async-signal-safe discipline
(`g_write_fd` + `g_active_handlers`, atomic publish/withdraw, spin-on-active
teardown, handler does exactly one non-blocking `posix.write` of a wake byte).
Differences from SIGWINCH:

- Signal: `posix.Signal(posix.SIGCHLD)` (bare const, not a `Signal` enum member —
  same cast trick as `SIGWINCH`).
- Flags: `sa_flags = {.RESTART, .NOCLDSTOP}`. `.NOCLDSTOP` suppresses SIGCHLD on
  child **stop/continue** so we only wake on exit. **Never** `.NOCLDWAIT` and never
  `SIG_IGN` — either auto-reaps and destroys the exit status we need.
- Self-pipe: `posix.pipe` + set both ends `O_NONBLOCK | FD_CLOEXEC`
  (`pipe_prepare` pattern). Read end is a private fd → safe to `associate_socket`
  on Darwin (the shared-open-file-description caveat does not apply).
- Installed **once** at Host init (or lazily on first `exec`, guarded by the
  `atomic_compare_exchange_strong(&g_write_fd, -1, w)` CAS); torn down at
  `js.destroy` in the exact withdraw→restore→spin→close order.

### 4b. Child registry (loop-thread only, no lock)

`pid → ^Exec_Job`. Because everything runs on the single loop thread (§ daemon
model), no mutex is needed. A small `map[posix.pid_t]^Exec_Job` on the Host (or an
intrusive list — few concurrent execs). Registered synchronously in `exec_entry`
right after `posix_spawn` returns the pid, **before** control returns to the loop.

### 4c. The reaper poll

Cast `read_fd → net.TCP_Socket`, `nbio.associate_socket`, then arm
`nbio.poll_poly(sock, .Receive, host, on_sigchld, l = loop)`. On completion:
1. clear the stored op pointer (op is dead after its callback), re-check liveness;
2. `drain_pipe(read_fd)` (collapse the burst — SIGCHLD coalesces);
3. reap loop: for each **registered** pid, `waitpid(pid, &st, {.NOHANG})`; on a
   positive return, decode status (`WIF*`, `128+sig` convention — reuse today's
   `exec_reap` decode), look up the job, mark it reaped with its code;
4. drive that job toward settle (§5);
5. re-arm the poll.

Reap **only pids we own** — never `waitpid(-1)`. Our only children are exec shell
leaders, but per-pid reaping is the robust choice and is O(small). `waitpid(leader)`
reaps **only the shell**, never grandchildren; the shell's forked commands
reparent to init on its exit and are *killed* (not reaped) via the existing
`killpg`. That is correct and sufficient.

### 4d. exec stdio on the loop

`exec_entry` (loop thread) does what the worker used to do at spawn, inline:
`posix.pipe` ×2 (read ends `O_NONBLOCK | FD_CLOEXEC`), `exec_spawn` (unchanged),
close the parent's write ends, register the pid. Then associate + poll each read
end with a copy of `drive_on_source_poll` (`relay_posix.odin:73`): on `.Ready` →
one non-blocking `posix.read` into a chunk → append to the job's output builder
(bounded by `EXEC_MAX_OUTPUT_BYTES`, set `truncated`) → **[streaming hook: emit
`Tool_Output_Delta` here]** → re-arm; on `n==0` mark that stream EOF; on
`EAGAIN/EINTR` re-arm; other errno → mark stream closed.

### 4e. Deadline + kill escalation

Per command: one `nbio.timeout_poly(job.timeout, …)` one-shot for the deadline.
On fire → `timed_out = true`, `exec_signal_group(SIGTERM)`, arm a second
`timeout_poly(EXEC_GRACE)`; on that fire, if still unreaped, `SIGKILL`. The reaper
observes the actual exit asynchronously and settles. Cancel a pending grace timer
with `nbio.remove` if the child reaps first. (A poll's own `.Timeout` result could
carry the deadline instead of a separate timer — optional simplification.)

### 4f. Remove the offload path

Delete: the `offload.submit` call, `exec_job_run`/`exec_drain`/`exec_read_chunk`/
`exec_terminate`/`exec_reap`, `EXEC_POLL_INTERVAL`. Remove `h.exec_pool` from
`js.Options`/`Host`, and `d.exec_workers` + `EXEC_WORKER_COUNT` +
`pool_init/pool_stop`/shutdown-gating/destroy-asserts from `src/daemon/daemon.odin`.
`op_begin`/`op_end` accounting and the promise settle **Keep** — still the
mechanism that resolves the JS promise on the loop thread.

---

## 5. One command as a state machine (loop thread only)

```
Spawning ─ posix_spawn ok ─▶ Running{out_open, err_open, reaped:false, code}
  ├─ stdout readable ─▶ read/append/[emit delta]/re-arm      (out_open until n==0)
  ├─ stderr readable ─▶ read/append/[emit delta]/re-arm      (err_open until n==0)
  ├─ SIGCHLD reaper  ─▶ reaped:true, code := status
  ├─ deadline fire   ─▶ timed_out; SIGTERM; arm grace timer
  └─ grace fire      ─▶ SIGKILL
Settle  ⇐  (!out_open && !err_open && reaped)   or   (cancel/close ⇒ remove polls,
           killpg, reject)
```

Settle predicate is **both streams EOF *and* child reaped** — the pipes can EOF
before the zombie is reaped, and a lingering grandchild can hold a pipe open past
the leader's exit (the deadline covers that). On settle: resolve with the
`{stdout, stderr, code, timedOut, truncated}` object (`exec_value`, Keep), or reject
on cancel; free op pointers; `op_end`.

**No cross-thread state anymore.** The job is written and read only on the loop
thread, so the worker/context memory boundary (`exec.odin:179`), the panic
allocators, and the per-job `Dynamic_Arena` heap indirection can go; job strings
can live on the Host allocator or the run arena.

---

## 6. Race + correctness ledger

- **Reap-before-arm: not a race here.** Handler is installed once at startup, so
  every future child is covered. `posix_spawn` and the reaper both run on the one
  loop thread; the pid is in the registry before the loop can dispatch the poll
  callback. A SIGCHLD byte already pending when we register is fine — the reaper
  runs later and finds the registered pid.
- **SIGCHLD coalescing:** `drain_pipe` + reap-loop-until-no-more, per libuv.
- **Stolen waitpid:** we never `wait(-1)`; nothing else in-process reaps. Safe.
- **Signal delivered to a worker thread:** harmless — the handler only atomic-writes
  the pipe; the actual `waitpid` runs on the loop thread. `.RESTART` prevents
  worker-syscall EINTR.
- **`num_waiting` and shutdown:** an always-armed reaper poll keeps
  `nbio.num_waiting() > 0`. The daemon's `serve()` exits on `signals_seen()`, not on
  work draining (it's a server with a listener always armed), so this is fine.
  Tear the reaper poll down at host destroy so a final drain can reach 0.
- **Group kill unchanged:** `POSIX_SPAWN_SETPGROUP` + `killpg` preserved verbatim —
  `test_exec_kills_the_whole_process_tree` and `test_exec_terminates_before_it_kills`
  depend on it and are model-independent.

---

## 7. Teardown / `ops_close`

`test_exec_stops_when_operations_close` requires in-flight commands to unwind in
<10 s. New path: `ops_close` sets `h.cancelled`; walk live jobs → `nbio.remove` both
polls + any timers, `killpg(SIGKILL)`, reject the promise, `op_end`. Immediate, no
worker join to wait on. The global notifier is removed at `js.destroy`, after
`ops_idle`.

---

## 8. Tests

**Preserve (7, `src/js/exec_test.odin`):** both-streams+code, deadline stop,
never-quiet stop, no-block-other-pool (now trivially true — no pool), ops-close
teardown, **whole-process-tree kill**, terminate-before-kill.

**Add:** reaper reaps N concurrent commands exiting simultaneously (coalescing);
a command whose grandchild lingers on a pipe still settles at the deadline; the
self-pipe/sigaction install+teardown restores prior SIGCHLD disposition; no zombie
leak after a burst (`waitpid` returns ECHILD afterward). Watch the SIGPIPE masking
note ([[odin-test-masks-sigpipe]]) and nil-logger swallowing ([[nil-logger-swallows-test-failures]]).

---

## 9. Follow-on: streaming tool output (the motivation)

The wire is already modeled: `Tool_Output_Delta` broadcast + `Tool_State_Running.output`
(`@bounded LIMITS.max_tool_output_stream_bytes`), validated and tested. What's
missing is the **producer**, and §4d's read callback is exactly it. But surfacing it
needs an API on `yuke:exec` (today it returns one promise): a streaming option /
callback so the JS tool handler forwards chunks, which `run.odin` accumulates into
`Tool_State_Running.output` and broadcasts, and `resync_build` seeds on reconnect.
That is its **own slice** layered on this rewrite — keep it out of the core exec
change, but land the read-callback seam (§4d hook) so it drops in without another
exec rewrite.

---

## 10. Spike — DONE (kqueue proven; io_uring pending)

Ran 2026-08-20 (`scratchpad/exec_spike.odin`, 12/12 pass on Darwin/kqueue).
Proven on the live backend:
- `nbio.associate_socket` + `poll_poly(.Receive)` delivers readiness on a **pipe**
  read fd via the `net.TCP_Socket` cast — both when data is already buffered and
  when it arrives after the poll is armed (genuinely deferred).
- Full reaper end-to-end: `sigaction({.RESTART, .NOCLDSTOP})` install, async-signal
  handler's self-pipe write wakes a thread blocked in `nbio.tick`, the poll fires,
  and `waitpid(WNOHANG)` reaps a real `posix_spawn` child with the correct exit
  code.

**Still to confirm on Linux/io_uring:** same API, and io_uring poll accepts
arbitrary fds (`associate_socket` is a Linux no-op), so this is expected to hold —
but run the spike (or slice-2 reaper tests) on a Linux box/CI before relying on it.

---

## 11. Slices

1. **Spike** (§10) — DONE 2026-08-20, kqueue proven.
2. **Reaper** — DONE 2026-08-20. `src/js/sigchld_posix.odin` (+ `sigchld_windows.odin`
   stub), `src/js/sigchld_test.odin`. `Child_Reaper` = global SIGCHLD self-pipe +
   pid→`Child_Watch` map; API `reaper_init/watch/destroy` + `Child_Exit` callback.
   **No `unwatch`** — a watched pid is owned until reaped (else it zombies); a caller
   that abandons a child kills it and lets the exit callback fire on reap. 5 tests
   (exit code, signalled death → 128+sig, concurrent/coalescing, no-zombie,
   disposition-restore) pass alongside the existing exec tests, confirming the
   reap-only-your-own-pids coexistence. Reaper tests share a file-scope mutex
   because the SIGCHLD disposition is a process singleton vs the parallel runner.
   Hardened after an adversarial review: both re-arm sites guard on `r.op == nil`
   so a re-entrant `reaper_watch` from an exit callback (the exec chaining shape)
   cannot double-arm the poll; `reaper_init` associates the fd *before* installing
   the handler, closing the init-failure write-to-closed-fd window (new
   `Associate_Failed`); the coalescing test is now deterministic (all children
   zombie, then one tick must reap all three); a 6th test covers the re-entrant
   re-arm. Not yet wired into `Host` or `exec`.
3. **exec rewrite** — move spawn/drain loop-side, wire the reaper, delete the
   offload path; make the 7 tests pass. Settle predicate = **reaped AND both streams
   EOF** (uniform across normal/timeout/cancel); job freed in the settle.
4. **Daemon cleanup** — remove `d.exec_workers` and its lifecycle.
5. **Streaming seam** (follow-on) — read-callback → `Tool_Output_Delta` →
   `Tool_State_Running.output` → resync.
