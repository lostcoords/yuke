# 2026-08-17 — a single transport timeout kills a turn; the retry policy is never driven

## Symptom

A chat stops in the middle of a turn. The session shows several assistant turns that just cut off,
each recorded as a provider failure rather than a completed turn.

Session `9989cb7ee5d5dfea` (`~/.local/share/yuke/yuked.db`), model `minimax/MiniMax-M3`, 4 turns:

| run | outcome |
|-----|---------|
| 1 | failed · `provider` |
| 2 | `stop` |
| 3 | failed · `provider` |
| 4 | failed · `provider` |

Each failed `run.done` event carries:

```json
{"outcome": {"type": "failed", "code": "provider", "message": "the provider failed this turn"}}
```

## Error

`~/.local/share/yuke/yuked.log`, one line per failed turn:

```
[ERROR] session_run.odin:366 run_on_result() daemon: session […9989cb7ee5d5dfea] turn failed: Timed_Out
```

The session byte array `[57, 57, 56, 57, 99, 98, 55, 101, …]` is ASCII `9989cb7ee5d5dfea`.
Every failure is `Transport_Error.Timed_Out` — the model call timed out.

## Cause

The retry *policy* exists and is correct, but **nothing drives it**. A single transport error is
terminal for the turn.

`src/provider/retry.odin` defines a complete, unit-tested policy:

- `RETRY_MAX_ATTEMPTS :: 10`
- exponential backoff (`RETRY_BASE 3s`, `RETRY_FACTOR 1.8`, `RETRY_CAP 60s`) with equal jitter, and
  an honored-but-capped `Retry-After` (`RETRY_AFTER_CAP 120s`)
- `error_retryable(.Timed_Out)` → **`true`** — a timeout is explicitly retryable (alongside
  `.Rate_Limited`, `.Server_Error`, `.Network_Error`, `.Stream_Truncated`)

The design intent is stated in the code itself — `retry.odin:5` ("The engine owns the counter; the
transport is single-attempt") and `provider/doc.odin:10-11` ("the engine drives the pure policy
(`retry_backoff`, `error_retryable`) with its own counter, timer, and cancel check").

That engine-side driver was never built. A grep for the policy's callers across `src/daemon/` and
`src/provider/` finds only the definition, its doc, and its tests — **zero callers in the daemon**:

```
$ grep -rn "retry_backoff\|error_retryable\|RETRY_MAX_ATTEMPTS" src/daemon src/provider --include=*.odin
src/provider/retry.odin:7:RETRY_MAX_ATTEMPTS :: 10
src/provider/retry.odin:29:retry_backoff :: proc(...)
src/provider/retry.odin:60:error_retryable :: proc(...)
src/provider/doc.odin:10: ... the engine drives the pure policy (`retry_backoff`,
(only definitions, doc, and *_test.odin — no daemon caller)
```

What actually runs is `src/daemon/session_run.odin:365`, `run_on_result`:

```odin
if result.err != .None {
    log.errorf("daemon: session %v turn failed: %v", run.session, result.err)
    code, message := run_fault(result.err)
    run_fail(run, code, message)   // terminal on the first transport error
    return
}
```

There is no attempt counter, no backoff timer, and no `error_retryable` check. The first
`Timed_Out` (or any retryable transport error) fails the whole turn. So although the policy promises
up to 10 attempts, every turn is single-attempt in practice.

## Fix (proposed, not yet applied)

Wire the policy into the run state machine:

- give `Run` an attempt counter (1-based) and a backoff timer op
- in `run_on_result`, when `result.err` is retryable *and* attempts remain *and* the run is not
  canceled, schedule `retry_backoff(attempt, retry_after, jitter)` and re-dispatch the same turn
  instead of calling `run_fail`
- only call `run_fail` when the error is non-retryable or the attempt budget is exhausted
- respect cancellation while parked in the backoff timer

`retry_after` should come from the transport (e.g. a `429`/`503` `Retry-After`); `jitter` is a
caller-supplied fraction in `[0,1]` so the policy stays pure.

## Notes

- The DB is `~/.local/share/yuke/`**`yuked`**`.db` (not `yuke.db`), and `sqlite3` CLI is not
  installed on this box — read it via Python's `sqlite3`.
- Separate open question worth its own investigation: *why* `minimax/MiniMax-M3` times out at all
  (slow first token / streaming stall vs. too-low a provider timeout). Retrying will paper over an
  occasional timeout but not a systematically slow endpoint.
