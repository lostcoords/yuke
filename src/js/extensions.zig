//! Compose the one QuickJS host used by the TUI and JSONL RPC frontends.

const std = @import("std");
const zio = @import("zio");
const host_mod = @import("host.zig");
const tool_run = @import("tool_run.zig");
const owner = @import("owner.zig");
const App = @import("../app/app.zig").App;

pub const Host = host_mod.Host;

pub const Options = struct {
    host: host_mod.Options,
    boot: [:0]const u8,
    config_dir: ?[]const u8 = null,
};

/// Own the QuickJS host and the wake event that all non-owner tasks use.
pub const Extensions = struct {
    app: *App,
    host: *Host,
    wake: zio.ResetEvent = .init,
    user_entry_fault: bool = false,

    /// Create one host, evaluate the common graph and install its tools in the engine.
    pub fn init(self: *Extensions, gpa: std.mem.Allocator, io: std.Io, app: *App, opts: Options) !void {
        self.app = app;
        self.user_entry_fault = false;
        self.wake = .init;
        const host = try Host.createWith(gpa, io, opts.host);
        errdefer host.destroy();
        self.host = host;
        host.owner_wake = &self.wake;
        host.engine.wake = &self.wake;
        host.engine.attach(app);

        host.interrupt_budget = std.math.maxInt(u32);
        try host.evalModule(opts.boot, "boot.js");
        host.interrupt_budget = host_mod.default_interrupt_budget;
        evalUserEntry(host, opts.config_dir) catch |err| switch (err) {
            error.JavaScriptFault => self.user_entry_fault = true,
            else => return err,
        };
        // Load built-ins last so a user tool with the same name wins.
        try host.evalModule("import \"yuke:builtins\";", "builtins.js");

        app.engine.installTools(tool_run.toolSet(host));
    }

    pub fn deinit(self: *Extensions) void {
        // Stop and join every turn before the engine drops its borrowed host set.
        self.app.engine.stopTurns();
        self.app.engine.clearTools();
        self.host.destroy();
        self.* = undefined;
    }
};

pub const user_entry = "index.js";

/// Evaluate `<config_dir>/index.js`; an absent file is valid.
pub fn evalUserEntry(host: *Host, config_dir: ?[]const u8) host_mod.Error!void {
    const dir = config_dir orelse return;
    const path = try std.fs.path.joinZ(host.gpa, &.{ dir, user_entry });
    defer host.gpa.free(path);
    _ = try host.evalFile(path);
}

test "headless extensions pump an async JavaScript tool" {
    const ai = @import("ai");
    const database = @import("../store/store.zig");

    var gpa = std.heap.DebugAllocator(.{}).init;
    defer std.debug.assert(gpa.deinit() == .ok);

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "note.txt", .data = "from rpc" });
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = user_entry, .data =
        \\import { defineConfig, tools } from "yuke";
        \\defineConfig({ systemPrompt: "configured by JavaScript" });
        \\import { fs } from "yuke:fs";
        \\tools.define({
        \\  name: "read_note",
        \\  description: "Read the note.",
        \\  parameters: { type: "object", properties: { path: { type: "string" } } },
        \\  execute: async ({ path }) => ({ text: await fs.readFile(path) }),
        \\});
    });
    var root_buf: [std.fs.max_path_bytes]u8 = undefined;
    const root = root_buf[0..try tmp.dir.realPath(std.testing.io, &root_buf)];

    var reactor = try zio.Runtime.init(gpa.allocator(), .{ .executors = .exact(1) });
    defer reactor.deinit();
    var env: std.process.Environ.Map = .init(gpa.allocator());
    defer env.deinit();
    var canned = ai.transport.CannedTransport{ .bytes = ai.transport.canned_reply };
    var app_runtime: App = undefined;
    try app_runtime.initTest(gpa.allocator(), reactor.io(), try database.Database.openTest(), &env, canned.transport());
    var extensions: Extensions = undefined;
    try extensions.init(gpa.allocator(), reactor.io(), &app_runtime, .{
        .host = .{ .headless = true, .cwd = root, .env = &env },
        .boot = "import \"yuke:kernel\";\nimport \"yuke:ext\";",
        .config_dir = root,
    });
    defer {
        extensions.deinit();
        app_runtime.engine.close();
        app_runtime.db.deinit();
        app_runtime.store.deinit();
        app_runtime.logins.deinit();
    }
    try std.testing.expect(!extensions.user_entry_fault);
    // The engine asks the host, so the user tool and every built-in reach the provider together.
    const installed = app_runtime.engine.deps.tools;
    const advertised = installed.getDecls(installed.ctx);
    try std.testing.expectEqual(extensions.host.tools.decls.items.len, advertised.len);
    const found = for (advertised) |d| {
        if (std.mem.eql(u8, d.name, "read_note")) break true;
    } else false;
    try std.testing.expect(found);
    try std.testing.expectEqualStrings("configured by JavaScript", app_runtime.engine.default_system_prompt.?);
    try extensions.host.evalModule(
        \\import { defineConfig } from "yuke";
        \\defineConfig({ systemPrompt: null });
    , "clear-config.js");
    try std.testing.expect(app_runtime.engine.default_system_prompt == null);
    try extensions.host.evalModule(
        \\import { defineConfig } from "yuke";
        \\let rejected = false;
        \\try { defineConfig({ systemPrompt: "x".repeat(1048577) }); } catch { rejected = true; }
        \\globalThis.configRejected = rejected;
    , "bad-config.js");
    try std.testing.expectEqual(@as(i32, 1), try extensions.host.evalInt("globalThis.configRejected"));
    try std.testing.expect(app_runtime.engine.default_system_prompt == null);

    const call = try extensions.host.calls.submit("read_note", "{\"path\":\"note.txt\"}");
    try owner.pump(extensions.host);
    var rounds: u32 = 0;
    while (call.state != .settled) : (rounds += 1) {
        if (rounds == 64) return error.CallNeverSettled;
        extensions.wake.timedWait(.fromMilliseconds(1000)) catch {};
        extensions.wake.reset();
        try owner.pump(extensions.host);
    }
    try std.testing.expect(!call.is_error);
    try std.testing.expectEqualStrings("{\"text\":\"from rpc\"}", call.text.?);
    extensions.host.calls.finish(call);
    try owner.pump(extensions.host);
}

