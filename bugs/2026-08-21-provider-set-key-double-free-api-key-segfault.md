# 2026-08-21 — `yuke provider set-key` double-frees the API key and segfaults on exit

## Symptom

On Linux, `yuke provider set-key <id>` does its job — the key is saved — then the process
crashes as it exits:

```
xyaman@awou:~/Work/yuke$ yuke provider set-key minimax
API key:
saved API key for minimax; restart yuked to apply it
Segmentation fault (core dumped)
```

The success message prints first, so the request round-trip and the daemon write both
succeeded. The crash is pure teardown: it happens *after* everything the user cares about
is done. Only the `set-key` path is affected — `list` and `remove-key` never allocate an
API key. Not reproduced on macOS (see Cause for why).

## Cause

`state.api_key` is freed twice.

`provider_key_prompt` returns a `strings.clone`'d string (`src/yuke/cmd_provider.odin:199`).
That single allocation is then deleted on two independent paths:

1. `provider_run` registers `defer delete(state.api_key)` right after the prompt
   (`src/yuke/cmd_provider.odin:60`), intending to own the key for the whole subcommand.

2. `provider_on_ready`, in the `.Set_Key` arm, *also* deletes it after sending the request
   (`src/yuke/cmd_provider.odin:96`) — and does **not** null the field:

```odin
case .Set_Key:
    daemon_session_send(
        s,
        .Auth_Set_Api_Key,
        wire.Auth_Set_Api_Key_Params{provider_id = wire.Provider_Id(state.provider_id), api_key = state.api_key},
        provider_on_response,
    )
    delete(state.api_key)   // frees the clone, but state.api_key still points at it
```

Control flow: `provider_run` → `daemon_session_run` runs the event loop to completion
(`on_ready` sends → response prints the success line → close → `done`), then returns; the
`defer` at line 60 fires and frees the *same* pointer a second time. Double free →
heap-allocator abort. On glibc this surfaces as `Segmentation fault (core dumped)` (or a
`free(): double free detected` abort depending on the tunables); macOS's allocator happens
to tolerate the second free of that block, which is why it never crashed in local dev.

The in-handler `delete` at line 96 is *timing*-safe on its own — it is not a
use-after-free. `client_send_request` encodes the params synchronously into a fresh emitter
and sends the text before returning (`src/client/client.odin:285-288`), so `api_key` is
fully consumed by the time `daemon_session_send` returns. The bug is solely the redundant
second free of a pointer the `defer` already owns.

## Fix (proposed, not yet applied)

The `defer delete(state.api_key)` in `provider_run` is the single owner and already covers
every exit path. The cleanest fix is to **delete the redundant free** at
`src/yuke/cmd_provider.odin:96` and let the `defer` do the one free:

```odin
case .Set_Key:
    daemon_session_send(
        s,
        .Auth_Set_Api_Key,
        wire.Auth_Set_Api_Key_Params{provider_id = wire.Provider_Id(state.provider_id), api_key = state.api_key},
        provider_on_response,
    )
```

If the intent of line 96 was to wipe key material from the heap as early as possible (right
after it is sent, rather than at subcommand end), note that plain `delete` does **not** zero
the freed bytes — it only frees them, so it buys no security over the `defer`. To actually
scrub early, keep a single owner: null the field after freeing so the `defer` is a no-op,
e.g.

```odin
    delete(state.api_key)
    state.api_key = ""   // defer delete("") is a safe no-op
```

Prefer the first form (just remove line 96) unless early scrubbing is a deliberate
requirement; either way the invariant is **exactly one free per allocation**.

## Notes

- Blast radius is cosmetic-plus: the key is written correctly and the exit code path in
  `main` (`provider_run` returns `0`, so `os.exit` is skipped) is never reached because the
  crash pre-empts it. A double-free abort can in principle be exploited depending on heap
  state, so treat it as more than a nuisance even though the observable effect is "crashes
  after succeeding."
- The macOS/Linux divergence is the tell: any "works on my Mac, segfaults on the Linux box"
  memory crash should prompt a hunt for double-free / use-after-free, since the two
  allocators disagree on how loudly they punish it.
- A `-sanitize:address` build (or running under valgrind) on Linux would flag this at the
  second `free` with the exact allocation site; worth wiring into CI for the `yuke` binary.
