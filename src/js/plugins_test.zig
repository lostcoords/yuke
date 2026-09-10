const support = @import("test_support.zig");
const host_mod = @import("host.zig");
const std = @import("std");
const Host = @import("host.zig").Host;

test "plugin scope contracts" {
    const host = Host.create(std.testing.allocator);
    defer host.destroy();
    try support.eval(host, "tests/plugins/scope.test.js");
}

test "plugin events contracts" {
    const host = Host.create(std.testing.allocator);
    defer host.destroy();
    try support.eval(host, "tests/plugins/events.test.js");
}

test "plugin commands contracts" {
    const host = Host.create(std.testing.allocator);
    defer host.destroy();
    try support.eval(host, "tests/plugins/commands.test.js");
}

test "plugin keymap contracts" {
    const host = Host.create(std.testing.allocator);
    defer host.destroy();
    try support.eval(host, "tests/plugins/keymap.test.js");
}

test "plugin advice contracts" {
    const host = Host.create(std.testing.allocator);
    defer host.destroy();
    try support.eval(host, "tests/plugins/advice.test.js");
}

test "plugin services contracts" {
    const host = Host.create(std.testing.allocator);
    defer host.destroy();
    try support.eval(host, "tests/plugins/services.test.js");
}

test "plugin plugins contracts" {
    const host = Host.create(std.testing.allocator);
    defer host.destroy();
    try support.eval(host, "tests/plugins/plugins.test.js");
}

test "plugin style contracts" {
    const host = Host.create(std.testing.allocator);
    defer host.destroy();
    try support.eval(host, "tests/plugins/style.test.js");
}

test "plugin status contracts" {
    const host = Host.create(std.testing.allocator);
    defer host.destroy();
    try support.eval(host, "tests/plugins/status.test.js");
}

test "plugin context contracts" {
    const host = Host.create(std.testing.allocator);
    defer host.destroy();
    try support.eval(host, "tests/plugins/context.test.js");
}

test "the yuke facade exports config, plugins, and the tool registry" {
    const host = Host.create(std.testing.allocator);
    defer host.destroy();

    try support.eval(host, "tests/plugins/facade-entry.test.js");

    // The facade reaches the same native table the engine borrows.
    try std.testing.expectEqual(@as(usize, 1), host.tools.entries.items.len);
    try std.testing.expectEqualStrings("facade_tool", host.tools.entries.items[0].decl.name);
    try std.testing.expectEqual(@as(i32, 1), try host.evalInt("globalThis.named === 'from-facade' ? 1 : 0"));
    // `defineConfig` through the facade reaches the same live config object.
    try std.testing.expectEqual(@as(i32, 500), try host.evalInt("globalThis.chord"));
}

test "the facade and its internal module share one instance" {
    const host = Host.create(std.testing.allocator);
    defer host.destroy();

    // A second module name must not create a second plugin registry.
    try support.eval(host, "tests/plugins/identity.test.js");
}

test "tools.define refuses a definition that is not an object" {
    const host = Host.create(std.testing.allocator);
    defer host.destroy();

    try support.eval(host, "tests/plugins/bad-tool.test.js");
    try std.testing.expectEqual(@as(i32, 4), try host.evalInt("globalThis.refused"));
    try std.testing.expectEqual(@as(usize, 0), host.tools.entries.items.len);
}

test "inject holds a block until every capability exists" {
    const host = Host.create(std.testing.allocator);
    defer host.destroy();
    try support.eval(host, "tests/plugins/inject-gate.test.js");
}

test "inject waits for every name and stops watching with its plugin" {
    const host = Host.create(std.testing.allocator);
    defer host.destroy();
    try support.eval(host, "tests/plugins/inject-deps.test.js");
}

test "inject refuses a bad declaration and survives a throwing block" {
    const host = Host.create(std.testing.allocator);
    defer host.destroy();
    try support.eval(host, "tests/plugins/inject-bad.test.js");
}

test "a disposed injection never builds from a copied watcher list" {
    const host = Host.create(std.testing.allocator);
    defer host.destroy();
    try support.eval(host, "tests/plugins/inject-reentrancy.test.js");
}

test "a service event always reports the live provider" {
    const host = Host.create(std.testing.allocator);
    defer host.destroy();
    try support.eval(host, "tests/plugins/service-event-live.test.js");
}

test "a capability binds onto the block that declared it" {
    const host = Host.create(std.testing.allocator);
    defer host.destroy();
    try support.eval(host, "tests/plugins/capability-binding.test.js");
}

test "a host with no renderer loads the view tier and leaves a view plugin inert" {
    const host = host_mod.Host.create(std.testing.allocator);
    defer host.destroy();

    // `index.js` is one file for both frontends, so a view import must load with no terminal bound.
    try support.eval(host, "tests/plugins/view-inert.test.js");
}

test "the kernel alone runs without the terminal tier" {
    const host = Host.create(std.testing.allocator);
    defer host.destroy();
    var loader: KernelLoader = .{ .inner = &host.loader };
    host.runtime.setModuleLoader(&loader);
    defer host.runtime.setModuleLoader(&host.loader);
    try support.eval(host, "tests/plugins/headless.test.js");
}

test "a change during a build rebuilds the block instead of leaving it stale" {
    const host = Host.create(std.testing.allocator);
    defer host.destroy();
    try support.eval(host, "tests/plugins/inject-dirty.test.js");
}

test "a headless bus refuses a name only the view tier emits" {
    const host = host_mod.Host.create(std.testing.allocator);
    defer host.destroy();

    // Without the view tier nothing emits these names, so a listener would wait for ever.
    try support.eval(host, "tests/plugins/headless-bus.test.js");
}

test "an overlay survives a rebuild of the block that claimed it" {
    const host = Host.create(std.testing.allocator);
    defer host.destroy();
    try support.eval(host, "tests/plugins/overlay-rebuild.test.js");
}

test "a plugin owns the tools it defines and withdraws them on unload" {
    const host = Host.create(std.testing.allocator);
    defer host.destroy();
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
    const host = Host.create(std.testing.allocator);
    defer host.destroy();
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
    const host = Host.create(std.testing.allocator);
    defer host.destroy();
    try support.eval(host, "tests/plugins/bus-fault.test.js");
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