test "a plugin notice reaches every attached frontend" {
    const ai = @import("ai");
    const database = @import("../store/store.zig");
    const rpc_boot = @import("../app/rpc.zig").boot;
    const proto = @import("proto");

    var gpa = std.heap.DebugAllocator(.{}).init;
    defer std.debug.assert(gpa.deinit() == .ok);

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = user_entry, .data = "" });
    var root_buf: [std.fs.max_path_bytes]u8 = undefined;
    const root = root_buf[0..try tmp.dir.realPath(std.testing.io, &root_buf)];

    var reactor = try zio.Runtime.init(gpa.allocator(), .{ .executors = .exact(1) });
    defer reactor.deinit();
    var env: std.process.Environ.Map = .init(gpa.allocator());
    defer env.deinit();
    var canned = ai.transport.CannedTransport{ .bytes = ai.transport.canned_reply };
    var app_runtime: App = undefined;
    try app_runtime.initTest(gpa.allocator(), reactor.io(), try database.Database.openTest(), &env, canned.transport());
    var extensions: Extensions = undefined;
    try extensions.init(gpa.allocator(), reactor.io(), &app_runtime, .{
        .host = .{ .headless = true, .cwd = root, .env = &env },
        .boot = rpc_boot,
        .config_dir = root,
    });
    defer {
        extensions.deinit();
        app_runtime.engine.close();
        app_runtime.db.deinit();
        app_runtime.store.deinit();
        app_runtime.logins.deinit();
    }
    try std.testing.expect(!extensions.user_entry_fault);

    // A frontend attaches here, so the notice has somewhere to arrive.
    const Capture = struct {
        level: proto.enums.NoticeLevel = .info,
        source: [64]u8 = undefined,
        source_len: usize = 0,
        message: [64]u8 = undefined,
        message_len: usize = 0,
        seen: usize = 0,

        fn onEvent(ctx: *anyopaque, note: proto.rpc.Notification) void {
            const self: *@This() = @ptrCast(@alignCast(ctx));
            if (note.method != .notice) return;
            self.seen += 1;
            self.level = note.params.notice.level;
            self.source_len = note.params.notice.source.len;
            @memcpy(self.source[0..self.source_len], note.params.notice.source);
            self.message_len = note.params.notice.message.len;
            @memcpy(self.message[0..self.message_len], note.params.notice.message);
        }
    };
    var capture: Capture = .{};
    app_runtime.engine.sinks.add(.{ .ctx = @ptrCast(&capture), .on_event = Capture.onEvent });
    defer app_runtime.engine.sinks.remove(@ptrCast(&capture));

    try extensions.host.evalModule(
        \\import { plugins } from "yuke:ext";
        \\plugins.use({ name: "reporter", apply(ctx) { ctx.interaction.notify("build failed", "warn"); } });
    , "notify.js");

    try std.testing.expectEqual(@as(usize, 1), capture.seen);
    try std.testing.expectEqual(proto.enums.NoticeLevel.warn, capture.level);
    try std.testing.expectEqualStrings("reporter", capture.source[0..capture.source_len]);
    try std.testing.expectEqualStrings("build failed", capture.message[0..capture.message_len]);
}
