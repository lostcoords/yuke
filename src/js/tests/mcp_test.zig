//! These tests run the MCP plugin with shell servers from both protocol eras.

const std = @import("std");
const zio = @import("zio");
const support = @import("support.zig");
const Host = @import("../host.zig").Host;
const HttpPeer = @import("mcp_http_peer.zig").Peer;

/// One reactor host in an empty directory, so the plugin reads no real `.mcp.json` file.
const Fixture = struct {
    rt: *zio.Runtime,
    host: *Host,
    tmp: std.testing.TmpDir,
    root_buf: [std.fs.max_path_bytes]u8,
    root_len: usize,
    env: std.process.Environ.Map,
    /// The loopback MCP peer of the HTTP case.
    peer: ?*HttpPeer = null,

    /// The host keeps a pointer to `env`, so the fixture initializes in place and never moves.
    fn init(self: *Fixture, case: [:0]const u8) !void {
        self.peer = null;
        self.tmp = std.testing.tmpDir(.{});
        errdefer self.tmp.cleanup();
        self.root_len = try self.tmp.dir.realPath(std.testing.io, &self.root_buf);
        self.env = .init(std.testing.allocator);
        errdefer self.env.deinit();
        // The private config and data directories are outside the test workspace.
        try self.env.put("XDG_CONFIG_HOME", self.root());
        try self.env.put("XDG_DATA_HOME", self.root());
        try self.tmp.dir.createDirPath(std.testing.io, "workspace");
        self.root_len = try self.tmp.dir.realPathFile(std.testing.io, "workspace", &self.root_buf);
        try self.env.put("MCP_TEST_GREETING", "hello");
        try self.env.put("MCP_TEST_TOKEN", "secret");
        self.rt = try zio.Runtime.init(std.testing.allocator, .{ .executors = .exact(1) });
        errdefer self.rt.deinit();
        self.host = support.createHostWith(self.rt.io(), self.root());
        errdefer support.destroyHost(self.host);
        self.host.execution.env = &self.env;
        const global = self.host.ctx.getGlobalObject();
        defer self.host.ctx.freeValue(global);
        try self.host.ctx.setPropertyStr(global, "mcpCase", self.host.ctx.newString(case));
        if (std.mem.eql(u8, case, "http")) {
            const peer = try HttpPeer.create(std.testing.allocator, self.rt.io());
            self.peer = peer;
            peer.wake = &self.host.wake;
            try self.host.ctx.setPropertyStr(global, "mcpHttpBase", self.host.ctx.newString(peer.base));
        }
        try support.eval(self.host, "plugins/mcp.test.js");
    }

    fn root(self: *const Fixture) []const u8 {
        std.debug.assert(self.root_len > 0);
        return self.root_buf[0..self.root_len];
    }

    fn deinit(self: *Fixture) void {
        // The peer sets the host's wake, so its tasks end before the host does.
        if (self.peer) |peer| peer.destroy();
        support.destroyHost(self.host);
        self.rt.deinit();
        self.env.deinit();
        self.tmp.cleanup();
        self.* = undefined;
    }
};

fn deferred(host: *Host, name: []const u8) bool {
    return host.tools.entries.items[host.tools.find(name).?].decl.defer_loading;
}

fn expectSearch(host: *Host, args: []const u8, prefix: []const u8, loaded: []const []const u8, not_loaded: []const u8) !void {
    const call = host.calls.submit("tool_search", args, host.cwd);
    try support.pumpUntilSettled(host, call);
    try std.testing.expect(!call.is_error);
    try std.testing.expect(std.mem.startsWith(u8, call.text orelse "", prefix));
    const extra = call.extra_json orelse return error.TestExpectedEqual;
    for (loaded) |name| try std.testing.expect(std.mem.indexOf(u8, extra, name) != null);
    try std.testing.expect(std.mem.indexOf(u8, extra, not_loaded) == null);
    try support.dropCall(host, call);
}

