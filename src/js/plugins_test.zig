const support = @import("test_support.zig");
const std = @import("std");
const Host = @import("host.zig").Host;

test "public tools and commands leave with their owners" {
    const host = support.createHost();
    defer support.destroyHost(host);
    try support.eval(host, "tests/plugins/public-own.test.js");
    try std.testing.expectEqual(@as(usize, 0), host.tools.entries.items.len);
}

test "plugin scope contracts" {
    try support.run("tests/plugins/scope.test.js");
}

test "plugin events contracts" {
    try support.run("tests/plugins/events.test.js");
}

test "plugin commands contracts" {
    try support.run("tests/plugins/commands.test.js");
}

test "plugin keymap contracts" {
    try support.run("tests/plugins/keymap.test.js");
}

test "plugin advice contracts" {
    try support.run("tests/plugins/advice.test.js");
}

test "plugin services contracts" {
    try support.run("tests/plugins/services.test.js");
}

test "plugin plugins contracts" {
    try support.run("tests/plugins/plugins.test.js");
}

test "plugin style contracts" {
    try support.run("tests/plugins/style.test.js");
}

test "plugin status contracts" {
    try support.run("tests/plugins/status.test.js");
}

test "plugin context contracts" {
    try support.run("tests/plugins/context.test.js");
}

test "the yuke facade exports config, plugins, and the tool registry" {
    const host = support.createHost();
    defer support.destroyHost(host);

    try support.eval(host, "tests/plugins/facade-entry.test.js");

    // The facade reaches the same native table the engine borrows.
    try std.testing.expectEqual(@as(usize, 1), host.tools.entries.items.len);
    try std.testing.expectEqualStrings("facade_tool", host.tools.entries.items[0].decl.name);
    try std.testing.expectEqual(@as(i32, 1), try host.evalInt("globalThis.named === 'from-facade' ? 1 : 0"));
    // `defineConfig` through the facade reaches the same live config object.
    try std.testing.expectEqual(@as(i32, 500), try host.evalInt("globalThis.chord"));
}

test "the facade and its internal module share one instance" {
    // A second module name must not create a second plugin registry.
    try support.run("tests/plugins/identity.test.js");
}

test "tools.define refuses a definition that is not an object" {
    const host = support.createHost();
    defer support.destroyHost(host);

    try support.eval(host, "tests/plugins/bad-tool.test.js");
    try std.testing.expectEqual(@as(i32, 4), try host.evalInt("globalThis.refused"));
    try std.testing.expectEqual(@as(usize, 0), host.tools.entries.items.len);
}

test "inject holds a block until every capability exists" {
    try support.run("tests/plugins/inject-gate.test.js");
}

test "inject waits for every name and stops watching with its plugin" {
    try support.run("tests/plugins/inject-deps.test.js");
}

test "inject refuses a bad declaration and survives a throwing block" {
    try support.run("tests/plugins/inject-bad.test.js");
}

test "a disposed injection never builds from a copied watcher list" {
    try support.run("tests/plugins/inject-reentrancy.test.js");
}

test "a service event always reports the live provider" {
    try support.run("tests/plugins/service-event-live.test.js");
}

test "a capability binds onto the block that declared it" {
    try support.run("tests/plugins/capability-binding.test.js");
}

test "a host with no renderer loads the view tier and leaves a view plugin inert" {
    // `index.js` is one file for both frontends, so a view import must load with no terminal bound.
    try support.run("tests/plugins/view-inert.test.js");
}

test "the kernel alone runs without the terminal tier" {
    const host = support.createHost();
    defer support.destroyHost(host);
    var loader: KernelLoader = .{ .inner = &host.loader };
    host.runtime.setModuleLoader(&loader);
    defer host.runtime.setModuleLoader(&host.loader);
    try support.eval(host, "tests/plugins/headless.test.js");
}

test "a change during a build rebuilds the block instead of leaving it stale" {
    try support.run("tests/plugins/inject-dirty.test.js");
}

test "a headless bus refuses a name only the view tier emits" {
    // Without the view tier nothing emits these names, so a listener would wait for ever.
    try support.run("tests/plugins/headless-bus.test.js");
}

test "an overlay survives a rebuild of the block that claimed it" {
    try support.run("tests/plugins/overlay-rebuild.test.js");
}

test "a plugin owns the tools it defines and withdraws them on unload" {
    const host = support.createHost();
    defer support.destroyHost(host);
    try support.eval(host, "tests/plugins/own.test.js");

    // The plugin registered both, and the table keeps them sorted.
    try std.testing.expectEqual(@as(usize, 2), host.tools.entries.items.len);
    try std.testing.expectEqualStrings("alpha", host.tools.entries.items[0].decl.name);
    try std.testing.expectEqualStrings("zeta", host.tools.entries.items[1].decl.name);

    // An unload withdraws every tool the plugin owned.
    try support.eval(host, "tests/plugins/drop.test.js");
    try std.testing.expectEqual(@as(usize, 0), host.tools.entries.items.len);

    // The name is free again, so a reload can register it.
    try support.eval(host, "tests/plugins/reload.test.js");
    try std.testing.expectEqual(@as(usize, 1), host.tools.entries.items.len);
}

