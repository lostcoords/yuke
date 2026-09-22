//! Private MCP trust records live in the data directory and hold execution digests, never commands or secrets.

const std = @import("std");
const quickjs = @import("quickjs");
const Host = @import("../host.zig").Host;
const module = @import("module.zig");
const paths = @import("../../paths.zig");

const Context = quickjs.Context;
const Value = quickjs.Value;
const Sha256 = std.crypto.hash.sha2.Sha256;

pub fn install(host: *Host) void {
    module.installObject(host, "yuke:mcp-native", "mcpState", &.{
        .{ .name = "configPath", .arity = 0, .call = jsConfigPath },
        .{ .name = "readTrust", .arity = 2, .call = jsRead },
        .{ .name = "writeTrust", .arity = 3, .call = jsWrite },
        .{ .name = "resetTrust", .arity = 1, .call = jsReset },
    }, null);
}

fn jsConfigPath(ctx: Context, _: Value, _: []const Value) Value {
    const host = Host.fromContext(ctx);
    const base = (paths.configDir(host.gpa, host.execution.env) catch return ctx.throwTypeError("the MCP config directory is invalid")) orelse return quickjs.UNDEFINED;
    defer host.gpa.free(base);
    const path = std.fs.path.join(host.gpa, &.{ base, ".mcp.json" }) catch unreachable;
    defer host.gpa.free(path);
    return ctx.newString(path);
}

fn digest(text: []const u8) [64]u8 {
    var bytes: [Sha256.digest_length]u8 = undefined;
    Sha256.hash(text, &bytes, .{});
    return std.fmt.bytesToHex(bytes, .lower);
}

const Store = struct {
    arena: std.heap.ArenaAllocator,
    io: std.Io,
    dir: std.Io.Dir,
    name: [64]u8,

    fn open(gpa: std.mem.Allocator, io: std.Io, env: *const std.process.Environ.Map, cwd: []const u8, name: []const u8) !Store {
        std.debug.assert(std.fs.path.isAbsolute(cwd));
        std.debug.assert(name.len > 0);
        var arena: std.heap.ArenaAllocator = .init(gpa);
        errdefer arena.deinit();
        const alloc = arena.allocator();
        const base = (try paths.dataDir(alloc, env)) orelse return error.HomeUnavailable;
        const workspace = try std.Io.Dir.realPathFileAbsoluteAlloc(io, cwd, alloc);
        const workspace_key = digest(workspace);
        const path = try std.fs.path.join(alloc, &.{ base, "mcp-trust", &workspace_key });
        var dir = try std.Io.Dir.cwd().createDirPathOpen(io, path, .{
            .permissions = .fromMode(0o700),
            .open_options = .{ .follow_symlinks = false },
        });
        errdefer dir.close(io);
        const canonical = try dir.realPathFileAlloc(io, ".", alloc);
        if (std.mem.eql(u8, canonical, workspace) or
            (std.mem.startsWith(u8, canonical, workspace) and (workspace.len == 1 or canonical[workspace.len] == std.fs.path.sep)))
            return error.WorkspaceTrustPath;
        return .{ .arena = arena, .io = io, .dir = dir, .name = digest(name) };
    }

    fn close(self: *Store) void {
        self.dir.close(self.io);
        self.arena.deinit();
        self.* = undefined;
    }

    fn exists(self: *Store) !bool {
        const info = self.dir.statFile(self.io, &self.name, .{ .follow_symlinks = false }) catch |err| switch (err) {
            error.FileNotFound => return false,
            else => return err,
        };
        if (info.kind != .file or info.nlink != 1) return error.InvalidTrustFile;
        return true;
    }

    fn read(self: *Store, identity: []const u8) !?bool {
        std.debug.assert(identity.len > 0);
        if (!try self.exists()) return null;
        const bytes = try self.dir.readFileAlloc(self.io, &self.name, self.arena.allocator(), .limited(66));
        if (bytes.len != 65 or (bytes[0] != '0' and bytes[0] != '1')) return error.InvalidTrustFile;
        const expected = digest(identity);
        if (!std.mem.eql(u8, bytes[1..], &expected)) return null;
        return bytes[0] == '1';
    }

    fn write(self: *Store, identity: []const u8, approved: bool) !void {
        std.debug.assert(identity.len > 0);
        _ = try self.exists();
        var bytes: [65]u8 = undefined;
        bytes[0] = if (approved) '1' else '0';
        bytes[1..].* = digest(identity);
        var atomic = try self.dir.createFileAtomic(self.io, &self.name, .{ .permissions = .fromMode(0o600), .replace = true });
        defer atomic.deinit(self.io);
        try atomic.file.setPermissions(self.io, .fromMode(0o600));
        var writer = atomic.file.writer(self.io, &.{});
        try writer.interface.writeAll(&bytes);
        try writer.interface.flush();
        try atomic.replace(self.io);
    }

    fn reset(self: *Store) !void {
        if (try self.exists()) try self.dir.deleteFile(self.io, &self.name);
    }
};