fn expectState(host: *Host, name: []const u8, want: []const u8) !void {
    const source = try std.fmt.allocPrintSentinel(std.testing.allocator, "globalThis.mcpRow = mcpStates()[\"{s}\"];", .{name}, 0);
    defer std.testing.allocator.free(source);
    try host.evalModule(source, "mcp-row.js");
    try support.expectString(host, "mcpRow", want);
}

fn expectCall(host: *Host, name: []const u8, args: []const u8, want: []const u8, want_error: bool) !void {
    const call = host.calls.submit(name, args, host.cwd);
    try support.pumpUntilSettled(host, call);
    try std.testing.expectEqualStrings(want, call.text orelse "");
    try std.testing.expectEqual(want_error, call.is_error);
    try support.dropCall(host, call);
}

/// The first run of a session calls `tools.select`, where the plugin asks for trust.
fn askSelect(host: *Host) !void {
    const call = host.calls.submitHook("tools.select", "{\"tools\":[],\"context\":{}}");
    try support.pumpUntilSettled(host, call);
    try std.testing.expect(!call.is_error);
    try support.dropCall(host, call);
}

test "a silent MCP server times out after the legacy fallback and releases its resources" {
    var f: Fixture = undefined;
    const start = std.Io.Timestamp.now(std.testing.io, .awake);
    try f.init("silent");
    defer f.deinit();
    const host = f.host;
    try support.pumpUntilTrue(host, "mcpReady && mcpSettled()");
    try expectState(host, "silent", "failed · legacy · the request timed out");
    try std.testing.expect(start.durationTo(std.Io.Timestamp.now(std.testing.io, .awake)).toMilliseconds() >= 100);
    try std.testing.expect(!support.hasTool(host, "mcp_silent_echo"));
    try host.close();
    try std.testing.expectEqual(@as(usize, 0), host.timers.entries.items.len);
    try std.testing.expectEqual(@as(usize, 0), host.procs.live.items.len);
    try std.testing.expectEqual(@as(usize, 0), host.ops.live.items.len);
}

test "an MCP call timeout cancels the request and ignores its late reply" {
    var f: Fixture = undefined;
    try f.init("timeout");
    defer f.deinit();
    const host = f.host;
    try support.pumpUntilTrue(host, "mcpReady && mcpSettled()");
    try expectState(host, "modern", "connected · modern · 3 tools: a.tool, a_tool, echo");
    const start = std.Io.Timestamp.now(host.io, .awake);
    const call = host.calls.submit("mcp_modern_echo", "{\"text\":\"slow\"}", host.cwd);
    try support.pumpUntilSettled(host, call);
    try std.testing.expect(call.is_error);
    try std.testing.expectEqualStrings("the request timed out", call.text orelse "");
    try std.testing.expect(start.durationTo(std.Io.Timestamp.now(host.io, .awake)).toMilliseconds() >= 100);
    try expectCall(host, "mcp_modern_echo", "{\"text\":\"after-timeout\"}", "canceled: yes", false);
    try std.testing.expect(call.is_error);
    try std.testing.expectEqualStrings("the request timed out", call.text orelse "");
    try support.dropCall(host, call);
    try host.evalModule("import { plugins } from \"yuke:ext\"; globalThis.mcpDisposed = false; Promise.resolve(plugins.dispose(\"mcp\")).then(() => { globalThis.mcpDisposed = true; });", "mcp-timeout-dispose.js");
    try support.pumpUntilTrue(host, "mcpDisposed === true");
    try std.testing.expect(!support.hasTool(host, "mcp_modern_echo"));
    try host.close();
    try std.testing.expectEqual(@as(usize, 0), host.timers.entries.items.len);
    try std.testing.expectEqual(@as(usize, 0), host.procs.live.items.len);
    try std.testing.expectEqual(@as(usize, 0), host.ops.live.items.len);
}

