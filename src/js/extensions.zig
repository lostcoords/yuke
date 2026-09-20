//! Compose the one QuickJS host used by the TUI and JSONL RPC frontends.

const std = @import("std");
const execution = @import("../execution.zig");
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
        // The prompt plugin loads before the user entry, so a user handler runs after it in every prompt.build chain.
        try host.evalModule("import \"yuke:prompt\";", "prompt.js");
        evalUserEntry(host, opts.config_dir) catch {
            self.user_entry_fault = true;
        };
        // Load built-ins last so a user tool with the same name wins.
        try host.evalModule("import \"yuke:builtins\";", "builtins.js");

        app.engine.installTools(port.toolSet(host));
        app.engine.installHooks(port.hookSet(host));
    }

    pub fn deinit(self: *Extensions) void {
        self.host.stopPlugins();
        // A child waiter reaps with cancelation blocked, so children end first; a command leaves before the last turn stops.
        self.host.endChildren();
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
    errdefer {
        const fault = host.fault_text;
        const fault_len = host.fault_text_len;
        host.evalStartup("import { plugins } from \"yuke:ext\"; await plugins._cancelStartup();", "plugins-cancel.js") catch {};
        host.fault_text = fault;
        host.fault_text_len = fault_len;
    }
    _ = try host.evalFile(path);
    try host.evalStartup("import { plugins } from \"yuke:ext\"; await plugins.ready();", "plugins-ready.js");
}

// ---------------------------------------------------------------- tests

const ai = @import("ai");
const database = @import("../store/store.zig");
const tools_table = @import("tools.zig");
const app_fixture = @import("../app/fixture.zig");
const support = @import("tests/support.zig");

/// The boot a headless test host runs: the kernel and the plugin bus, and nothing of the view tier.
const kernel_boot = "import \"yuke:kernel\";\nimport \"yuke:ext\";";

/// One headless host over a canned engine, with the user entry the test writes. It must not move after `init`.
pub const Fixture = struct {
    gpa: support.Pool,
    tmp: std.testing.TmpDir,
    root_buf: [std.fs.max_path_bytes]u8,
    reactor: *zio.Runtime,
    env: std.process.Environ.Map,
    canned: ai.testing.CannedTransport,
    app: App,
    extensions: Extensions,

    pub fn init(self: *Fixture, entry: []const u8, boot: [:0]const u8) !void {
        self.gpa = .init;
        self.tmp = std.testing.tmpDir(.{});
        try self.tmp.dir.writeFile(std.testing.io, .{ .sub_path = user_entry, .data = entry });
        const root = self.root_buf[0..try self.tmp.dir.realPath(std.testing.io, &self.root_buf)];
        self.reactor = try zio.Runtime.init(self.gpa.allocator(), .{ .executors = .exact(1) });
        self.env = .init(self.gpa.allocator());
        self.canned = .{ .bytes = ai.testing.canned_reply };
        // One context, so a split between the two owners is a test failure and not a silent drift.
        const context = execution.testContext(&self.env);
        try app_fixture.init(&self.app, self.gpa.allocator(), self.reactor.io(), root, context, self.canned.transport());
        try app_fixture.installModel(&self.app);
        try self.extensions.init(self.gpa.allocator(), self.reactor.io(), &self.app, .{
            .host = .{ .cwd = root, .execution = context },
            .boot = boot,
            .config_dir = root,
        });
        try std.testing.expect(!self.extensions.user_entry_fault);
    }

    pub fn deinit(self: *Fixture) void {
        self.extensions.deinit();
        self.app.deinit();
        self.env.deinit();
        self.reactor.deinit();
        self.tmp.cleanup();
        std.debug.assert(self.gpa.deinit() == .ok);
    }
};

test "one execution context reaches both the engine and the JavaScript host" {
    var f: Fixture = undefined;
    try f.init("", kernel_boot);
    defer f.deinit();

    // A later split between these two owners would make the prompt promise a shell the runner never uses.
    const engine_side = f.app.engine.deps.execution;
    const host_side = f.extensions.host.execution;
    try std.testing.expectEqual(engine_side.env, host_side.env);
    try std.testing.expectEqualStrings(engine_side.shell.path, host_side.shell.path);
}