fn open(ctx: Context, args: []const Value) ?Store {
    if (args.len == 0) {
        _ = ctx.throwTypeError("MCP trust needs a server name");
        return null;
    }
    const name = module.string(ctx, args[0]) orelse {
        _ = ctx.throwTypeError("the MCP server name must be a string");
        return null;
    };
    defer ctx.freeCString(name.ptr);
    if (name.len == 0) {
        _ = ctx.throwTypeError("the MCP server name must not be empty");
        return null;
    }
    const host = Host.fromContext(ctx);
    return Store.open(host.gpa, host.io, host.execution.env, host.cwd, name) catch {
        _ = ctx.throwTypeError("the private MCP trust directory is unavailable or inside the workspace");
        return null;
    };
}

/// Read the nonempty execution identity in the second argument, or null.
fn identityArg(ctx: Context, args: []const Value) ?[:0]const u8 {
    if (args.len < 2) return null;
    const identity = module.string(ctx, args[1]) orelse return null;
    if (identity.len != 0) return identity;
    ctx.freeCString(identity.ptr);
    return null;
}

fn jsRead(ctx: Context, _: Value, args: []const Value) Value {
    const identity = identityArg(ctx, args) orelse return ctx.throwTypeError("the MCP execution identity must be a nonempty string");
    defer ctx.freeCString(identity.ptr);
    var store = open(ctx, args) orelse return module.throwPending(ctx);
    defer store.close();
    const decision = store.read(identity) catch return ctx.throwTypeError("the MCP trust record is invalid or unreadable");
    return if (decision) |approved| ctx.newBool(approved) else quickjs.UNDEFINED;
}

fn jsWrite(ctx: Context, _: Value, args: []const Value) Value {
    if (args.len < 3 or !ctx.isBool(args[2])) return ctx.throwTypeError("MCP trust needs a boolean decision");
    const identity = identityArg(ctx, args) orelse return ctx.throwTypeError("the MCP execution identity must be a nonempty string");
    defer ctx.freeCString(identity.ptr);
    var store = open(ctx, args) orelse return module.throwPending(ctx);
    defer store.close();
    store.write(identity, ctx.toBool(args[2]) catch unreachable) catch return ctx.throwTypeError("the MCP trust record could not be saved");
    return quickjs.UNDEFINED;
}

fn jsReset(ctx: Context, _: Value, args: []const Value) Value {
    var store = open(ctx, args) orelse return module.throwPending(ctx);
    defer store.close();
    store.reset() catch return ctx.throwTypeError("the MCP trust record could not be removed");
    return quickjs.UNDEFINED;
}

test "MCP trust persists per workspace, server, and execution identity" {
    const t = std.testing;
    var tmp = t.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDirPath(t.io, "workspace");
    try tmp.dir.createDirPath(t.io, "other");
    const base = try tmp.dir.realPathFileAlloc(t.io, ".", t.allocator);
    defer t.allocator.free(base);
    const cwd = try tmp.dir.realPathFileAlloc(t.io, "workspace", t.allocator);
    defer t.allocator.free(cwd);
    const other = try tmp.dir.realPathFileAlloc(t.io, "other", t.allocator);
    defer t.allocator.free(other);
    var env: std.process.Environ.Map = .init(t.allocator);
    defer env.deinit();
    try env.put("XDG_DATA_HOME", base);
    {
        var store = try Store.open(t.allocator, t.io, &env, cwd, "server");
        defer store.close();
        try t.expectEqual(null, try store.read("command"));
        try store.write("command", true);
    }
    var store = try Store.open(t.allocator, t.io, &env, cwd, "server");
    defer store.close();
    try t.expectEqual(true, try store.read("command"));
    const info = try store.dir.statFile(t.io, &store.name, .{});
    try t.expectEqual(@as(std.posix.mode_t, 0o600), info.permissions.toMode() & 0o777);
    const saved = try store.dir.readFileAlloc(t.io, &store.name, t.allocator, .limited(66));
    defer t.allocator.free(saved);
    try t.expectEqual(@as(usize, 65), saved.len);
    try t.expect(std.mem.indexOf(u8, saved, "command") == null);
    try t.expectEqual(null, try store.read("changed"));
    var second = try Store.open(t.allocator, t.io, &env, cwd, "second");
    defer second.close();
    try t.expectEqual(null, try second.read("command"));
    var elsewhere = try Store.open(t.allocator, t.io, &env, other, "server");
    defer elsewhere.close();
    try t.expectEqual(null, try elsewhere.read("command"));
    try store.write("command", false);
    try t.expectEqual(false, try store.read("command"));
    try store.reset();
    try t.expectEqual(null, try store.read("command"));
    try env.put("XDG_DATA_HOME", cwd);
    try t.expectError(error.WorkspaceTrustPath, Store.open(t.allocator, t.io, &env, cwd, "server"));
}