test "the MCP plugin connects both eras, names every failure, and answers each result kind" {
    var f: Fixture = undefined;
    try f.init("servers");
    defer f.deinit();
    const host = f.host;
    try support.pumpUntilTrue(host, "mcpReady && mcpSettled()");
    try expectState(host, "legacy", "connected · legacy · 1 tool: echo · 1 stray stdout line");
    try expectState(host, "modern", "connected · modern · 3 tools: a.tool, a_tool, echo");
    try expectState(host, "dies", "connected · legacy · 1 tool: echo");
    try expectState(host, "modernonly", "failed · modern · the server supports no protocol version this client speaks");
    try expectState(host, "downgrade", "connected · legacy · 1 tool: echo");
    try expectState(host, "oldver", "failed · legacy · the server answered initialize with an unknown protocol version");
    try expectState(host, "missing", "failed · the environment variable MCP_TEST_MISSING is not set");
    try expectState(host, "badargs", "failed · args must be an array of strings");
    try expectState(host, "socket", "failed · type must be stdio, http, or sse");
    try expectState(host, "ftp", "failed · url must be an http or https URL");
    try expectState(host, "off", "disabled");
    // The two names that clean to one yuke name both exist.
    try std.testing.expect(support.hasTool(host, "mcp_modern_a_tool"));
    try std.testing.expect(support.hasTool(host, "mcp_modern_a_tool_2"));
    // An MCP tool defers by default; `alwaysLoad` keeps the legacy server's tool eager.
    try std.testing.expect(deferred(host, "mcp_modern_echo"));
    try std.testing.expect(!deferred(host, "mcp_legacy_echo"));
    // One search tool names the connected servers and loads the tools that match.
    try std.testing.expect(support.hasTool(host, "tool_search"));
    try std.testing.expect(!deferred(host, "tool_search"));
    // The eager legacy tool is listed but not loaded; the two deferred ones are.
    try expectSearch(host, "{\"query\":\"echo\"}", "Found 4 MCP tools:", &.{ "mcp_dies_echo", "mcp_downgrade_echo", "mcp_modern_echo" }, "mcp_legacy_echo");
    try expectSearch(host, "{\"query\":\"echo\",\"server\":\"modern\",\"limit\":1}", "Found 1 MCP tool:", &.{"mcp_modern_echo"}, "mcp_legacy_echo");
    try expectCall(host, "tool_search", "{\"query\":\"nothing_like_this\"}", "No MCP tool matches \"nothing_like_this\". Connected servers: legacy, modern, dies, downgrade.", false);
    try expectCall(host, "tool_search", "{\"query\":\"\"}", "query must be a nonempty string", true);

    // The legacy server sent a ping after the handshake and received the empty answer.
    try expectCall(host, "mcp_legacy_echo", "{\"text\":\"there\"}", "hello says there pinged", false);
    try expectCall(host, "mcp_modern_echo", "{\"text\":\"x\"}", "modern: x", false);
    try expectCall(host, "mcp_modern_echo", "[]", "MCP tool arguments must be an object", true);
    try expectCall(host, "mcp_modern_echo", "{\"text\":\"fail\"}", "no such thing", true);
    try expectCall(host, "mcp_modern_echo", "{\"text\":\"media\"}", "[image image/png, 3 bytes]\n[resource file:///x x]\nwhy", false);
    // The image block also attaches as media, beside the line that names it.
    const media = host.calls.submit("mcp_modern_echo", "{\"text\":\"media\"}", host.cwd);
    try support.pumpUntilSettled(host, media);
    try std.testing.expect(std.mem.indexOf(u8, media.extra_json orelse "", "\"media\":[{\"hash\":\"abab") != null);
    try support.dropCall(host, media);
    try expectCall(host, "mcp_modern_echo", "{\"text\":\"structured\"}", "{\"n\":1}", false);
    const marker = "\n[truncated 20000 characters]";
    const big = try std.testing.allocator.alloc(u8, 100_000 + marker.len);
    defer std.testing.allocator.free(big);
    @memset(big[0..100_000], 'x');
    @memcpy(big[100_000..], marker);
    try expectCall(host, "mcp_modern_echo", "{\"text\":\"big\"}", big, false);
    try expectCall(host, "mcp_modern_echo", "{\"text\":\"input\"}", "the tool asks for input, which this client cannot answer", true);
    try host.evalModule("import { plugins } from \"yuke:ext\"; globalThis.mcpConflict = false; plugins.use({ name: \"mcp-conflict\", apply(ctx) { ctx.tools.define({ name: \"mcp_modern_added\", description: \"Occupied name.\", parameters: { type: \"object\", properties: {} }, execute() { return \"other\"; } }); } }).ready.then(() => { globalThis.mcpConflict = true; });", "mcp-conflict.js");
    try support.pumpUntilTrue(host, "mcpConflict === true");
    try expectCall(host, "mcp_modern_echo", "{\"text\":\"change\"}", "changed", false);
    try support.pumpUntilTrue(host, "mcpStates().modern.includes('another tool already has this name')");
    try std.testing.expect(support.hasTool(host, "mcp_modern_a_tool"));
    try expectCall(host, "mcp_modern_echo", "{\"text\":\"restored\"}", "modern: restored", false);
    try host.evalModule("import { plugins } from \"yuke:ext\"; globalThis.mcpConflict = true; Promise.resolve(plugins.dispose(\"mcp-conflict\")).then(() => { globalThis.mcpConflict = false; });", "mcp-unconflict.js");
    try support.pumpUntilTrue(host, "mcpConflict === false");
    // A list change installs a new tool set and removes the old yuke names first.
    try expectCall(host, "mcp_modern_echo", "{\"text\":\"change\"}", "changed", false);
    try support.pumpUntilTrue(host, "mcpStates().modern === 'connected · modern · 2 tools: added, echo'");
    try std.testing.expect(support.hasTool(host, "mcp_modern_added"));
    try std.testing.expect(!support.hasTool(host, "mcp_modern_a_tool"));
    try expectCall(host, "mcp_modern_echo", "{\"text\":\"badchange\"}", "changed", false);
    try support.pumpUntilTrue(host, "mcpStates().modern.includes('invalid MCP tool input schema')");
    try std.testing.expect(support.hasTool(host, "mcp_modern_added"));
    try expectCall(host, "mcp_modern_added", "{\"text\":\"still\"}", "modern: still", false);
    // A server that exits during a call fails the call and removes its tools.
    try expectCall(host, "mcp_dies_echo", "{}", "the server exited with code 3", true);
    try support.pumpUntilTrue(host, "mcpStates().dies === 'failed · legacy · the server exited with code 3 · stderr: boom'");
    try std.testing.expect(!support.hasTool(host, "mcp_dies_echo"));

    // A stop answers a pending call at once; it does not wait for the server to exit.
    const slow = host.calls.submit("mcp_modern_echo", "{\"text\":\"slow\"}", host.cwd);
    try host.pump();
    try std.testing.expect(slow.state == .running);
    try host.evalModule("import { plugins } from \"yuke:ext\"; globalThis.mcpDisposed = false; Promise.resolve(plugins.dispose(\"mcp\")).then(() => { globalThis.mcpDisposed = true; });", "mcp-dispose.js");
    try support.pumpUntilSettled(host, slow);
    try std.testing.expect(slow.is_error);
    try std.testing.expectEqualStrings("the MCP server stopped", slow.text orelse "");
    try support.dropCall(host, slow);
    try support.pumpUntilTrue(host, "mcpDisposed === true");
    try std.testing.expect(!support.hasTool(host, "mcp_legacy_echo"));
    try std.testing.expect(!support.hasTool(host, "mcp_modern_echo"));
}