test "one tool leaves without moving the others" {
    const host = support.createHost();
    defer support.destroyHost(host);
    try support.eval(host, "tests/plugins/three.test.js");
    try std.testing.expectEqual(@as(usize, 4), host.tools.entries.items.len);

    // Drop the middle tool. The rest must keep their order, so the advertised prefix is unchanged.
    try host.evalModule("globalThis.drop();", "drop-one.js");
    try std.testing.expectEqual(@as(usize, 3), host.tools.entries.items.len);
    try std.testing.expectEqualStrings("alpha", host.tools.entries.items[0].decl.name);
    try std.testing.expectEqualStrings("mike", host.tools.entries.items[1].decl.name);
    try std.testing.expectEqualStrings("zulu", host.tools.entries.items[2].decl.name);
}

test "a listener fault reaches the shared error bus" {
    try support.run("tests/plugins/bus-fault.test.js");
}

const KernelLoader = struct {
    inner: *@import("loader.zig").Loader,

    pub fn onNormalize(self: *@This(), ctx: @import("quickjs").Context, base: []const u8, name: []const u8) ?[:0]u8 {
        for ([_][]const u8{ "yuke:kernel", "yuke:engine-native", "yuke:test" }) |allowed| {
            if (std.mem.eql(u8, name, allowed)) return self.inner.onNormalize(ctx, base, name);
        }
        _ = ctx.throwReferenceError("the kernel imported a module outside its boundary");
        return null;
    }

    pub fn onLoadModule(self: *@This(), ctx: @import("quickjs").Context, name: []const u8) ?@import("quickjs").Context.Module {
        return self.inner.onLoadModule(ctx, name);
    }
};

test "plugin stop shares its promise and holds its name until disposal" {
    const host = support.createHost();
    defer support.destroyHost(host);
    try support.eval(host, "tests/plugins/stop.test.js");
    try support.pumpUntilTrue(host, "globalThis.stopDone");
    try std.testing.expectEqual(@as(usize, 0), host.timers.entries.items.len);
}

test "plugin stop timeout releases the scope and ignores late failure" {
    const host = support.createHost();
    defer support.destroyHost(host);
    try support.eval(host, "tests/plugins/stop-timeout.test.js");
    try support.pumpUntilTrue(host, "globalThis.stopDone");
    try std.testing.expectEqual(@as(usize, 0), host.timers.entries.items.len);
}

test "plugin stop faults still dispose every scope" {
    const host = support.createHost();
    defer support.destroyHost(host);
    try support.eval(host, "tests/plugins/stop-fault.test.js");
    try support.pumpUntilTrue(host, "globalThis.stopDone");
}

test "shutdown permits process I/O and timers before resource release" {
    const reactor = try @import("zio").Runtime.init(std.testing.allocator, .{ .executors = .exact(1) });
    defer reactor.deinit();
    const host = support.createHostWith(reactor.io(), "/tmp");
    defer support.destroyHost(host);
    try host.evalModule(
        \\import { plugins, spawn, client } from "yuke";
        \\let child;
        \\globalThis.stopped = "";
        \\plugins.use({ name: "flush", apply(ctx) {
        \\  child = spawn(["/bin/cat"]);
        \\  child.onStdout(text => { globalThis.stopped += text; });
        \\  ctx.own(() => { child.kill(); globalThis.stopped += "disposed"; });
        \\}, async stop() {
        \\  await import("yuke/ui");
        \\  await new Promise(resolve => setTimeout(resolve, 1));
        \\  await child.write("flushed:");
        \\  child.closeStdin();
        \\  await child.exited;
        \\  try { await client.sessionList(); } catch (error) {
        \\    if (error.message === "the host is closed") globalThis.stopped += "refused:";
        \\  }
        \\} });
    , "shutdown-io.js");
    try host.close();
    try support.expectString(host, "stopped", "flushed:refused:disposed");
    try std.testing.expectEqual(@as(usize, 0), host.ops.live.items.len);
    try std.testing.expectEqual(@as(usize, 0), host.procs.live.items.len);
}

test "shutdown has one deadline and forces disposal of stalled plugins" {
    const host = support.createHost();
    defer support.destroyHost(host);
    try host.evalModule(
        \\import { plugins } from "yuke";
        \\globalThis.stopped = "";
        \\for (const name of ["a", "b", "c"]) plugins.use({ name,
        \\  apply(ctx) { ctx.effect(() => () => { globalThis.stopped += name; }); },
        \\  stop() { return new Promise(() => {}); }
        \\});
    , "shutdown-stall.js");
    const start = std.Io.Timestamp.now(host.io, .awake);
    try host.close();
    const elapsed = start.durationTo(std.Io.Timestamp.now(host.io, .awake)).toMilliseconds();
    try std.testing.expect(elapsed < 2500);
    try support.expectString(host, "stopped", "cba");
}

