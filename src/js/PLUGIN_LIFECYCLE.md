# Plugin lifecycle

`plugins.use({ name, apply, stop? })` installs one plugin.
`apply(ctx, config)` returns `void` or `Promise<void>`.
It must not return a disposer.
The optional `stop(ctx)` returns `void` or `Promise<void>`.

`plugins.use()` returns a handle with `ready` and `dispose()`.
Await `handle.ready` before use of a plugin that has async startup.
Startup failure or cancellation rejects `ready`.
Call `await handle.dispose()` or `await plugins.dispose(name)` before replacement.
Concurrent async disposal requests share one promise.
The plugin retains its name until resource release and native drain complete.
An old handle cannot stop a replacement.

A synchronous plugin without `stop`, a signal, or owned resources disposes synchronously.
This path creates no disposal promise or timer.
`Scope.dispose()` remains synchronous.
Use `ctx.effect()` for synchronous registrations and their cleanup callbacks.
Use `ctx.own(release)` for resources with synchronous release callbacks.
Pass `ctx.signal` to native operations that must cancel on unload.

Disposal cancels the signal and withdraws registrations before `stop` runs.
Existing resources remain available to `stop`.
Startup and stop can overlap.
Disposal waits for both, then releases resources and drains native operations.
A one-second local deadline forces resource release if startup or stop stalls.
Late registrations fail.
Late resource ownership releases the resource at once and fails.
JavaScript promises cannot force arbitrary plugin code to stop.

A callback failure or timeout emits `ext.error` with the plugin name.
The disposal promise resolves after resource release and native drain, even on a callback failure.
A late result cannot dispose a replacement or emit a second stop error.

The host pumps native I/O during user-entry startup, with a ten-second deadline per startup evaluation.
The host checks plugin readiness after the entry module completes.
On entry failure, the host disposes incomplete startup and preserves the original fault text.

At process exit, the registry refuses new plugins and the engine refuses new requests.
The host starts all plugin stops. Async stops can overlap.
Do not depend on another plugin's service during stop. The host keeps primitive I/O available.
All stop callbacks share a one-second shutdown deadline.
The host then gives forced disposal a separate 100 ms budget.
It cancels native work before it frees QuickJS.
The TUI completes plugin cleanup before it releases the renderer.

Normal engine events and tool dispatch stop during this phase.
The host continues process output, primitive results, timers, and promise jobs.
A temporary interrupt handler bounds JavaScript stop code. The normal frame loop has no new deadline check.
