# Handoff: daemon parallel-test flakiness — root cause

_Investigation run 2026-08-20. Pre-existing flakiness, independent of the exec→nbio
rewrite (commit `bfe9788`). Read cold — self-contained._

## 1. Summary

**Root-caused, high confidence.** The `daemon` package flakiness is a use-after-free of
an nbio timeout **Operation**: a one-shot `EVFILT_TIMER` fires on an Operation that has
already been freed back to the loop's operation pool (`op.type == .None`), tripping
`assert(op.type != .None)` / `assert(.Has_Timeout in op._impl.flags)` inside `core:nbio`
`handle_results`. The freed/double-used Operation is the **curl driver's `d.timer_op`**
(`libs/bindings/curl/drive.odin`). Our code uses nbio correctly (arm a `nbio.timeout`,
later `nbio.remove` it); the defect is in **stdlib `core:nbio`** — the kqueue backend's
deferred `remove` of a `.Timeout`-type operation leaves a stale timer registration in the
kqueue that outlives the operation and fires after it is recycled.

Two premises corrected by evidence:
- It is **not** primarily a cross-thread test-runner race. It reproduces
  **single-threaded** (`-define:ODIN_TEST_THREADS=1`) at ~15–25% of full-suite runs.
  Parallelism only raises the hit rate (more concurrent async I/O per wall-second → more
  timing variance).
- The offload cross-thread `next_tick_poly` hypothesis is **disproven** (see §3/§4).
  nbio's cross-thread machinery is thread-safe, and the dominant failing test doesn't even
  use an offload worker.

## 2. Reproduction

Build native deps first in a fresh worktree (else link fails on missing `quickjs.a`):

```
./build.py deps
```

Reusable test binary:

```
mise exec -- odin build src/daemon -build-mode:test \
  -define:ODIN_TEST_FAIL_ON_BAD_MEMORY=true \
  -out:build/daemon_test.bin \
  -collection:src=src -collection:libs=libs -collection:tools=tools
./build/daemon_test.bin        # repeat; ~50–70% of runs fail
```

True single-threaded (compile-time define — NOT a runtime env var; see the gotcha):

```
mise exec -- odin build src/daemon -build-mode:test \
  -define:ODIN_TEST_FAIL_ON_BAD_MEMORY=true -define:ODIN_TEST_THREADS=1 \
  -out:build/daemon_serial.bin \
  -collection:src=src -collection:libs=libs -collection:tools=tools
./build/daemon_serial.bin      # repeat; still fails ~15–25% of runs
```

Failure signatures (all the same underlying bug):
- `[impl_posix.odin:251] runtime assertion: op.type != .None`
- `[impl_posix.odin:316] runtime assertion: op.type != .None`
- `[impl_posix.odin:325] runtime assertion: .Has_Timeout in op._impl.flags`
- `Caught signal ... Unhandled_Trap` (same corruption, different landing)
- Logic expectations such as `the canceled second-round draft is gone`,
  `client_destroy with transport work still outstanding`, `client: transport failed:
  Send_Failed`. These are **collateral**: once the timer UAF corrupts the loop's
  kqueue/op-pool bookkeeping mid-test, the affected turn never completes cleanly, so
  downstream expectations diverge. The `+++ leak ... cancel.odin` lines are just whatever
  JS-tool state was live at crash time — a symptom, not the cause.

Failing tests all drive a **real end-to-end provider turn** over the curl transport:
`test_session_cancel_run_preserves_committed_tool_results`,
`test_session_run_is_concurrent_across_sessions`,
`test_session_resync_mid_turn_carries_the_draft_and_the_queue`,
`test_session_send_input_queues_behind_a_live_turn`, etc. (`src/daemon/run_test.odin`).

**Gotcha that cost time:** `ODIN_TEST_THREADS` is a compile-time `-define`, not a runtime
env var. `ODIN_TEST_THREADS=1 ./build/daemon_test.bin` does **nothing** — that binary
still runs multi-threaded. You must recompile with the define to get a serial binary.

## 3. Root cause

The double-used/freed nbio `Operation` is the **curl driver's timeout op**, armed at
`libs/bindings/curl/drive.odin:246`:

```odin
d.timer_op = nbio.timeout_poly(delay, d, drive_on_timeout, d.loop)
```

and removed at `drive.odin:239` (`drive_apply` reconciliation) and `drive.odin:110`
(`drive_clear_io`). Curl's usage is legitimate: it arms curl's requested timeout and, when
curl asks for a new one on the next socket event, `nbio.remove`s the old op and arms a new
one. In these loopback tests curl repeatedly arms a **1 ms** timer and removes it almost
immediately (fast loopback ⇒ socket events land within ~1 ms of the timer).