test "headless extensions pump an async JavaScript tool" {
    var f: Fixture = undefined;
    try f.init(
        \\import { defineConfig, config, plugins, fs } from "yuke";
        \\defineConfig({ systemPrompt: "configured by JavaScript" });
        \\globalThis.configured = config.systemPrompt;
        \\plugins.use({ name: "notes", apply(ctx) { ctx.tools.define({
        \\  name: "read_note",
        \\  description: "Read the note.",
        \\  parameters: { type: "object", properties: { path: { type: "string" } } },
        \\  execute: async ({ path }) => ({ text: await fs.readFile(path) }),
        \\}); } });
    , kernel_boot);
    defer f.deinit();
    try f.tmp.dir.writeFile(std.testing.io, .{ .sub_path = "note.txt", .data = "from rpc" });
    const extensions = &f.extensions;
    const app_runtime = &f.app;
    // The engine asks the host, so the user tool and every built-in reach the provider together.
    const installed = app_runtime.engine.deps.tools;
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const names = try installed.names(installed.ctx, arena.allocator());
    const advertised = try installed.getDecls(installed.ctx, arena.allocator(), names);
    try std.testing.expectEqual(extensions.host.tools.entries.items.len, advertised.len);
    const found = for (advertised) |d| {
        if (std.mem.eql(u8, d.name, "read_note")) break true;
    } else false;
    try std.testing.expect(found);
    const call = extensions.host.calls.submit("read_note", "{\"path\":\"note.txt\"}", "");
    try support.pumpUntilSettled(extensions.host, call);
    try std.testing.expect(!call.is_error);
    try std.testing.expectEqualStrings("{\"text\":\"from rpc\"}", call.text.?);
    call.finish();
    try extensions.host.pump();
}

test "the tool port lists names in table order and answers only the declarations a run allows" {
    var f: Fixture = undefined;
    try f.init(
        \\import { plugins } from "yuke";
        \\const parameters = { type: "object", properties: {} };
        \\plugins.use({ name: "pair", apply(ctx) {
        \\  ctx.tools.define({ name: "normal_tool", description: "normal", parameters, execute: async () => "normal" });
        \\  ctx.tools.define({ name: "hidden_tool", description: "hidden", parameters, execute: async () => "hidden" });
        \\} });
    , kernel_boot);
    defer f.deinit();
    const host = f.extensions.host;
    const installed = f.app.engine.deps.tools;
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const names = try installed.names(installed.ctx, arena.allocator());
    try std.testing.expect(names.len >= 2);
    for (names[1..], 0..) |name, i| try std.testing.expect(std.mem.order(u8, names[i], name) == .lt);
    const some = try installed.getDecls(installed.ctx, arena.allocator(), &.{ "normal_tool", "absent" });
    try std.testing.expectEqual(@as(usize, 1), some.len);
    try std.testing.expectEqualStrings("normal_tool", some[0].name);
    try host.evalModule(
        \\import { removeTool } from "yuke:tools";
        \\globalThis.removed = removeTool("hidden_tool") ? 1 : 0;
    , "remove.js");
    try std.testing.expectEqual(@as(i32, 1), try host.evalInt("globalThis.removed"));
    try std.testing.expect(host.tools.find("hidden_tool") == null);
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
        \\import { plugins } from "yuke";
        \\plugins.use({ name: "reporter", apply(ctx) { ctx.interaction.notify("build failed", "warn"); } });
    , "notify.js");

    try std.testing.expectEqual(@as(usize, 1), capture.seen);
    try std.testing.expectEqual(proto.enums.NoticeLevel.warn, capture.level);
    try std.testing.expectEqualStrings("reporter", capture.source[0..capture.source_len]);
    try std.testing.expectEqualStrings("build failed", capture.message[0..capture.message_len]);
}