test "a search tool name conflict clears on the next catalog change" {
    var f: Fixture = undefined;
    try f.init("search-conflict");
    defer f.deinit();
    const host = f.host;
    try support.pumpUntilTrue(host, "mcpReady && mcpSettled()");
    try support.pumpUntilTrue(host, "(mcpStates().config ?? '').includes('tool_search: another tool already has this name')");
    try host.evalModule("import { plugins } from \"yuke:ext\"; globalThis.mcpHeld = true; Promise.resolve(plugins.dispose(\"search-holder\")).then(() => { globalThis.mcpHeld = false; });", "mcp-release.js");
    try support.pumpUntilTrue(host, "mcpHeld === false");
    try std.testing.expect(!support.hasTool(host, "tool_search"));
    try expectCall(host, "mcp_modern_echo", "{\"text\":\"change\"}", "changed", false);
    try support.pumpUntilTrue(host, "mcpStates().modern === 'connected · modern · 2 tools: added, echo'");
    try std.testing.expect(support.hasTool(host, "tool_search"));
    try std.testing.expect(!deferred(host, "tool_search"));
}

test "MCP servers over Streamable HTTP and the old SSE transport connect, call, cancel, and end the session" {
    var f: Fixture = undefined;
    try f.init("http");
    defer f.deinit();
    const host = f.host;
    const peer = f.peer.?;
    try support.pumpUntilTrue(host, "mcpReady && mcpSettled()");
    try expectState(host, "modern", "connected · modern · 3 tools: echo, region, slow · dropped: broken (x-mcp-header on a parameter that is not a string, integer, or boolean)");
    // A modern error in a 400 body is no legacy server, so the client does not fall back.
    try expectState(host, "mismatch", "failed · modern · Header mismatch");
    // The modern probe fails outside a session, so the client falls back to `initialize` and keeps the session.
    try expectState(host, "legacy", "connected · legacy · 1 tool: echo");
    try expectState(host, "old", "connected · legacy · 1 tool: echo");
    try expectState(host, "denied", "failed · legacy · the server answered HTTP 401: unauthorized");

    // A progress notification before the answer changes nothing.
    try expectCall(host, "mcp_modern_echo", "{\"text\":\"hi\"}", "modern http: hi", false);
    // An annotated argument travels in its header too, encoded when it is not plain ASCII.
    try expectCall(host, "mcp_modern_region", "{\"region\":\"eu-west1\"}", "region header: eu-west1", false);
    try expectCall(host, "mcp_modern_region", "{\"region\":\"世界\"}", "region header: =?base64?5LiW55WM?=", false);
    try expectCall(host, "mcp_old_echo", "{\"text\":\"hi\"}", "old sse: hi", false);
    // A timeout closes the modern stream, which is the modern cancel.
    try expectCall(host, "mcp_modern_slow", "{}", "the request timed out", true);
    try support.pumpUntilSet(host, &peer.cancel_seen);
    // An answer above 256 KiB arrives whole, cut only at the model's result limit.
    const big = host.calls.submit("mcp_legacy_echo", "{\"text\":\"big\"}", host.cwd);
    try support.pumpUntilSettled(host, big);
    try std.testing.expect(!big.is_error);
    try std.testing.expect(std.mem.endsWith(u8, big.text orelse "", "[truncated 207200 characters]"));
    try support.dropCall(host, big);
    // A forgotten session fails the call that finds it, and the server starts a new session.
    try expectCall(host, "mcp_legacy_echo", "{\"text\":\"expire\"}", "legacy http: expire", false);
    try expectCall(host, "mcp_legacy_echo", "{\"text\":\"late\"}", "the server ended the session", true);
    try support.pumpUntilTrue(host, "mcpStates().legacy === 'connected · legacy · 1 tool: echo'");
    try expectCall(host, "mcp_legacy_echo", "{\"text\":\"again\"}", "legacy http: again", false);
    // The legacy GET stream carries the list change, and the next list names the new tool.
    try expectCall(host, "mcp_legacy_echo", "{\"text\":\"change\"}", "legacy http: change", false);
    try support.pumpUntilTrue(host, "mcpStates().legacy === 'connected · legacy · 2 tools: added, echo'");

    try host.evalModule("import { plugins } from \"yuke:ext\"; globalThis.mcpDisposed = false; Promise.resolve(plugins.dispose(\"mcp\")).then(() => { globalThis.mcpDisposed = true; });", "mcp-http-dispose.js");
    try support.pumpUntilTrue(host, "mcpDisposed === true");
    try std.testing.expect(peer.deleted.load(.acquire));
    try host.close();
    try std.testing.expectEqual(@as(usize, 0), host.bodies.live.items.len);
    try std.testing.expectEqual(@as(usize, 0), host.ops.live.items.len);
    try std.testing.expectEqual(@as(usize, 0), host.abort_listeners.items.len);
    try std.testing.expectEqual(@as(?anyerror, null), peer.failure);
}