The defect is in **stdlib `core:nbio`, kqueue backend** (`core/nbio/impl_posix.odin`):

- A `.Timeout` op registers **one** kqueue timer keyed by its address:
  `ident = uintptr(op), filter = .Timer, flags = {.Add,.Enable,.One_Shot}`
  (`impl_posix.odin:1108–1121`, `timeout_exec`).
- `nbio.remove(op)` is **deferred**: `_remove` (`impl_posix.odin:422–434`) sets
  `{.Removed,.Has_Timeout}` and calls `link_timeout(op, now)`, which **re-arms an EV_TIMER
  on the same `ident = uintptr(op)`** to fire "now" (`impl_posix.odin:1203–1222`). For a
  `.Timeout` op the removal's timer and the op's own timer are the *same* kqueue key.
- If the original one-shot timer has already fired (kernel auto-removed it; its event is
  pending) when `remove` runs — exactly the 1 ms/rapid-re-arm case — the re-armed EV_TIMER
  plus the still-pending original event yield **two** timer events for one `ident`.
  Processing the first takes the internal-timeout branch (`impl_posix.odin:320–331`,
  `is_internal_timeout` true because `Has_Timeout` is set), and `timeout_and_delete` +
  `handle_completed` **free the op** (pool.put → zeroed → `type==None`). A leftover
  EV_TIMER for that same `ident` then fires on the recycled op → `assert(op.type != .None)`.

So: **our code is correct; the bug is stdlib `core:nbio`'s deferred `remove` of a
`.Timeout` operation on the kqueue (darwin/BSD) backend.** The mechanism is inherent to
removing timeout ops and is merely *provoked* by the curl driver's rapid 1 ms arm/remove;
any subsystem that `nbio.remove`s a live `.Timeout` op is exposed.

## 4. Evidence (verified vs inferred)

**Verified:**
- **lldb, deterministic:** conditional breakpoints at `impl_posix.odin:251/316`
  (`op->type == 0`) stop with `event.filter == Timer`,
  `event.ident == uintptr(op) == udata`, `op.type == .None`. Across runs the crash op is
  the **same** address (`0x300000658`; stable because nbio's op pool uses a virtual growing
  arena). ⇒ a freed timeout op with a live kqueue timer.
- **Owner pinned by tracing:** temporary `DBG_TIMER` `fmt.eprintfln` at arm/remove/fire in
  `drive.odin`, rebuilt serial, caught under lldb. For the crash op: `CURLARM 0x300000658
  delay=1ms` then `CURLREM 0x300000658 (apply)` and **no** `CURLFIRE` — curl armed a 1 ms
  timeout and `nbio.remove`d it via `drive_apply` before it fired through curl; nbio then
  freed it and a stale timer fired on it. Reproduced across 4 consecutive crashes, same
  address, same ARM→REM history. (Instrumentation reverted; worktree clean.)
- **Serial reproduction:** the truly single-threaded binary crashes ~1/6 runs with the
  identical assertion ⇒ not a test-runner cross-thread race.
- **nbio cross-thread machinery is thread-safe:** `core:container/pool` `get`/`put` are
  mutex-guarded, the backing `virtual.Arena` allocates under its own mutex, the MPSC ring
  (`core/nbio/mpsc.odin`) and `wake_up` (`impl_posix.odin:515`) are correct, and
  `nbio.exec` routes foreign-loop ops through the MPSC queue (`nbio.odin:405`). So
  `offload._publish_completed → nbio.next_tick_poly` (`libs/offload/offload.odin:291`) is
  safe.
- **Offload not involved in the dominant test:** `RUN_FAKE_TOOL_ENTRY`'s handler is pure JS
  (`run_test.odin:136`) — no `yuke:exec`/fs/diff — so no offload worker touches that test's
  loop, yet it fails. Rules out the offload hypothesis for it.
- **libcurl global state** is `sync.Once`-guarded (`libs/bindings/curl/curl.odin:190/209`);
  fake provider is plain HTTP to `127.0.0.1` (no DNS, no TLS) — rules out libcurl
  SIGALRM-resolver / global-init races.
- **Disproven mitigation:** extending test pump budgets to a wall-clock deadline
  (`pump_tick_until`, `pump_settle`) does not fix it — even a 5 s settle still fails.
  Genuine corruption, not an under-budgeted wait.