test "the prompt plugin writes the default sections, and a user handler appends after it" {
    var f: Fixture = undefined;
    try f.init(
        \\import { plugins, defineConfig } from "yuke";
        \\defineConfig({ systemPrompt: "Base for ${agent_name} in ${workspace}" });
        \\plugins.use({ name: "tail", apply(ctx) {
        \\  ctx.hook("prompt.build", (build) => ({ replace: { ...build, sections: [...build.sections, { key: "tail", text: "the end" }] } }));
        \\} });
    , kernel_boot);
    defer f.deinit();
    const payload =
        \\{"context":{"session_id":"01010101010101010101010101010101","parent_id":null,"depth":0,"agent_name":"root","workspace":"/w","operating_system":"macos","shell":"/bin/sh","session_start_date_utc":"2026-09-19"},
        \\ "instructions":[{"scope":"workspace","path":"/w/AGENTS.md","text":"rules"}],"skills":[{"name":"pdf","description":"Handle PDFs & forms"}],"sections":[]}
    ;
    const answer = try settleHook(&f.extensions, "prompt.build", payload);
    defer std.testing.allocator.free(answer);
    const Answer = struct { type: []const u8, value: struct { sections: []const struct { key: []const u8, text: []const u8 } } };
    const parsed = try std.json.parseFromSlice(Answer, std.testing.allocator, answer, .{ .ignore_unknown_fields = true });
    defer parsed.deinit();
    const sections = parsed.value.value.sections;
    try std.testing.expectEqual(@as(usize, 5), sections.len);
    try std.testing.expectEqualStrings("base", sections[0].key);
    try std.testing.expectEqualStrings("Base for root in /w", sections[0].text);
    try std.testing.expectEqualStrings("instructions", sections[1].key);
    try std.testing.expect(std.mem.startsWith(u8, sections[1].text, "Project instructions follow."));
    try std.testing.expect(std.mem.indexOf(u8, sections[1].text, "## AGENTS.md (/w/AGENTS.md)\nScope: workspace.\n\nrules") != null);
    try std.testing.expectEqualStrings("skills", sections[2].key);
    try std.testing.expect(std.mem.indexOf(u8, sections[2].text, "<description>Handle PDFs &amp; forms</description>") != null);
    try std.testing.expectEqualStrings("environment", sections[3].key);
    try std.testing.expectEqualStrings("<environment>\nworkspace: /w\noperating_system: macos\nshell: /bin/sh\nsession_start_date_utc: 2026-09-19\n</environment>", sections[3].text);
    try std.testing.expectEqualStrings("tail", sections[4].key);
    // A seeded request base wins over the configured one and keeps its key.
    const seeded = try settleHook(&f.extensions, "prompt.build", "{\"context\":{\"session_id\":\"01010101010101010101010101010101\",\"parent_id\":null,\"depth\":0,\"agent_name\":\"root\",\"workspace\":\"/w\",\"operating_system\":\"macos\",\"shell\":\"/bin/sh\",\"session_start_date_utc\":\"2026-09-19\"},\"instructions\":[],\"skills\":[],\"sections\":[{\"key\":\"system_prompt\",\"text\":\"custom\"}]}");
    defer std.testing.allocator.free(seeded);
    const seeded_answer = try std.json.parseFromSlice(Answer, std.testing.allocator, seeded, .{ .ignore_unknown_fields = true });
    defer seeded_answer.deinit();
    try std.testing.expectEqual(@as(usize, 3), seeded_answer.value.value.sections.len);
    try std.testing.expectEqualStrings("system_prompt", seeded_answer.value.value.sections[0].key);
    try std.testing.expectEqualStrings("custom", seeded_answer.value.value.sections[0].text);
    // The compaction instruction comes from the same plugin, one text per mode, and the merge names the engine's wrapper.
    const merge = try settleHook(&f.extensions, "compaction.prompt", "{\"context\":{},\"mode\":\"merge\",\"prompt\":\"\"}");
    defer std.testing.allocator.free(merge);
    try std.testing.expect(std.mem.indexOf(u8, merge, "You are a context summarization assistant") != null);
    try std.testing.expect(std.mem.indexOf(u8, merge, "The <context_summary> block holds the summary") != null);
    const summarize = try settleHook(&f.extensions, "compaction.prompt", "{\"context\":{},\"mode\":\"summarize\",\"prompt\":\"\"}");
    defer std.testing.allocator.free(summarize);
    try std.testing.expect(std.mem.indexOf(u8, summarize, "Write a context checkpoint") != null);
    try std.testing.expect(std.mem.indexOf(u8, summarize, "context_summary") == null);
    // Only a prompt.build handler change marks the stored prompts stale.
    const before = f.app.engine.prompt_generation;
    try f.extensions.host.evalModule(
        \\import { plugins } from "yuke";
        \\plugins.use({ name: "other", apply(ctx) { ctx.hook("request.send", () => null); } });
    , "other-point.js");
    try std.testing.expectEqual(before, f.app.engine.prompt_generation);
    try f.extensions.host.evalModule(
        \\import { plugins } from "yuke";
        \\plugins.use({ name: "second", apply(ctx) { ctx.hook("prompt.build", () => null); } });
    , "prompt-point.js");
    try std.testing.expectEqual(before + 1, f.app.engine.prompt_generation);
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
        \\  ctx.hook("request.send", () => { throw new Error("boom"); });
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
    // A point no handler holds must cost nothing, so the set answers false for it. The skills plugin holds tools.select until it goes.
    try std.testing.expect(extensions.host.hooks.holds(.@"tools.select"));
    try extensions.host.evalModule("import { plugins } from \"yuke\"; plugins.dispose(\"skills\");", "drop-skills.js");
    try std.testing.expect(!extensions.host.hooks.holds(.@"tools.select"));
    // A throwing handler fails closed: the point answers a block, never a pass.
    const failed = try settleHook(extensions, "request.send", "{\"url\":\"u\",\"headers\":[],\"body\":\"{}\"}");
    defer std.testing.allocator.free(failed);
    try std.testing.expect(std.mem.indexOf(u8, failed, "\"type\":\"block\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, failed, "gate plugin failed at request.send") != null);

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

test "a turn task gets its hook answer from the owner without a second wake" {
    var f: Fixture = undefined;
    try f.init(
        \\import { plugins } from "yuke";
        \\plugins.use({ name: "gate", apply: (ctx) => {
        \\  ctx.hook("tool.before", (ev) => ({ block: "denied " + ev.name }));
        \\}});
    , kernel_boot);
    defer f.deinit();
    const host = f.extensions.host;

    // The task asks through the port, as a turn task does.
    const Asker = struct {
        host: *Host,
        arena: std.heap.ArenaAllocator,
        decision: ?@import("../engine/hookset.zig").Decision = null,
        answered: std.Io.Event = .unset,

        fn run(self: *@This()) void {
            const hooks = port.hookSet(self.host);
            self.decision = hooks.ask(hooks.ctx, self.arena.allocator(), .@"tool.before", "{\"name\":\"bash\",\"arguments\":\"{}\"}");
            self.answered.set(self.host.io);
            self.host.wake.set(self.host.io);
        }
    };
    var asker: Asker = .{ .host = host, .arena = .init(std.testing.allocator) };
    defer asker.arena.deinit();
    var task = try host.io.concurrent(Asker.run, .{&asker});
    defer task.cancel(host.io);

    try support.pumpUntilSet(host, &asker.answered);
    try std.testing.expectEqualStrings("denied bash", asker.decision.?.block);
}

test "a hook call settles in the pump that starts it" {
    var f: Fixture = undefined;
    try f.init(
        \\import { plugins } from "yuke";
        \\plugins.use({ name: "gate", apply: (ctx) => {
        \\  ctx.hook("tool.before", () => ({ block: "denied" }));
        \\}});
    , kernel_boot);
    defer f.deinit();
    const host = f.extensions.host;
    const call = host.calls.submitHook("tool.before", "{\"name\":\"bash\",\"arguments\":\"{}\"}");
    try host.pump();
    try std.testing.expect(call.state == .settled);
    try std.testing.expectEqualStrings("{\"type\":\"block\",\"reason\":\"denied\"}", call.text.?);
    call.finish();
    try host.pump();
    try std.testing.expect(!host.hasPending());
}

/// Submit one hook call, pump the owner until it settles, and copy the answer, because the owner frees the record's text on its next sweep.
fn settleHook(extensions: *Extensions, point: []const u8, payload: []const u8) ![]u8 {
    const call = extensions.host.calls.submitHook(point, payload);
    try support.pumpUntilSettled(extensions.host, call);
    try std.testing.expect(!call.is_error);
    const text = try std.testing.allocator.dupe(u8, call.text.?);
    call.finish();
    return text;
}

test "a user entry file evaluates and a missing one is not an error" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(std.testing.io, .{
        .sub_path = user_entry,
        .data = "globalThis.result = 5;\n",
    });
    var dir_buf: [std.fs.max_path_bytes]u8 = undefined;
    const dir_len = try tmp.dir.realPath(std.testing.io, &dir_buf);
    const dir = dir_buf[0..dir_len];

    const host = support.createHost();
    defer support.destroyHost(host);
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
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(std.testing.io, .{
        .sub_path = user_entry,
        .data = "throw new Error('bad config');\n",
    });
    var dir_buf: [std.fs.max_path_bytes]u8 = undefined;
    const dir_len = try tmp.dir.realPath(std.testing.io, &dir_buf);

    const host = support.createHost();
    defer support.destroyHost(host);
    try std.testing.expectError(
        error.JavaScriptFault,
        evalUserEntry(host, dir_buf[0..dir_len]),
    );
    try std.testing.expect(std.mem.indexOf(u8, host.faultText(), "bad config") != null);
}

const deferred_input =
    \\import { plugins } from "yuke";
    \\import { client } from "yuke";
    \\globalThis.request = (method, params = {}) => client.request(method, params);
    \\globalThis.sendInput = (params) => client.sessionSendInput(params.session_id, params.input.content);
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
        \\request("session.create", { workspace_path: "/tmp/yuke-hooks", model: "test/model" }).then((result) => {
        \\  globalThis.sid = result.session.id;
        \\  return sendInput({ session_id: sid, input: { type: "content", content: [{ type: "text", text: "original" }] } });
        \\}).then(() => { globalThis.finished = 1; }, (e) => { globalThis.failure = e.code; globalThis.finished = 2; });
    , "input-start.js");
    try support.pumpUntilTrue(host, "globalThis.waiting === 1");
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
    try support.pumpUntilTrue(host, "globalThis.responsive === 1");
    try std.testing.expectEqual(@as(i32, 0), try host.evalInt("globalThis.finished"));
    try host.evalModule(
        \\release({ replace: { ...payload, content: [{ type: "text", text: "replaced" }] } });
    , "input-release.js");
    try support.pumpUntilTrue(host, "globalThis.finished !== 0");
    try std.testing.expectEqual(@as(i32, 1), try host.evalInt("globalThis.finished"));
    try host.evalModule(
        \\request("session.history", { session_id: sid, before_message_id: Number.MAX_SAFE_INTEGER }).then((history) => {
        \\  globalThis.stored = history.messages.some((m) => m.type === "user" && m.content[0].text === "replaced") ? 1 : 2;
        \\}).catch(() => { globalThis.stored = 3; });
    , "input-history.js");
    try support.pumpUntilTrue(host, "globalThis.stored > 0");
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
    try support.pumpUntilTrue(host, "globalThis.removed === 1");
    try host.eval("release();", "input-release.js");
    try support.pumpUntilTrue(host, "globalThis.finished !== 0");
    try std.testing.expectEqual(@as(i32, 1), try host.evalInt("globalThis.finished === 2 && globalThis.failure === 'unknown_session'"));
}

