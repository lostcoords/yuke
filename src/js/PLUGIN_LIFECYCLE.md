# Plugin lifecycle

`plugins.use({ name, apply })` installs one plugin.
`apply(ctx)` returns `void` or `Promise<void>`.
It must not return a disposer.
A plugin has no `stop`; it releases each resource with `ctx.own`.

`plugins.use()` returns a handle with `ready` and `dispose()`.
Await `handle.ready` before use of a plugin that has async startup.
Startup failure or cancellation rejects `ready`.
Call `await handle.dispose()` or `await plugins.dispose(name)` before replacement.
Every disposal request during one close shares one promise; a sync close answers none.
The plugin retains its name until its releases, its startup, and its native drain complete.
An old handle cannot dispose a replacement.

One scope owns everything a plugin registers.
Use `ctx.effect()` for synchronous registrations and their cleanup callbacks.
Use `ctx.own(release)` for resources; a release may return a promise, and disposal awaits it.
Pass `ctx.signal` to native operations that must cancel on unload.
An `inject` block owns a child scope with its own effects, releases, and signal.

Disposal runs one fixed order for each scope, and for its child scopes first.
It cancels the signal, reverts the effects newest first, and awaits the child closes.
It then runs the releases newest first; an async release holds the next one until it settles.
It then drains the native operations of the signal.
A release registered after a resource runs before its release, so a graceful goodbye still has the resource.
A plugin that holds no async release, no signal, and no startup frees its name at once.
A child scope that closes on its own still holds its parent's close until its releases end.

A one-second local deadline frees the name if a release or the startup stalls.
Late registrations fail.
Late resource ownership releases the resource at once and fails.
JavaScript promises cannot force arbitrary plugin code to stop.

A release failure or timeout emits `ext.error` with the plugin name.
The disposal promise resolves after the releases and the native drain, even on a release failure.
A release fault after the deadline stays silent, so it cannot touch a replacement.

The host pumps native I/O during user-entry startup, with a ten-second deadline per startup evaluation.
The host checks plugin readiness after the entry module completes.
On entry failure, the host disposes incomplete startup and preserves the original fault text.

At process exit, the registry refuses new plugins and the engine refuses new requests.
The host disposes every plugin, newest first, and their async releases overlap.
Do not depend on another plugin's service in a release. The host keeps primitive I/O available.
All releases share a one-second shutdown deadline.
The host then gives forced disposal a separate 100 ms budget.
It cancels native work before it frees QuickJS.
The TUI completes plugin cleanup before it releases the renderer.

Normal engine events and tool dispatch stop during this phase.
The host continues process output, primitive results, timers, and promise jobs.
A temporary interrupt handler bounds JavaScript release code. The normal frame loop has no new deadline check.
