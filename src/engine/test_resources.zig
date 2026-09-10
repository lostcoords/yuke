//! Test resources stay at one address until all engines that borrow them close.

const std = @import("std");
const zio = @import("zio");
const ai = @import("ai");
const Engine = @import("Engine.zig");
const Database = @import("../store/store.zig").Database;
const ProviderStore = @import("../provider/provider_store.zig");

runtime: *zio.Runtime,
env: std.process.Environ.Map,
providers: ProviderStore,
transport: ai.transport.CannedTransport,

pub fn init(self: *@This()) !void {
    std.debug.assert(@import("builtin").is_test);
    self.runtime = try zio.Runtime.init(std.testing.allocator, .{ .executors = .exact(1) });
    self.env = .init(std.testing.allocator);
    self.providers = .init(std.testing.allocator, self.runtime.io(), &self.env);
    self.transport = .{ .bytes = ai.transport.canned_reply };
    std.debug.assert(self.providers.env == &self.env);
}

pub fn deinit(self: *@This()) void {
    std.debug.assert(self.providers.env == &self.env);
    self.providers.deinit();
    self.env.deinit();
    self.runtime.deinit();
    self.* = undefined;
}

pub fn makeEngine(self: *@This(), db: *Database) Engine {
    std.debug.assert(self.providers.env == &self.env);
    return Engine.init(.{
        .gpa = std.testing.allocator,
        .io = self.runtime.io(),
        .db = db,
        .providers = &self.providers,
        .route_transport = self.transport.transport(),
        .execution = @import("../execution.zig").testContext(&self.env),
    });
}
