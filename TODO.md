# yuke — open items

Last verified: 2026-09-10.

## Break the engine import cycle

`src/engine/request.zig:94` imports `compaction.zig`, `src/engine/compaction.zig:255` imports
`model_call.zig`, and `src/engine/model_call.zig:60` imports `request.zig`. The three files form a
loop.

Zig analyzes lazily, so the loop compiles today and no test fails. It is a layering smell, not a
fault.

`model_call.zig` closes the loop for one function, `reasoningFor`. That function maps a configured
level onto one model and reads nothing else from the request builder. A neutral home for it, such as
`model_config.zig` or `context.zig`, breaks the loop and moves no other code.

Check this again when the engine layering changes. Confirm each of the three lines still holds
before any work, because a moved import makes this note wrong.

## Replace the posix_spawn shim when Zig std gains a session option

`src/js/host/process.zig` spawns the exec child with libc `posix_spawn` and `POSIX_SPAWN_SETSID`
through the translate-c module from `src/c/spawn.h`. Zig 0.16 `std.process.SpawnOptions` has no
session flag. ziglang/zig#19205 tracks a detached option.

When std adds the option, replace `spawnDetached` with `std.process.spawn`. Delete `src/c/spawn.h`
and the `spawn_c` module in `build.zig`. Keep the four session tests. See `docs/exec-terminal-detach.md`.