test "shutdown bounds synchronous stop code and still disposes its scope" {
    const host = support.createHost();
    defer support.destroyHost(host);
    try host.evalModule(
        \\import { plugins } from "yuke";
        \\globalThis.stopped = "";
        \\plugins.use({ name: "spin",
        \\  apply(ctx) { ctx.effect(() => () => { globalThis.stopped = "disposed"; }); },
        \\  stop() { while (true) {} }
        \\});
    , "shutdown-spin.js");
    const start = std.Io.Timestamp.now(host.io, .awake);
    host.stopPlugins();
    try std.testing.expect(start.durationTo(std.Io.Timestamp.now(host.io, .awake)).toMilliseconds() < 2500);
    try host.close();
    try support.expectString(host, "stopped", "disposed");
}

test "async plugin startup cancels, releases late resources, and isolates a replacement" {
    const host = support.createHost();
    defer support.destroyHost(host);
    try support.eval(host, "tests/plugins/start.test.js");
    try support.pumpUntilTrue(host, "globalThis.startDone");
    try support.expectString(host, "globalThis.startFailure || ''", "");
    try std.testing.expectEqual(@as(usize, 0), host.signal_waiters.items.len);
    try std.testing.expectEqual(@as(usize, 0), host.timers.entries.items.len);
}

test "a capability withdrawal closes its child resource owner" {
    const host = support.createHost();
    defer support.destroyHost(host);
    try support.eval(host, "tests/plugins/resource-child.test.js");
    try support.pumpUntilTrue(host, "globalThis.childDone");
    try std.testing.expectEqual(@as(usize, 0), host.signal_waiters.items.len);
}

test "unload bounds startup that ignores cancellation" {
    const host = support.createHost();
    defer support.destroyHost(host);
    try support.eval(host, "tests/plugins/start-timeout.test.js");
    try support.pumpUntilTrue(host, "globalThis.startDone");
    try support.expectString(host, "globalThis.startFailure || ''", "");
    try std.testing.expectEqual(@as(usize, 0), host.timers.entries.items.len);
}

test "plugin unload cancels and drains native startup" {
    const reactor = try @import("zio").Runtime.init(std.testing.allocator, .{ .executors = .exact(1) });
    defer reactor.deinit();
    const host = support.createHostWith(reactor.io(), "/tmp");
    defer support.destroyHost(host);
    try host.evalModule(
        \\import { plugins, exec } from "yuke";
        \\globalThis.startCanceled = false;
        \\globalThis.disposed = false;
        \\const handle = plugins.use({ name: "native-start", async apply(ctx) {
        \\  try { await exec("sleep 30", { signal: ctx.signal }); }
        \\  catch { globalThis.startCanceled = true; }
        \\} });
        \\handle.dispose().then(() => { globalThis.disposed = true; });
    , "native-start.js");
    try support.pumpUntilTrue(host, "globalThis.disposed");
    try std.testing.expectEqual(@as(i32, 1), try host.evalInt("globalThis.startCanceled ? 1 : 0"));
    try std.testing.expectEqual(@as(usize, 0), host.ops.live.items.len);
    try std.testing.expectEqual(@as(usize, 0), host.signal_waiters.items.len);
}

test "resource release is LIFO, idempotent, and safe under reentrant disposal" {
    const host = support.createHost();
    defer support.destroyHost(host);
    try support.eval(host, "tests/plugins/resource-release.test.js");
    try support.pumpUntilTrue(host, "globalThis.resourcesDone");
}

test "plugin disposal joins native work from a withdrawn injection" {
    const reactor = try @import("zio").Runtime.init(std.testing.allocator, .{ .executors = .exact(1) });
    defer reactor.deinit();
    const host = support.createHostWith(reactor.io(), "/tmp");
    defer support.destroyHost(host);
    try host.evalModule(
        \\import { plugins, exec, services } from "yuke";
        \\globalThis.childCanceled = false;
        \\globalThis.disposed = false;
        \\const withdraw = services.provide("child-resource", 1);
        \\const handle = plugins.use({ name: "native-child", apply(ctx) {
        \\  ctx.inject(["child-resource"], child => {
        \\    exec("sleep 30", { signal: child.signal }).catch(() => { globalThis.childCanceled = true; });
        \\  });
        \\} });
        \\withdraw();
        \\handle.dispose().then(() => { globalThis.disposed = true; });
    , "native-child.js");
    try support.pumpUntilTrue(host, "globalThis.disposed");
    try std.testing.expectEqual(@as(i32, 1), try host.evalInt("globalThis.childCanceled ? 1 : 0"));
    try std.testing.expectEqual(@as(usize, 0), host.ops.live.items.len);
    try std.testing.expectEqual(@as(usize, 0), host.signal_waiters.items.len);
}

test "Herdr plugin isolates reports, retries, and cleanup" {
    const host = support.createHost();
    defer support.destroyHost(host);
    try support.eval(host, "tests/plugins/herdr.test.js");
    try support.pumpUntilTrue(host, "globalThis.herdrDone === true");
}
