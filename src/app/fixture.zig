//! App fixtures own a private database and borrow a canned transport at a stable address.

const std = @import("std");
const ai = @import("ai");
const App = @import("app.zig").App;
const Database = @import("../store/store.zig").Database;
const execution = @import("../execution.zig");
const provider = @import("../provider/provider.zig");
const Engine = @import("../engine/Engine.zig");
const builtin = @import("builtin");

/// Initialize caller-owned app memory; the caller must call `App.deinit` before it moves.
pub fn init(app: *App, gpa: std.mem.Allocator, io: std.Io, blob_dir: []const u8, route_transport: ai.transport.Transport, context: execution.Context) !void {
    const owned_dir = try gpa.dupe(u8, blob_dir);
    errdefer gpa.free(owned_dir);
    app.* = .{
        .gpa = gpa,
        .io = io,
        .http_transport = .init(gpa, io, null, "yuke-fixture"),
        .db = try Database.openTest(),
        .blob_dir = owned_dir,
        .logins = .init(gpa),
        .store = .init(gpa, io, context.env),
        .engine = undefined,
    };
    app.engine = Engine.init(.{
        .gpa = gpa,
        .io = io,
        .db = &app.db,
        .blobs = .{ .dir = app.blob_dir },
        .providers = &app.store,
        .route_transport = route_transport,
        .execution = context,
    });
    app.scheduler = .init(app);
    std.debug.assert(app.engine.deps.db == &app.db);
    std.debug.assert(app.store.env == context.env);
}

/// Offer `test/model` so a test that creates a session can name a model the catalog serves.
pub fn installModel(self: *App) !void {
    std.debug.assert(builtin.is_test);
    var local = try provider.config.loadBytes(self.gpa,
        \\{"providers":[{"id":"test","base_url":"http://localhost:1/v1","endpoints":[{"protocol":"openai_chat"}],"models":[{"id":"model","upstream_id":"model","flags":{"supports_tools":true}}]}]}
    );
    _ = self.store.installLocal(&local) catch |err| {
        local.deinit();
        return err;
    };
}