test "a workspace server starts only after the user trusts it at the first run" {
    var f: Fixture = undefined;
    try f.init("trust");
    defer f.deinit();
    const host = f.host;
    try host.evalModule("globalThis.mcpAnswer = false; globalThis.mcpReady = false; mcpStart().then(() => { globalThis.mcpReady = true; });", "mcp-start.js");
    try support.pumpUntilTrue(host, "mcpReady === true");
    try expectState(host, "ws", "untrusted");
    try askSelect(host);
    try expectState(host, "ws", "disabled · not trusted");
    try std.testing.expect(!support.hasTool(host, "mcp_ws_echo"));
    // The plugin asks the question once per process, not once per run.
    try askSelect(host);
    try std.testing.expectEqual(@as(i32, 1), try host.evalInt("asked.length"));

    try host.evalModule("import { plugins } from \"yuke:ext\"; globalThis.mcpReady = false; Promise.resolve(plugins.dispose(\"mcp\")).then(mcpStart).then(() => { globalThis.mcpReady = true; });", "mcp-denied-reload.js");
    try support.pumpUntilTrue(host, "mcpReady === true");
    try expectState(host, "ws", "disabled · not trusted");
    try askSelect(host);
    try std.testing.expectEqual(@as(i32, 1), try host.evalInt("asked.length"));
    try host.evalModule("globalThis.mcpReset = false; mcpPlugin.resetTrust().then(() => { globalThis.mcpReset = true; });", "mcp-reset.js");
    try support.pumpUntilTrue(host, "mcpReset === true");

    try host.evalModule("import { plugins } from \"yuke:ext\"; globalThis.mcpAnswer = true; globalThis.mcpReady = false; Promise.resolve(plugins.dispose(\"mcp\")).then(mcpStart).then(() => { globalThis.mcpReady = true; });", "mcp-restart.js");
    try support.pumpUntilTrue(host, "mcpReady === true");
    try askSelect(host);
    try support.pumpUntilTrue(host, "mcpStates().ws === 'connected · legacy · 1 tool: echo · 1 stray stdout line'");
    try std.testing.expect(support.hasTool(host, "mcp_ws_echo"));
    try expectCall(host, "mcp_ws_echo", "{\"text\":\"you\"}", "hello says you pinged", false);
    try host.evalModule("import { plugins } from \"yuke:ext\"; globalThis.mcpReorder = true; globalThis.mcpTimeout = 800; globalThis.mcpReady = false; Promise.resolve(plugins.dispose(\"mcp\")).then(mcpStart).then(() => { globalThis.mcpReady = true; });", "mcp-approved-reload.js");
    try support.pumpUntilTrue(host, "mcpReady && mcpSettled()");
    try askSelect(host);
    try std.testing.expectEqual(@as(i32, 2), try host.evalInt("asked.length"));
    try std.testing.expect(support.hasTool(host, "mcp_ws_echo"));
    try host.evalModule("import { plugins } from \"yuke:ext\"; globalThis.mcpReady = false; Promise.resolve(plugins.dispose(\"mcp\")).then(() => mcpStart(\"changed\")).then(() => { globalThis.mcpReady = true; });", "mcp-changed.js");
    try support.pumpUntilTrue(host, "mcpReady === true");
    try expectState(host, "ws", "untrusted");
    try askSelect(host);
    try support.pumpUntilTrue(host, "mcpSettled()");
    try std.testing.expectEqual(@as(i32, 3), try host.evalInt("asked.length"));
    try host.evalModule("globalThis.mcpReset = false; mcpPlugin.resetTrust().then(() => { globalThis.mcpReset = true; });", "mcp-connected-reset.js");
    try support.pumpUntilTrue(host, "mcpReset === true");
    try expectState(host, "ws", "untrusted");
    try std.testing.expect(!support.hasTool(host, "mcp_ws_echo"));
    try askSelect(host);
    try support.pumpUntilTrue(host, "mcpSettled()");
    try std.testing.expect(support.hasTool(host, "mcp_ws_echo"));
    try std.testing.expectEqual(@as(i32, 4), try host.evalInt("asked.length"));
    try host.evalModule("import { plugins } from \"yuke:ext\"; globalThis.mcpEnabled = false; globalThis.mcpReady = false; Promise.resolve(plugins.dispose(\"mcp\")).then(() => mcpStart(\"changed\")).then(() => { globalThis.mcpReady = true; });", "mcp-disabled.js");
    try support.pumpUntilTrue(host, "mcpReady === true");
    try expectState(host, "ws", "disabled");
    try host.evalModule("globalThis.mcpReset = false; mcpPlugin.resetTrust().then(() => { globalThis.mcpReset = true; });", "mcp-disabled-reset.js");
    try support.pumpUntilTrue(host, "mcpReset === true");
    try host.evalModule("import { plugins } from \"yuke:ext\"; globalThis.mcpEnabled = true; globalThis.mcpReady = false; Promise.resolve(plugins.dispose(\"mcp\")).then(() => mcpStart(\"changed\")).then(() => { globalThis.mcpReady = true; });", "mcp-enabled.js");
    try support.pumpUntilTrue(host, "mcpReady === true");
    try expectState(host, "ws", "untrusted");
}

