//! Compose the one QuickJS host used by the TUI and JSONL RPC frontends.

const std = @import("std");
const zio = @import("zio");
const host_mod = @import("host.zig");
const port = @import("port.zig");
const App = @import("../app/app.zig").App;

pub const Host = host_mod.Host;

pub const Options = struct {
    host: host_mod.Options,
    boot: [:0]const u8,
    config_dir: ?[]const u8 = null,
};

/// Own the QuickJS host and the plugin graph it evaluated.
pub const Extensions = struct {
    app: *App,
    host: *Host,
    user_entry_fault: bool = false,

    /// Create one host, evaluate the common graph and install its tools in the engine.
    pub fn init(self: *Extensions, gpa: std.mem.Allocator, io: std.Io, app: *App, opts: Options) !void {
        self.app = app;
        self.user_entry_fault = false;
        const host = Host.createWith(gpa, io, opts.host);
        errdefer host.destroy();
        self.host = host;
        host.engine.attach(app);

        host.interrupt_budget = std.math.maxInt(u32);
        try host.evalModule(opts.boot, "boot.js");
        host.interrupt_budget = host_mod.default_interrupt_budget;
        evalUserEntry(host, opts.config_dir) catch {
            self.user_entry_fault = true;
        };
        // Load built-ins last so a user tool with the same name wins.
        try host.evalModule("import \"yuke:builtins\";", "builtins.js");

        app.engine.installTools(port.toolSet(host));
        app.engine.installHooks(port.hookSet(host));
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
    const path = std.fs.path.joinZ(host.gpa, &.{ dir, user_entry }) catch unreachable;
    defer host.gpa.free(path);
    _ = try host.evalFile(path);
}

// ---------------------------------------------------------------- tests

const ai = @import("ai");
const database = @import("../store/store.zig");
const tools_table = @import("tools.zig");

/// The boot a headless test host runs: the kernel and the plugin bus, and nothing of the view tier.
const kernel_boot = "import \"yuke:kernel\";\nimport \"yuke:ext\";";

/// One headless host over a canned engine, with the user entry the test writes. It must not move after `init`.
const Fixture = struct {
    gpa: std.heap.DebugAllocator(.{}),
    tmp: std.testing.TmpDir,
    root_buf: [std.fs.max_path_bytes]u8,
    reactor: *zio.Runtime,
    env: std.process.Environ.Map,
    canned: ai.transport.CannedTransport,
    app: App,
    extensions: Extensions,

    fn init(self: *Fixture, entry: []const u8, boot: [:0]const u8) !void {
        self.gpa = .init;
        self.tmp = std.testing.tmpDir(.{});
        try self.tmp.dir.writeFile(std.testing.io, .{ .sub_path = user_entry, .data = entry });
        const root = self.root_buf[0..try self.tmp.dir.realPath(std.testing.io, &self.root_buf)];
        self.reactor = try zio.Runtime.init(self.gpa.allocator(), .{ .executors = .exact(1) });
        self.env = .init(self.gpa.allocator());
        self.canned = .{ .bytes = ai.transport.canned_reply };
        try self.app.initTest(self.gpa.allocator(), self.reactor.io(), try database.Database.openTest(), &self.env, self.canned.transport());
        try self.extensions.init(self.gpa.allocator(), self.reactor.io(), &self.app, .{
            .host = .{ .headless = true, .cwd = root, .env = &self.env },
            .boot = boot,
            .config_dir = root,
        });
        try std.testing.expect(!self.extensions.user_entry_fault);
    }

    fn deinit(self: *Fixture) void {
        self.extensions.deinit();
        self.app.engine.close();
        self.app.db.deinit();
        self.app.store.deinit();
        self.app.logins.deinit();
        self.env.deinit();
        self.reactor.deinit();
        self.tmp.cleanup();
        std.debug.assert(self.gpa.deinit() == .ok);
    }
};

/// Drive the owner until one call settles, the way `serve` does between frames.
fn pumpUntilSettled(host: *Host, call: *tools_table.Call) !void {
    try host.pump();
    var rounds: u32 = 0;
    while (call.state != .settled) : (rounds += 1) {
        if (rounds == 64) return error.CallNeverSettled;
        host.wake.timedWait(.fromMilliseconds(1000)) catch {};
        host.wake.reset();
        try host.pump();
    }
}

test "headless extensions pump an async JavaScript tool" {
    var f: Fixture = undefined;
    try f.init(
        \\import { defineConfig, tools } from "yuke";
        \\defineConfig({ systemPrompt: "configured by JavaScript" });
        \\import { fs } from "yuke:fs";
        \\tools.define({
        \\  name: "read_note",
        \\  description: "Read the note.",
        \\  parameters: { type: "object", properties: { path: { type: "string" } } },
        \\  execute: async ({ path }) => ({ text: await fs.readFile(path) }),
        \\});
    , kernel_boot);
    defer f.deinit();
    try f.tmp.dir.writeFile(std.testing.io, .{ .sub_path = "note.txt", .data = "from rpc" });
    const extensions = &f.extensions;
    const app_runtime = &f.app;
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

    const call = extensions.host.calls.submit("read_note", "{\"path\":\"note.txt\"}", "");
    try pumpUntilSettled(extensions.host, call);
    try std.testing.expect(!call.is_error);
    try std.testing.expectEqualStrings("{\"text\":\"from rpc\"}", call.text.?);
    call.finish();
    try extensions.host.pump();
}

test "a plugin notice reaches every attached frontend" {
    const proto = @import("proto");
    var f: Fixture = undefined;
    try f.init("", @import("../app/rpc.zig").boot);
    defer f.deinit();
    const extensions = &f.extensions;
    const app_runtime = &f.app;

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

test "a hook chain replaces a payload and the first block ends it" {
    var f: Fixture = undefined;
    try f.init(
        \\import { plugins } from "yuke";
        \\plugins.use({ name: "gate", apply: (ctx) => {
        \\  ctx.hook("tool.before", (ev) => ({ replace: { name: ev.name, arguments: "rewritten" } }));
        \\  ctx.hook("tool.before", (ev) => (ev.arguments === "rewritten" ? { block: "denied" } : undefined));
        \\  ctx.hook("tool.after", async (ev) => ({ replace: { output: ev.output + "!", is_error: false } }));
        \\  ctx.hook("request.build", (ev) => ({ replace: { ...ev, system: "from the chain" } }));
        \\  ctx.hook("input.before", (ev) => (ev.content[0].text === "no" ? { block: "refused" } : undefined));
        \\  ctx.on("run.started", (ev) => { globalThis.sawRun = ev.session; });
        \\}});
    , kernel_boot);
    defer f.deinit();
    const extensions = &f.extensions;
    const app_runtime = &f.app;

    // A point no handler holds must never reach the owner, so a turn pays nothing for it.
    try std.testing.expect(extensions.host.hooks.holds(.@"tool.before"));
    try std.testing.expect(extensions.host.hooks.holds(.@"tool.after"));
    try std.testing.expect(extensions.host.hooks.holds(.@"request.build"));
    try std.testing.expect(extensions.host.hooks.holds(.@"input.before"));
    // A point no handler holds must cost nothing, so the set answers false for it.
    try std.testing.expect(!extensions.host.hooks.holds(.@"request.send"));

    // A published run must reach a headless handler through the digest, because the bus carried no engine fact before.
    const proto = @import("proto");
    const session_id: proto.ids.SessionId = .bytes(@splat(0xab));
    app_runtime.engine.sinks.emit(.{ .method = .@"run.started", .params = .{ .run_started_data = .{
        .session_id = session_id,
        .seq = 1,
        .run_id = 1,
        .kind = .turn,
        .config_rev = 0,
        .started_at_ms = 1,
    } } });
    try extensions.host.pump();
    try std.testing.expectEqual(@as(i32, 1), try extensions.host.evalInt(
        \\globalThis.sawRun === "abababababababababababababababab" ? 1 : 0
    ));

    // The first handler rewrites the arguments, so the second one sees them and ends the chain.
    const blocked = try settleHook(extensions, "tool.before", "{\"name\":\"bash\",\"arguments\":\"original\"}");
    defer std.testing.allocator.free(blocked);
    try std.testing.expectEqualStrings("{\"type\":\"block\",\"reason\":\"denied\"}", blocked);

    // An async handler settles through the same poll a tool call uses.
    const replaced = try settleHook(extensions, "tool.after", "{\"output\":\"ok\",\"is_error\":false}");
    defer std.testing.allocator.free(replaced);
    try std.testing.expectEqualStrings("{\"type\":\"replace\",\"value\":{\"output\":\"ok!\",\"is_error\":false}}", replaced);

    // A handler reads the whole neutral request, so an untouched field survives the round trip.
    const built = try settleHook(extensions, "request.build", "{\"model\":\"m\",\"system\":\"original\",\"tools\":[],\"max_output_tokens\":64}");
    defer std.testing.allocator.free(built);
    try std.testing.expectEqualStrings(
        "{\"type\":\"replace\",\"value\":{\"model\":\"m\",\"system\":\"from the chain\",\"tools\":[],\"max_output_tokens\":64}}",
        built,
    );

    // A handler that answers nothing leaves the input as the user wrote it.
    const allowed = try settleHook(extensions, "input.before", "{\"session_id\":\"s\",\"content\":[{\"type\":\"text\",\"text\":\"yes\"}]}");
    defer std.testing.allocator.free(allowed);
    try std.testing.expectEqualStrings("", allowed);

    const refused = try settleHook(extensions, "input.before", "{\"session_id\":\"s\",\"content\":[{\"type\":\"text\",\"text\":\"no\"}]}");
    defer std.testing.allocator.free(refused);
    try std.testing.expectEqualStrings("{\"type\":\"block\",\"reason\":\"refused\"}", refused);
}

/// Submit one hook call, pump the owner until it settles, and copy the answer, because the owner frees the record's text on its next sweep.
fn settleHook(extensions: *Extensions, point: []const u8, payload: []const u8) ![]u8 {
    const call = extensions.host.calls.submitHook(point, payload);
    try pumpUntilSettled(extensions.host, call);
    try std.testing.expect(!call.is_error);
    const text = try std.testing.allocator.dupe(u8, call.text.?);
    call.finish();
    return text;
}

test "a user entry file evaluates and a missing one is not an error" {
    var gpa = std.heap.DebugAllocator(.{}).init;
    defer std.debug.assert(gpa.deinit() == .ok);

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(std.testing.io, .{
        .sub_path = user_entry,
        .data = "globalThis.result = 5;\n",
    });
    var dir_buf: [std.fs.max_path_bytes]u8 = undefined;
    const dir_len = try tmp.dir.realPath(std.testing.io, &dir_buf);
    const dir = dir_buf[0..dir_len];

    const host = Host.create(gpa.allocator());
    defer host.destroy();
    try evalUserEntry(host, dir);
    try std.testing.expectEqual(@as(i32, 5), try host.evalInt("globalThis.result"));

    try evalUserEntry(host, null);
    var empty = std.testing.tmpDir(.{});
    defer empty.cleanup();
    var empty_buf: [std.fs.max_path_bytes]u8 = undefined;
    const empty_len = try empty.dir.realPath(std.testing.io, &empty_buf);
    try evalUserEntry(host, empty_buf[0..empty_len]);
}

test "a throwing user entry is a JavaScriptFault the loop absorbs" {
    var gpa = std.heap.DebugAllocator(.{}).init;
    defer std.debug.assert(gpa.deinit() == .ok);

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(std.testing.io, .{
        .sub_path = user_entry,
        .data = "throw new Error('bad config');\n",
    });
    var dir_buf: [std.fs.max_path_bytes]u8 = undefined;
    const dir_len = try tmp.dir.realPath(std.testing.io, &dir_buf);

    const host = Host.create(gpa.allocator());
    defer host.destroy();
    try std.testing.expectError(
        error.JavaScriptFault,
        evalUserEntry(host, dir_buf[0..dir_len]),
    );
    try std.testing.expect(std.mem.indexOf(u8, host.faultText(), "bad config") != null);
}