test "a blocked input answers its code and reaches no store" {
    var f: Fixture = undefined;
    try f.init(deferred_input, kernel_boot);
    defer f.deinit();
    const host = f.extensions.host;
    try startDeferredInput(host);
    try host.eval("release({ block: 'denied' });", "input-block.js");
    try support.pumpUntilTrue(host, "globalThis.finished !== 0");
    try std.testing.expectEqual(@as(i32, 1), try host.evalInt("globalThis.finished === 2 && globalThis.failure === 'bad_request'"));
    try host.evalModule(
        \\request("session.history", { session_id: sid, before_message_id: Number.MAX_SAFE_INTEGER }).then((history) => { globalThis.empty = history.messages.length === 0 ? 1 : 2; }).catch(() => { globalThis.empty = 3; });
    , "input-after-block.js");
    try support.pumpUntilTrue(host, "globalThis.empty > 0");
    try std.testing.expectEqual(@as(i32, 1), try host.evalInt("globalThis.empty"));
}

test "create with input shares the hook gate and a refusal leaves no session" {
    var f: Fixture = undefined;
    try f.init(
        \\import { plugins } from "yuke";
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
        try support.pumpUntilSettled(host, call);
        try std.testing.expect(std.mem.indexOf(u8, call.text.?, "failure") != null);
        try std.testing.expectEqual(@as(u64, 0), try database.session.count(&f.app.db, a, .{}));
    }
    try std.testing.expectEqual(@as(i32, 1), try host.evalInt("globalThis.proposed"));
    try host.eval("globalThis.mode='replace'", "mode.js");
    const call = host.calls.submitInputMethod("session.create", params);
    defer call.finish();
    try support.pumpUntilSettled(host, call);
    const answer = try std.json.parseFromSliceLeaky(struct { result: proto.session.SessionResult }, a, call.text.?, .{});
    const id = answer.result.session.id;
    const page = try database.message.historyPage(&f.app.db, a, id.raw, 0, 10);
    try std.testing.expectEqualStrings("replaced", page.messages[0].user.content[0].text.text);
    try std.testing.expectEqual(@as(u64, 1), (try database.event.highWater(&f.app.db, a, id.raw)).?.input_id_high);
}

