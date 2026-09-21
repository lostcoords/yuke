//! These tests run the MCP plugin with shell servers from both protocol eras.

const std = @import("std");
const zio = @import("zio");
const support = @import("support.zig");
const Host = @import("../host.zig").Host;

/// One reactor host in an empty directory, so the plugin reads no real `.mcp.json` file.
const Fixture = struct {
    rt: *zio.Runtime,
    host: *Host,
    tmp: std.testing.TmpDir,
    root_buf: [std.fs.max_path_bytes]u8,
    root_len: usize,
    env: std.process.Environ.Map,

    /// The host keeps a pointer to `env`, so the fixture initializes in place and never moves.
    fn init(self: *Fixture, case: [:0]const u8) !void {
        self.tmp = std.testing.tmpDir(.{});
        errdefer self.tmp.cleanup();
        self.root_len = try self.tmp.dir.realPath(std.testing.io, &self.root_buf);
        self.env = .init(std.testing.allocator);
        errdefer self.env.deinit();
        // The config home is the empty test directory, so the user file is absent.
        try self.env.put("XDG_CONFIG_HOME", self.root());
        try self.env.put("MCP_TEST_GREETING", "hello");
        self.rt = try zio.Runtime.init(std.testing.allocator, .{ .executors = .exact(1) });
        errdefer self.rt.deinit();
        self.host = support.createHostWith(self.rt.io(), self.root());
        errdefer support.destroyHost(self.host);
        self.host.execution.env = &self.env;
        const global = self.host.ctx.getGlobalObject();
        defer self.host.ctx.freeValue(global);
        try self.host.ctx.setPropertyStr(global, "mcpCase", self.host.ctx.newString(case));
        try support.eval(self.host, "plugins/mcp.test.js");
    }

    fn root(self: *const Fixture) []const u8 {
        std.debug.assert(self.root_len > 0);
        return self.root_buf[0..self.root_len];
    }

    fn deinit(self: *Fixture) void {
        support.destroyHost(self.host);
        self.rt.deinit();
        self.env.deinit();
        self.tmp.cleanup();
        self.* = undefined;
    }
};

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

test "the MCP plugin connects both eras, names every failure, and answers each result kind" {
    var f: Fixture = undefined;
    try f.init("servers");
    defer f.deinit();
    const host = f.host;
    try support.pumpUntilTrue(host, "mcpReady && mcpSettled()");
    try expectState(host, "legacy", "connected · legacy · 1 tool: echo · 1 stray stdout line");
    try expectState(host, "modern", "connected · modern · 3 tools: a.tool, a_tool, echo");
    // A silent probe selects the legacy handshake next, and that handshake times out.
    try expectState(host, "silent", "failed · legacy · the request timed out");
    try expectState(host, "dies", "connected · legacy · 1 tool: echo");
    try expectState(host, "modernonly", "failed · modern · the server supports no protocol version this client speaks");
    try expectState(host, "oldver", "failed · legacy · the server answered initialize with an unknown protocol version");
    try expectState(host, "missing", "failed · the environment variable MCP_TEST_MISSING is not set");
    try expectState(host, "badargs", "failed · args must be an array of strings");
    try expectState(host, "remote", "unsupported · only stdio servers are supported");
    try expectState(host, "off", "disabled");
    // The two names that clean to one yuke name both exist.
    try std.testing.expect(support.hasTool(host, "mcp_modern_a_tool"));
    try std.testing.expect(support.hasTool(host, "mcp_modern_a_tool_2"));

    // The legacy server sent a ping after the handshake and received the empty answer.
    try expectCall(host, "mcp_legacy_echo", "{\"text\":\"there\"}", "hello says there pinged", false);
    try expectCall(host, "mcp_modern_echo", "{\"text\":\"x\"}", "modern: x", false);
    try expectCall(host, "mcp_modern_echo", "{\"text\":\"fail\"}", "no such thing", true);
    try expectCall(host, "mcp_modern_echo", "{\"text\":\"media\"}", "[image image/png, 3 bytes]\n[resource file:///x x]\nwhy", false);
    try expectCall(host, "mcp_modern_echo", "{\"text\":\"structured\"}", "{\"n\":1}", false);
    const marker = "\n[truncated 20000 characters]";
    const big = try std.testing.allocator.alloc(u8, 100_000 + marker.len);
    defer std.testing.allocator.free(big);
    @memset(big[0..100_000], 'x');
    @memcpy(big[100_000..], marker);
    try expectCall(host, "mcp_modern_echo", "{\"text\":\"big\"}", big, false);
    try expectCall(host, "mcp_modern_echo", "{\"text\":\"input\"}", "the tool asks for input, which this client cannot answer", true);
    // A list change installs a new tool set and removes the old yuke names first.
    try expectCall(host, "mcp_modern_echo", "{\"text\":\"change\"}", "changed", false);
    try support.pumpUntilTrue(host, "mcpStates().modern === 'connected · modern · 2 tools: added, echo'");
    try std.testing.expect(support.hasTool(host, "mcp_modern_added"));
    try std.testing.expect(!support.hasTool(host, "mcp_modern_a_tool"));
    try expectCall(host, "mcp_modern_echo", "{\"text\":\"slow\"}", "the request timed out", true);
    // A server that exits during a call fails the call and removes its tools.
    try expectCall(host, "mcp_dies_echo", "{}", "the server exited with code 3", true);
    try support.pumpUntilTrue(host, "mcpStates().dies === 'failed · legacy · the server exited with code 3 · stderr: boom'");
    try std.testing.expect(!support.hasTool(host, "mcp_dies_echo"));

    try host.evalModule("import { plugins } from \"yuke:ext\"; globalThis.mcpDisposed = false; Promise.resolve(plugins.dispose(\"mcp\")).then(() => { globalThis.mcpDisposed = true; });", "mcp-dispose.js");
    try support.pumpUntilTrue(host, "mcpDisposed === true");
    try std.testing.expect(!support.hasTool(host, "mcp_legacy_echo"));
    try std.testing.expect(!support.hasTool(host, "mcp_modern_echo"));
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

    try host.evalModule("import { plugins } from \"yuke:ext\"; globalThis.mcpAnswer = true; globalThis.mcpReady = false; Promise.resolve(plugins.dispose(\"mcp\")).then(mcpStart).then(() => { globalThis.mcpReady = true; });", "mcp-restart.js");
    try support.pumpUntilTrue(host, "mcpReady === true");
    try askSelect(host);
    try support.pumpUntilTrue(host, "mcpStates().ws === 'connected · legacy · 1 tool: echo · 1 stray stdout line'");
    try std.testing.expect(support.hasTool(host, "mcp_ws_echo"));
    try expectCall(host, "mcp_ws_echo", "{\"text\":\"you\"}", "hello says you pinged", false);
}