**Inferred (not single-stepped):**
- The precise kevent change/return ordering by which the re-armed EV_TIMER escapes
  `timeout_and_delete`'s EV_DELETE. The *outcome* — a stale timer on a freed timeout op —
  is proven; the exact batch ordering is reasoned from the nbio source.
- That the logic-expectation failures are all downstream of the same timer UAF — strongly
  supported (co-occurrence, same tests, nothing else races) but not each proven.

## 5. Recommended fix

The correct fix is in **stdlib `core:nbio`** (not ours): deferred `remove` of a `.Timeout`
operation must not leave a second/stale kqueue timer on the op's own `ident`. For the nbio
maintainers: when `_remove` targets a `.Timeout` op, EV_DELETE its own timer and complete
it directly instead of re-arming a `link_timeout` on the same `ident`; and/or make removal
idempotent against a duplicate pending timer event for a freed op. Files:
`core/nbio/impl_posix.odin` (`_remove` ~L422, `link_timeout` ~L1203, `timeout_and_delete`
~L1235, `handle_results` ~L225–347).

Since we can't edit the mise stdlib, the **smallest correct workaround in our tree** is to
stop calling `nbio.remove` on a live `.Timeout` op and instead let the one-shot timer fire
and ignore it. In `libs/bindings/curl/drive.odin`: don't `nbio.remove(d.timer_op)` in
`drive_apply`/`drive_clear_io`; keep an epoch/token on the `Drive`, capture it in the
timeout's user data, and in `drive_on_timeout` drop the callback if the token is stale. The
op then completes and frees itself via the natural one-shot path, so nbio never removes a
`.Timeout` op. Apply the same pattern to the other `nbio.remove(<timeout op>)` sites.
(Removing **poll**/recv/send ops — the curl `watch` ops — is *not* implicated; only
`.Timeout` ops are.)

A cleaner long-term option is to **vendor a patched `core:nbio`** as a local collection and
fix `_remove` at the source — fixes every timeout consumer at once and matches the
"zero technical debt" preference.

**Not a valid mitigation:** running affected packages with `ODIN_TEST_THREADS=1`. It
reproduces serially, so forcing one test thread does not fix it (and would mask a real
product-code UAF that can also occur in the running daemon).

## 6. Open questions / next steps (start here tomorrow)

1. **Confirm the nbio timer-remove hazard in isolation.** Write a ~30-line standalone nbio
   program (no daemon): arm `nbio.timeout(1ms)`, spin the loop so it's about to fire,
   `nbio.remove` it and immediately arm another, loop rapidly. Expect the same
   `op.type != .None` crash. Isolates the bug to `core:nbio` and gives an upstream-ready
   repro. (Highest-value next step.)
2. **Decide fix locus:** vendor+patch `core:nbio` (fixes all timeout consumers) vs.
   per-site epoch-guard in `drive.odin` (+ other sites). Check whether `dev-2026-07a` is
   the pinned Odin and whether upstream nbio already has a fix.
3. **Verify the collateral-damage claim:** after the fix, confirm the logic failures
   (`draft is gone`, `client_destroy ... outstanding`, `Send_Failed`) also vanish; if any
   persists it's a separate daemon/provider bug.
4. **Sweep other `.Timeout` `nbio.remove` sites** for the same exposure:
   `libs/http/server/server.odin` (`c.timeout_op`), `libs/websocket/conn.odin`
   (keepalive/close), `src/daemon/{auth,run,relay}.odin`, `src/tui/host.odin`,
   `src/term/*`, `src/provider/turn.odin` (`turn.dispatch_op`).

### Reference: key file:line anchors
- Crash site: `core/nbio/impl_posix.odin:251,316,325` (`handle_results`).
- Timeout registration: `core/nbio/impl_posix.odin:1101–1123` (`timeout_exec`).
- Deferred remove + re-arm: `core/nbio/impl_posix.odin:422–434` (`_remove`), `:1203–1222`
  (`link_timeout`), `:1235–1341` (`timeout_and_delete`).
- Cross-thread exec routing (safe): `core/nbio/nbio.odin:405–423`; MPSC `core/nbio/mpsc.odin`.
- Owner of the leaked op: `libs/bindings/curl/drive.odin:246` (arm), `:239` and `:110`
  (remove).
- Offload marshalling (safe): `libs/offload/offload.odin:266–291`.
- Test pump budgets (not the cause): `src/daemon/pump_test.odin:165` (`pump_tick_until`),
  `:177` (`pump_settle`).