test "the agents plugin sets the native limits from its options and a dispose restores them" {
    var f: Fixture = undefined;
    try f.init(
        \\import { plugins } from "yuke";
        \\import { agents } from "yuke/chat";
        \\plugins.use(agents({ catalog: { only: {} }, maxConcurrent: 2, maxDepth: 3 }));
    , kernel_boot);
    defer f.deinit();
    try std.testing.expectEqual(@as(u32, 2), f.app.engine.max_concurrent_children);
    try std.testing.expectEqual(@as(u32, 3), f.app.engine.max_agent_depth);
    try f.extensions.host.evalModule("import { plugins } from \"yuke\"; plugins.dispose(\"agents\");", "dispose.js");
    try std.testing.expectEqual(@as(u32, 8), f.app.engine.max_concurrent_children);
    try std.testing.expectEqual(@as(u32, 1), f.app.engine.max_agent_depth);
}

test "extensions install no agent tool without the agents plugin" {
    var f: Fixture = undefined;
    try f.init("", kernel_boot);
    defer f.deinit();
    for ([_][]const u8{ "spawn_agent", "send_agent_input", "stop_agent" }) |name| try std.testing.expect(f.extensions.host.tools.find(name) == null);
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
    const created = try commands.sessionCreate(&f.app.engine, a, .{ .workspace_path = host.cwd, .model = "test/model" });
    try std.testing.expect(try database.session.hasSkills(&f.app.db, a, created.session.id.raw));

    const call = host.calls.submit("skill", "{\"name\":\"pdf\"}", host.cwd);
    call.site = .{ .session_id = created.session.id, .message_id = 1, .part_id = 0 };
    try support.pumpUntilSettled(host, call);
    try std.testing.expect(!call.is_error);
    try std.testing.expect(std.mem.startsWith(u8, call.text.?, "<skill_content name=\"pdf\">\nRead the pdf.\n\nSkill directory: "));
    try std.testing.expect(std.mem.endsWith(u8, call.text.?, ".agents/skills/pdf\nResolve relative paths against this directory.\n</skill_content>"));
    call.finish();
    try host.pump();

    // The catalog decides what a name means, so an unknown name is an error the model can read.
    const missing = host.calls.submit("skill", "{\"name\":\"nope\"}", host.cwd);
    missing.site = .{ .session_id = created.session.id, .message_id = 1, .part_id = 0 };
    try support.pumpUntilSettled(host, missing);
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
    const params = try std.json.Stringify.valueAlloc(a, .{ .workspace_path = f.extensions.host.cwd, .model = "test/model" }, .{});
    var output: std.Io.Writer.Allocating = .init(a);
    const failure = (try @import("../app/call.zig").call(&f.app, a, "session.create", params, &output.writer)).?;
    try std.testing.expectEqual(proto.enums.ErrorCode.bad_request, failure.code);
    try std.testing.expect(std.mem.indexOf(u8, failure.message, f.extensions.host.cwd) != null);
    try std.testing.expect(std.mem.indexOf(u8, failure.message, "AGENTS.md") != null);
    try std.testing.expectEqual(@as(usize, 0), output.written().len);
}