test "MCP rejects malformed envelopes and content without a peer crash" {
    var f: Fixture = undefined;
    try f.init("validation");
    defer f.deinit();
}

test "MCP refuses incompatible discovery and incomplete catalogs" {
    var f: Fixture = undefined;
    try f.init("protocol");
    defer f.deinit();
    const host = f.host;
    try support.pumpUntilTrue(host, "mcpReady && mcpSettled()");
    try expectState(host, "version", "failed · modern · the server supports no protocol version this client speaks");
    try expectState(host, "noTools", "connected · modern · no tools");
    try expectState(host, "capabilities", "failed · modern · invalid MCP tool capabilities");
    try expectState(host, "envelope", "failed · modern · invalid MCP envelope");
    try expectState(host, "duplicate", "failed · modern · invalid MCP duplicate tool name");
    try expectState(host, "schema", "failed · modern · invalid MCP tool input schema");
    try expectState(host, "cursor", "failed · modern · invalid MCP tool cursor");
}

test "a headless MCP denial is not a persistent user decision" {
    var f: Fixture = undefined;
    try f.init("trust");
    defer f.deinit();
    const host = f.host;
    try host.evalModule("import { interaction } from \"yuke:ext\"; globalThis.mcpHeadless = interaction.install({ interactive: false, notify() {} }); globalThis.mcpReady = false; mcpStart().then(() => { globalThis.mcpReady = true; });", "mcp-headless.js");
    try support.pumpUntilTrue(host, "mcpReady === true");
    try askSelect(host);
    try expectState(host, "ws", "disabled · not trusted");
    try std.testing.expectEqual(@as(i32, 0), try host.evalInt("asked.length"));
    try host.evalModule("import { plugins } from \"yuke:ext\"; mcpHeadless(); globalThis.mcpReady = false; Promise.resolve(plugins.dispose(\"mcp\")).then(mcpStart).then(() => { globalThis.mcpReady = true; });", "mcp-interactive.js");
    try support.pumpUntilTrue(host, "mcpReady === true");
    try expectState(host, "ws", "untrusted");
}
