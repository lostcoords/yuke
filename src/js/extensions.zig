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

        try host.evalModule("import { plugins } from \"yuke:ext\"; import { agentToolsPlugin } from \"yuke:agent-tools\"; plugins.use(agentToolsPlugin);", "agent-tools.js");

        app.engine.installTools(port.toolSet(host));
        app.engine.installHooks(port.hookSet(host));
    }

    pub fn deinit(self: *Extensions) void {
        // A command must leave before the last turn stops, or it could start another run.
        self.host.tasks.cancel(self.host.io);
        self.app.engine.stopTurns();
        self.app.engine.clearExtensions();
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
pub const Fixture = struct {
    gpa: std.heap.DebugAllocator(.{}),
    tmp: std.testing.TmpDir,
    root_buf: [std.fs.max_path_bytes]u8,
    reactor: *zio.Runtime,
    env: std.process.Environ.Map,
    canned: ai.transport.CannedTransport,
    app: App,
    extensions: Extensions,

    pub fn init(self: *Fixture, entry: []const u8, boot: [:0]const u8) !void {
        self.gpa = .init;
        self.tmp = std.testing.tmpDir(.{});
        try self.tmp.dir.writeFile(std.testing.io, .{ .sub_path = user_entry, .data = entry });
        const root = self.root_buf[0..try self.tmp.dir.realPath(std.testing.io, &self.root_buf)];
        self.reactor = try zio.Runtime.init(self.gpa.allocator(), .{ .executors = .exact(1) });
        self.env = .init(self.gpa.allocator());
        self.canned = .{ .bytes = ai.transport.canned_reply };
        try self.app.initTest(self.gpa.allocator(), self.reactor.io(), try database.Database.openTest(), &self.env, self.canned.transport());
        try self.extensions.init(self.gpa.allocator(), self.reactor.io(), &self.app, .{
            .host = .{ .cwd = root, .env = &self.env },
            .boot = boot,
            .config_dir = root,
        });
        try std.testing.expect(!self.extensions.user_entry_fault);
    }

    pub fn deinit(self: *Fixture) void {
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
        host.wake.waitTimeout(host.io, .{ .duration = .{ .raw = .fromMilliseconds(1000), .clock = .awake } }) catch {};
        host.wake.reset();
        try host.pump();
    }
}

test "headless extensions pump an async JavaScript tool" {
    var f: Fixture = undefined;
    try f.init(
        \\import { defineConfig, tools } from "yuke";
        \\defineConfig({ systemPrompt: "configured by JavaScript", childInstructions: "child policy" });
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
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const advertised = try installed.getDecls(installed.ctx, arena.allocator(), .{ .can_spawn = true, .has_skills = true });
    try std.testing.expectEqual(extensions.host.tools.entries.items.len, advertised.len);
    const found = for (advertised) |d| {
        if (std.mem.eql(u8, d.name, "read_note")) break true;
    } else false;
    try std.testing.expect(found);
    try std.testing.expectEqualStrings("configured by JavaScript", app_runtime.engine.default_system_prompt.?);
    try std.testing.expectEqualStrings("child policy", app_runtime.engine.child_instructions.?);
    try extensions.host.evalModule(
        \\import { defineConfig } from "yuke";
        \\defineConfig({ systemPrompt: null, childInstructions: null });
    , "clear-config.js");
    try std.testing.expect(app_runtime.engine.default_system_prompt == null);
    try std.testing.expect(app_runtime.engine.child_instructions == null);
    try extensions.host.evalModule(
        \\import { defineConfig } from "yuke";
        \\let rejected = false;
        \\try { defineConfig({ systemPrompt: "must not apply", childInstructions: "é".repeat(524289) }); } catch { rejected = true; }
        \\globalThis.configRejected = rejected;
    , "bad-config.js");
    try std.testing.expectEqual(@as(i32, 1), try extensions.host.evalInt("globalThis.configRejected"));
    try std.testing.expect(app_runtime.engine.default_system_prompt == null);
    try std.testing.expect(app_runtime.engine.child_instructions == null);

    try extensions.host.evalModule(
        \\import { defineConfig } from "yuke";
        \\defineConfig({ systemPrompt: "😀", childInstructions: "policy" });
        \\for (const key of ["systemPrompt", "childInstructions"]) {
        \\  for (const value of ["\ud800", "\udfff"]) {
        \\    let rejected = false;
        \\    try { defineConfig({ systemPrompt: "must not apply", [key]: value }); } catch (e) { rejected = e instanceof TypeError; }
        \\    if (!rejected) throw new Error("invalid Unicode accepted");
        \\  }
        \\}
    , "unicode-config.js");
    try std.testing.expectEqualStrings("😀", app_runtime.engine.default_system_prompt.?);
    try std.testing.expectEqualStrings("policy", app_runtime.engine.child_instructions.?);
    try extensions.host.evalModule(
        \\import { defineConfig } from "yuke";
        \\defineConfig({ childInstructions: "" });
    , "partial-config.js");
    try std.testing.expectEqualStrings("😀", app_runtime.engine.default_system_prompt.?);
    try std.testing.expectEqualStrings("", app_runtime.engine.child_instructions.?);

    const call = extensions.host.calls.submit("read_note", "{\"path\":\"note.txt\"}", "");
    try pumpUntilSettled(extensions.host, call);
    try std.testing.expect(!call.is_error);
    try std.testing.expectEqualStrings("{\"text\":\"from rpc\"}", call.text.?);
    call.finish();
    try extensions.host.pump();
}

test "tool declarations and dispatch enforce per-session spawn visibility" {
    var f: Fixture = undefined;
    try f.init(
        \\import { defineTool } from "yuke:tools";
        \\const parameters = { type: "object", properties: {} };
        \\defineTool("normal_tool", { description: "normal", parameters, execute: async () => "normal" });
        \\defineTool("spawn_alias", { description: "spawn", parameters, spawnsAgents: true, execute: async () => "spawn" });
        \\defineTool("skill_alias", { description: "skill", parameters, needsSkills: true, execute: async () => "skill" });
        \\let malformedRejected = false;
        \\try { defineTool("bad_metadata", { description: "bad", parameters, spawnsAgents: 1, execute: async () => "bad" }); } catch { malformedRejected = true; }
        \\globalThis.malformedRejected = malformedRejected ? 1 : 0;
    , kernel_boot);
    defer f.deinit();

    const host = f.extensions.host;
    const installed = f.app.engine.deps.tools;
    const spawn_index = host.tools.find("spawn_agent") orelse unreachable;
    try std.testing.expect(host.tools.entries.items[spawn_index].flags.spawns_agents);
    try std.testing.expectEqual(@as(i32, 1), try host.evalInt("globalThis.malformedRejected"));
    try std.testing.expect(host.tools.find("bad_metadata") == null);

    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const hidden = try installed.getDecls(installed.ctx, arena.allocator(), .{ .can_spawn = false });
    const visible = try installed.getDecls(installed.ctx, arena.allocator(), .{ .can_spawn = true });
    try std.testing.expect(findDecl(hidden, "normal_tool"));
    try std.testing.expect(!findDecl(hidden, "spawn_agent"));
    try std.testing.expect(!findDecl(hidden, "spawn_alias"));
    try std.testing.expect(findDecl(visible, "spawn_agent"));
    try std.testing.expect(findDecl(visible, "spawn_alias"));
    // The skill tool and any tool that needs a catalog stay out of a session that lists no skill.
    try std.testing.expect(!findDecl(visible, "skill"));
    try std.testing.expect(!findDecl(visible, "skill_alias"));
    const with_skills = try installed.getDecls(installed.ctx, arena.allocator(), .{ .can_spawn = false, .has_skills = true });
    try std.testing.expect(findDecl(with_skills, "skill"));
    try std.testing.expect(findDecl(with_skills, "skill_alias"));
    try std.testing.expect(!findDecl(with_skills, "spawn_alias"));
    try std.testing.expect(!installed.isAllowed(installed.ctx, "skill", .{ .can_spawn = true }));
    try std.testing.expect(installed.isAllowed(installed.ctx, "skill", .{ .has_skills = true }));
    try std.testing.expect(!installed.isAllowed(installed.ctx, "spawn_alias", .{ .can_spawn = false }));
    try std.testing.expect(installed.isAllowed(installed.ctx, "normal_tool", .{ .can_spawn = false }));
    try std.testing.expect(installed.isAllowed(installed.ctx, "spawn_alias", .{ .can_spawn = true }));

    const before = host.tools.find("spawn_alias") orelse unreachable;
    try std.testing.expect(host.tools.entries.items[before].flags.spawns_agents);
    try host.evalModule(
        \\import { removeTool } from "yuke:tools";
        \\globalThis.removedSpawnAlias = removeTool("spawn_alias") ? 1 : 0;
    , "remove-spawn-alias.js");
    try std.testing.expectEqual(@as(i32, 1), try host.evalInt("globalThis.removedSpawnAlias"));
    try std.testing.expect(host.tools.find("spawn_alias") == null);
    const normal_index = host.tools.find("normal_tool") orelse unreachable;
    try std.testing.expect(!host.tools.entries.items[normal_index].flags.spawns_agents);
}

test "tool rejection codes cross the native bridge as cancellation reasons" {
    const proto = @import("proto");
    var f: Fixture = undefined;
    try f.init(
        \\import { defineTool } from "yuke:tools";
        \\const parameters = { type: "object", properties: {} };
        \\defineTool("declined", { description: "declined", parameters, execute: async () => { throw Object.assign(new Error("declined"), { code: "setup_declined" }); } });
        \\defineTool("dismissed", { description: "dismissed", parameters, execute: async () => { throw Object.assign(new Error("dismissed"), { code: "setup_canceled" }); } });
        \\defineTool("ordinary", { description: "ordinary", parameters, execute: async () => { throw new Error("ordinary"); } });
        \\defineTool("getter", { description: "getter", parameters, execute: async () => { const error = new Error("getter"); Object.defineProperty(error, "code", { get: () => { throw new Error("code getter"); } }); throw error; } });
    , kernel_boot);
    defer f.deinit();
    const host = f.extensions.host;
    const cases = [_]struct { name: []const u8, reason: ?proto.tool.ToolCancellationReason }{
        .{ .name = "declined", .reason = .setup_declined },
        .{ .name = "dismissed", .reason = .setup_dismissed },
        .{ .name = "ordinary", .reason = null },
        .{ .name = "getter", .reason = null },
    };
    for (cases) |case| {
        const call = host.calls.submit(case.name, "{}", "");
        defer call.finish();
        try pumpUntilSettled(host, call);
        try std.testing.expectEqual(case.reason, call.cancellation_reason);
        try std.testing.expect(call.is_error);
        try std.testing.expectEqualStrings(case.name, call.text.?);
        try std.testing.expect(!host.ctx.hasException());
    }
    try host.pump();
}

fn findDecl(decls: []const @import("ai").ir.Tool, name: []const u8) bool {
    for (decls) |decl| if (std.mem.eql(u8, decl.name, name)) return true;
    return false;
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

fn pumpUntil(host: *Host, expression: [:0]const u8) !void {
    for (0..64) |_| {
        try host.pump();
        if (try host.evalInt(expression) != 0) return;
        host.wake.reset();
        if (!host.hasPending()) host.wake.waitTimeout(host.io, .{ .duration = .{ .raw = .fromMilliseconds(100), .clock = .awake } }) catch {};
    }
    return error.RequestNeverSettled;
}

const deferred_input =
    \\import { plugins } from "yuke";
    \\import { native } from "yuke:engine-native";
    \\import { sendInput } from "yuke:ext";
    \\globalThis.request = (method, params = {}) => native.request(method, JSON.stringify(params)).then(JSON.parse);
    \\globalThis.sendInput = sendInput;
    \\plugins.use({ name: "gate", apply(ctx) {
    \\  ctx.hook("input.before", (ev) => new Promise((resolve) => {
    \\    globalThis.payload = ev;
    \\    globalThis.release = resolve;
    \\    globalThis.waiting = 1;
    \\  }));
    \\} });
;

fn startDeferredInput(host: *Host) !void {
    try host.evalModule(
        \\globalThis.finished = 0;
        \\globalThis.waiting = 0;
        \\request("session.create", { workspace_path: "/tmp/yuke-hooks" }).then((result) => {
        \\  globalThis.sid = result.session.id;
        \\  return sendInput({ session_id: sid, input: { type: "content", content: [{ type: "text", text: "original" }] } });
        \\}).then(() => { globalThis.finished = 1; }, (e) => { globalThis.failure = e.code; globalThis.finished = 2; });
    , "input-start.js");
    try pumpUntil(host, "globalThis.waiting === 1");
}

test "an input hook leaves the owner free and its replacement reaches the store" {
    var f: Fixture = undefined;
    try f.init(deferred_input, kernel_boot);
    defer f.deinit();
    const host = f.extensions.host;
    try startDeferredInput(host);

    try host.evalModule(
        \\request("initialize").then(() => { globalThis.responsive = 1; });
    , "input-concurrent.js");
    try pumpUntil(host, "globalThis.responsive === 1");
    try std.testing.expectEqual(@as(i32, 0), try host.evalInt("globalThis.finished"));
    try host.evalModule(
        \\release({ replace: { ...payload, content: [{ type: "text", text: "replaced" }] } });
    , "input-release.js");
    try pumpUntil(host, "globalThis.finished !== 0");
    try std.testing.expectEqual(@as(i32, 1), try host.evalInt("globalThis.finished"));
    try host.evalModule(
        \\request("session.history", { session_id: sid, before_message_id: Number.MAX_SAFE_INTEGER }).then((history) => {
        \\  globalThis.stored = history.messages.some((m) => m.type === "user" && m.content[0].text === "replaced") ? 1 : 2;
        \\}).catch(() => { globalThis.stored = 3; });
    , "input-history.js");
    try pumpUntil(host, "globalThis.stored > 0");
    try std.testing.expectEqual(@as(i32, 1), try host.evalInt("globalThis.stored"));
}

test "an input hook cannot revive a session removed while it waits" {
    var f: Fixture = undefined;
    try f.init(deferred_input, kernel_boot);
    defer f.deinit();
    const host = f.extensions.host;
    try startDeferredInput(host);
    try host.evalModule(
        \\request("session.remove", { session_id: sid }).then(() => { globalThis.removed = 1; });
    , "input-remove.js");
    try pumpUntil(host, "globalThis.removed === 1");
    try host.eval("release();", "input-release.js");
    try pumpUntil(host, "globalThis.finished !== 0");
    try std.testing.expectEqual(@as(i32, 1), try host.evalInt("globalThis.finished === 2 && globalThis.failure === 'unknown_session'"));
}

test "a blocked input answers its code and reaches no store" {
    var f: Fixture = undefined;
    try f.init(deferred_input, kernel_boot);
    defer f.deinit();
    const host = f.extensions.host;
    try startDeferredInput(host);
    try host.eval("release({ block: 'denied' });", "input-block.js");
    try pumpUntil(host, "globalThis.finished !== 0");
    try std.testing.expectEqual(@as(i32, 1), try host.evalInt("globalThis.finished === 2 && globalThis.failure === 'bad_request'"));
    try host.evalModule(
        \\request("session.history", { session_id: sid, before_message_id: Number.MAX_SAFE_INTEGER }).then((history) => { globalThis.empty = history.messages.length === 0 ? 1 : 2; }).catch(() => { globalThis.empty = 3; });
    , "input-after-block.js");
    try pumpUntil(host, "globalThis.empty > 0");
    try std.testing.expectEqual(@as(i32, 1), try host.evalInt("globalThis.empty"));
}

test "create with input shares the hook gate and a refusal leaves no session" {
    var f: Fixture = undefined;
    try f.init(
        \\import { plugins } from "yuke:ext";
        \\globalThis.mode = "block";
        \\plugins.use({ name: "initial", apply(ctx) {
        \\  ctx.hook("input.before", async (value) => {
        \\    globalThis.proposed = value.session_id === null && value.create.workspace_path === "/work";
        \\    if (globalThis.mode === "block") return { block: "denied" };
        \\    if (globalThis.mode === "bad") return { replace: {} };
        \\    return { replace: { content: [{ type: "text", text: "replaced" }] } };
        \\  });
        \\} });
    , kernel_boot);
    defer f.deinit();
    const host = f.extensions.host;
    var scratch: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer scratch.deinit();
    const a = scratch.allocator();
    const proto = @import("proto");
    const params =
        \\{"workspace_path":"/work","model":"test/model","initial_input":{"type":"content","content":[{"type":"text","text":"original"}]}}
    ;
    for ([_][]const u8{ "globalThis.mode='block'", "globalThis.mode='bad'" }) |script| {
        const text = try a.dupeZ(u8, script);
        try host.eval(text, "mode.js");
        const call = host.calls.submitInputMethod("session.create", params);
        defer call.finish();
        try pumpUntilSettled(host, call);
        try std.testing.expect(std.mem.indexOf(u8, call.text.?, "failure") != null);
        try std.testing.expectEqual(@as(u64, 0), try database.session.count(&f.app.db, a, .{}));
    }
    try std.testing.expectEqual(@as(i32, 1), try host.evalInt("globalThis.proposed"));
    try host.eval("globalThis.mode='replace'", "mode.js");
    const call = host.calls.submitInputMethod("session.create", params);
    defer call.finish();
    try pumpUntilSettled(host, call);
    const answer = try std.json.parseFromSliceLeaky(struct { result: proto.session.SessionResult }, a, call.text.?, .{});
    const id = answer.result.session.id;
    const page = try database.message.historyPage(&f.app.db, a, id.raw, 0, 10);
    try std.testing.expectEqualStrings("replaced", page.messages[0].user.content[0].text.text);
    try std.testing.expectEqual(@as(u64, 1), (try database.event.highWater(&f.app.db, a, id.raw)).?.input_id_high);
}

test "agent config validates before it changes the native limits" {
    var f: Fixture = undefined;
    try f.init("", kernel_boot);
    defer f.deinit();
    const host = f.extensions.host;
    try host.evalModule(
        \\import { config, defineConfig } from "yuke:kernel";
        \\globalThis.defaultDepth = config.agents.maxDepth;
        \\defineConfig({ agents: { maxConcurrent: 2, maxDepth: 3 } });
        \\globalThis.changed = config.agents.maxConcurrent === 2 && config.agents.maxDepth === 3 ? 1 : 0;
        \\defineConfig({ agents: { maxDepth: 4 } });
        \\globalThis.preserved = config.agents.maxConcurrent === 2 && config.agents.maxDepth === 4 ? 1 : 0;
        \\globalThis.refusedLimits = 0;
        \\for (const maxConcurrent of [0, -1, 1.5, null, "2", 4294967296, NaN]) {
        \\  try { defineConfig({ agents: { maxConcurrent } }); } catch { globalThis.refusedLimits++; }
        \\}
        \\for (const maxDepth of [0, -1, 1.5, null, "2", 4294967296, NaN]) {
        \\  try { defineConfig({ agents: { maxDepth } }); } catch { globalThis.refusedLimits++; }
        \\}
        \\try { defineConfig({ agents: { unknown: 1 } }); } catch { globalThis.refusedLimits++; }
        \\globalThis.unchanged = config.agents.maxConcurrent === 2 && config.agents.maxDepth === 4 ? 1 : 0;
    , "limits.js");
    try std.testing.expectEqual(@as(i32, 15), try host.evalInt("globalThis.refusedLimits"));
    try std.testing.expectEqual(@as(i32, 1), try host.evalInt("globalThis.defaultDepth"));
    try std.testing.expectEqual(@as(i32, 1), try host.evalInt("globalThis.changed"));
    try std.testing.expectEqual(@as(i32, 1), try host.evalInt("globalThis.preserved"));
    try std.testing.expectEqual(@as(i32, 1), try host.evalInt("globalThis.unchanged"));
    try std.testing.expectEqual(@as(u32, 2), f.app.engine.max_concurrent_children);
    try std.testing.expectEqual(@as(u32, 4), f.app.engine.max_agent_depth);
}

test "a JavaScript build hook reconstructs exact prompt components" {
    var f: Fixture = undefined;
    try f.init(
        \\import { plugins } from "yuke:ext";
        \\plugins.use({ name: "prompt-parts", apply(ctx) {
        \\  ctx.hook("request.build", (request) => {
        \\    const { base, instructions, skills, child_policy, environment } = request.context.prompt;
        \\    const join = (parts) => parts.filter((text) => text != null && text.length > 0).join("\n\n");
        \\    if (join([base, instructions, skills, child_policy, environment]) !== request.system) return { block: "prompt mismatch" };
        \\    return { replace: { ...request, system: join(["custom base", instructions, skills, child_policy, environment]) } };
        \\  });
        \\} });
    , kernel_boot);
    defer f.deinit();
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const environment = "<environment>\nworkspace: /work\n</environment>";
    const Parts = @import("../session/prompt.zig").Parts;
    const cases = [_]struct { parts: Parts, system: []const u8, expected: []const u8 }{
        .{ .parts = .{ .base = "base\n\nwith separators", .instructions = "project rules", .child_policy = "child policy", .environment = environment }, .system = "base\n\nwith separators\n\nproject rules\n\nchild policy\n\n" ++ environment, .expected = "custom base\n\nproject rules\n\nchild policy\n\n" ++ environment },
        .{ .parts = .{ .base = "", .child_policy = null, .environment = environment }, .system = environment, .expected = "custom base\n\n" ++ environment },
        .{ .parts = .{ .base = "base", .instructions = "rules", .skills = "<available_skills/>", .child_policy = null, .environment = environment }, .system = "base\n\nrules\n\n<available_skills/>\n\n" ++ environment, .expected = "custom base\n\nrules\n\n<available_skills/>\n\n" ++ environment },
    };
    for (cases) |case| {
        const payload = try std.json.Stringify.valueAlloc(a, .{
            .model = "m",
            .system = case.system,
            .tools = .{},
            .max_output_tokens = 64,
            .context = .{ .prompt = case.parts },
        }, .{});
        const result = try settleHook(&f.extensions, "request.build", payload);
        defer std.testing.allocator.free(result);
        const parsed = try std.json.parseFromSliceLeaky(std.json.Value, a, result, .{});
        try std.testing.expectEqualStrings("replace", parsed.object.get("type").?.string);
        try std.testing.expectEqualStrings(case.expected, parsed.object.get("value").?.object.get("system").?.string);
    }
}

test "the skill tool answers a catalog body through skill.load" {
    const commands = @import("../engine/commands.zig");
    var f: Fixture = undefined;
    try f.init("", kernel_boot);
    defer f.deinit();
    try f.tmp.dir.createDirPath(std.testing.io, ".agents/skills/pdf");
    try f.tmp.dir.writeFile(std.testing.io, .{ .sub_path = ".agents/skills/pdf/SKILL.md", .data = "---\ndescription: Handle PDFs\n---\nRead the pdf.\n" });
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const host = f.extensions.host;
    const created = try commands.sessionCreate(&f.app.engine, a, .{ .workspace_path = host.cwd });
    try std.testing.expect(try database.session.hasSkills(&f.app.db, a, created.session.id.raw));

    const call = host.calls.submit("skill", "{\"name\":\"pdf\"}", host.cwd);
    call.site = .{ .session_id = created.session.id, .message_id = 1, .part_id = 0 };
    try pumpUntilSettled(host, call);
    try std.testing.expect(!call.is_error);
    try std.testing.expect(std.mem.startsWith(u8, call.text.?, "<skill_content name=\"pdf\">\nRead the pdf.\n\nSkill directory: "));
    try std.testing.expect(std.mem.endsWith(u8, call.text.?, ".agents/skills/pdf\nResolve relative paths against this directory.\n</skill_content>"));
    call.finish();
    try host.pump();

    // The catalog decides what a name means, so an unknown name is an error the model can read.
    const missing = host.calls.submit("skill", "{\"name\":\"nope\"}", host.cwd);
    missing.site = .{ .session_id = created.session.id, .message_id = 1, .part_id = 0 };
    try pumpUntilSettled(host, missing);
    try std.testing.expect(missing.is_error);
    try std.testing.expect(std.mem.indexOf(u8, missing.text.?, "has no skill with this name") != null);
    missing.finish();
    try host.pump();
}

test "session create returns the invalid instruction path through the call API" {
    const proto = @import("proto");
    var f: Fixture = undefined;
    try f.init("", kernel_boot);
    defer f.deinit();
    try f.tmp.dir.writeFile(std.testing.io, .{ .sub_path = "AGENTS.md", .data = "\xff" });
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const params = try std.json.Stringify.valueAlloc(a, .{ .workspace_path = f.extensions.host.cwd }, .{});
    var output: std.Io.Writer.Allocating = .init(a);
    const failure = (try @import("../app/call.zig").call(&f.app, a, "session.create", params, &output.writer)).?;
    try std.testing.expectEqual(proto.enums.ErrorCode.bad_request, failure.code);
    try std.testing.expect(std.mem.indexOf(u8, failure.message, f.extensions.host.cwd) != null);
    try std.testing.expect(std.mem.indexOf(u8, failure.message, "AGENTS.md") != null);
    try std.testing.expectEqual(@as(usize, 0), output.written().len);
}