test "entry startup pumps native I/O before it publishes plugin tools" {
    var f: Fixture = undefined;
    try f.init(
        \\import { plugins, exec } from "yuke";
        \\plugins.use({ name: "async-tools", async apply(ctx) {
        \\  const result = await exec("printf started", { signal: ctx.signal });
        \\  ctx.tools.define({ name: result.stdout, description: "Async startup.",
        \\    parameters: { type: "object", properties: {} }, execute: async () => "ok" });
        \\} });
    , kernel_boot);
    defer f.deinit();
    try std.testing.expect(f.extensions.host.tools.find("started") != null);
    try std.testing.expectEqual(@as(usize, 0), f.extensions.host.ops.live.items.len);
}

test "entry top-level await permits native I/O" {
    var f: Fixture = undefined;
    try f.init(
        \\import { exec } from "yuke";
        \\globalThis.entryResult = (await exec("printf ready")).stdout;
    , kernel_boot);
    defer f.deinit();
    try support.expectString(f.extensions.host, "globalThis.entryResult", "ready");
}

test "entry failure drains partial startup and preserves an independent plugin" {
    const reactor = try zio.Runtime.init(std.testing.allocator, .{ .executors = .exact(1) });
    defer reactor.deinit();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = user_entry, .data =
        \\import { plugins, exec } from "yuke";
        \\globalThis.released = 0;
        \\plugins.use({ name: "independent", apply() {} });
        \\plugins.use({ name: "partial", async apply(ctx) {
        \\  ctx.own(() => { globalThis.released++; });
        \\  await exec("printf ready", { signal: ctx.signal });
        \\  throw new Error("startup failure");
        \\}, stop() { globalThis.released++; } });
    });
    var buf: [std.fs.max_path_bytes]u8 = undefined;
    const dir = buf[0..try tmp.dir.realPath(std.testing.io, &buf)];
    const host = support.createHostWith(reactor.io(), dir);
    defer support.destroyHost(host);
    try std.testing.expectError(error.JavaScriptFault, evalUserEntry(host, dir));
    try std.testing.expect(std.mem.indexOf(u8, host.faultText(), "startup failure") != null);
    try std.testing.expectEqual(@as(i32, 2), try host.evalInt("globalThis.released"));
    try host.evalModule("import { plugins } from 'yuke'; globalThis.remaining = plugins.names().join(',');", "remaining.js");
    try support.expectString(host, "globalThis.remaining", "independent");
    try std.testing.expectEqual(@as(usize, 0), host.ops.live.items.len);
}

test "entry reports a plugin failure after immediate async cleanup" {
    const reactor = try zio.Runtime.init(std.testing.allocator, .{ .executors = .exact(1) });
    defer reactor.deinit();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = user_entry, .data =
        \\import { plugins } from "yuke";
        \\plugins.use({ name: "failed", async apply() { throw new Error("immediate failure"); } });
    });
    var buf: [std.fs.max_path_bytes]u8 = undefined;
    const dir = buf[0..try tmp.dir.realPath(std.testing.io, &buf)];
    const host = support.createHostWith(reactor.io(), dir);
    defer support.destroyHost(host);
    try std.testing.expectError(error.JavaScriptFault, evalUserEntry(host, dir));
    try std.testing.expect(std.mem.indexOf(u8, host.faultText(), "immediate failure") != null);
}
