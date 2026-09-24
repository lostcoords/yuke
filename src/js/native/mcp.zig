//! The MCP config path and the private MCP records: trust decisions and sign-in grants, each in a 0700 data directory.

const std = @import("std");
const quickjs = @import("quickjs");
const Host = @import("../host.zig").Host;
const module = @import("module.zig");
const paths = @import("../../paths.zig");

const Context = quickjs.Context;
const Value = quickjs.Value;
const Sha256 = std.crypto.hash.sha2.Sha256;

const max_record_bytes = 64 * 1024;

/// A closed set of record kinds; a trust record belongs to one workspace, a grant to the server URL alone.
const Scope = enum {
    @"mcp-trust",
    @"mcp-oauth",

    fn perWorkspace(scope: Scope) bool {
        return scope == .@"mcp-trust";
    }
};

pub fn install(host: *Host) void {
    module.installFunctions(host, "yuke:mcp-native", &.{
        .{ .name = "configPath", .arity = 0, .call = jsConfigPath },
        .{ .name = "readRecord", .arity = 2, .call = jsRead },
        .{ .name = "writeRecord", .arity = 3, .call = jsWrite },
        .{ .name = "removeRecord", .arity = 2, .call = jsRemove },
    });
}

fn jsConfigPath(ctx: Context, _: Value, _: []const Value) Value {
    const host = Host.fromContext(ctx);
    const base = (paths.configDir(host.gpa, host.execution.env) catch return ctx.throwTypeError("the MCP config directory is invalid")) orelse return quickjs.UNDEFINED;
    defer host.gpa.free(base);
    const path = std.Io.Dir.path.join(host.gpa, &.{ base, ".mcp.json" }) catch unreachable;
    defer host.gpa.free(path);
    return ctx.newString(path);
}

/// One open record file. The name is a digest, so no server name or URL reaches the file system.
const Record = struct {
    arena: std.heap.ArenaAllocator,
    io: std.Io,
    dir: std.Io.Dir,
    name: [64]u8,

    fn open(gpa: std.mem.Allocator, io: std.Io, env: *const std.process.Environ.Map, cwd: []const u8, scope: Scope, key: []const u8) !Record {
        std.debug.assert(std.Io.Dir.path.isAbsolute(cwd));
        std.debug.assert(key.len > 0);
        var arena: std.heap.ArenaAllocator = .init(gpa);
        errdefer arena.deinit();
        const alloc = arena.allocator();
        const base = (try paths.dataDir(alloc, env)) orelse return error.HomeUnavailable;
        const path = try std.Io.Dir.path.join(alloc, &.{ base, @tagName(scope) });
        var dir = try std.Io.Dir.cwd().createDirPathOpen(io, path, .{
            .permissions = .fromMode(0o700),
            .open_options = .{ .follow_symlinks = false },
        });
        errdefer dir.close(io);
        // A directory made by another tool may be open to others; the grants inside are secrets.
        const info = try dir.stat(io);
        if (info.permissions.toMode() & 0o077 != 0) try dir.setPermissions(io, .fromMode(0o700));
        // A store inside the workspace lets a checkout plant its own trust.
        const workspace = try std.Io.Dir.realPathFileAbsoluteAlloc(io, cwd, alloc);
        const canonical = try dir.realPathFileAlloc(io, ".", alloc);
        if (std.mem.startsWith(u8, canonical, workspace) and
            (canonical.len == workspace.len or workspace.len == 1 or canonical[workspace.len] == std.Io.Dir.path.sep))
            return error.RecordInWorkspace;
        var hash: Sha256 = .init(.{});
        if (scope.perWorkspace()) {
            hash.update(workspace);
            hash.update("\x00");
        }
        hash.update(key);
        return .{ .arena = arena, .io = io, .dir = dir, .name = std.fmt.bytesToHex(hash.finalResult(), .lower) };
    }

    fn close(self: *Record) void {
        self.dir.close(self.io);
        self.arena.deinit();
        self.* = undefined;
    }

    /// A link or a special file in the private directory is never read or replaced.
    fn exists(self: *Record) !bool {
        const info = self.dir.statFile(self.io, &self.name, .{ .follow_symlinks = false }) catch |err| switch (err) {
            error.FileNotFound => return false,
            else => return err,
        };
        if (info.kind != .file or info.nlink != 1) return error.InvalidRecord;
        return true;
    }

    fn read(self: *Record) !?[]const u8 {
        if (!try self.exists()) return null;
        return try self.dir.readFileAlloc(self.io, &self.name, self.arena.allocator(), .limited(max_record_bytes));
    }

    /// Replace the whole file, so a reader never sees half a record.
    fn write(self: *Record, text: []const u8) !void {
        std.debug.assert(text.len <= max_record_bytes);
        _ = try self.exists();
        var atomic = try self.dir.createFileAtomic(self.io, &self.name, .{ .permissions = .fromMode(0o600), .replace = true });
        defer atomic.deinit(self.io);
        try atomic.file.setPermissions(self.io, .fromMode(0o600));
        var writer = atomic.file.writer(self.io, &.{});
        try writer.interface.writeAll(text);
        try writer.interface.flush();
        try atomic.replace(self.io);
    }

    fn remove(self: *Record) !void {
        if (try self.exists()) try self.dir.deleteFile(self.io, &self.name);
    }
};

/// Open the record that the scope and key arguments name. A null answer means that a TypeError is pending.
fn openArg(ctx: Context, args: []const Value) ?Record {
    if (args.len < 2) {
        _ = ctx.throwTypeError("an MCP record needs a scope and a key");
        return null;
    }
    const scope_text = module.string(ctx, args[0]) orelse {
        _ = ctx.throwTypeError("the MCP record scope must be a string");
        return null;
    };
    defer ctx.freeCString(scope_text.ptr);
    const scope = std.meta.stringToEnum(Scope, scope_text) orelse {
        _ = ctx.throwTypeError("the MCP record scope is unknown");
        return null;
    };
    const key = module.string(ctx, args[1]) orelse {
        _ = ctx.throwTypeError("the MCP record key must be a string");
        return null;
    };
    defer ctx.freeCString(key.ptr);
    if (key.len == 0) {
        _ = ctx.throwTypeError("the MCP record key must not be empty");
        return null;
    }
    const host = Host.fromContext(ctx);
    return Record.open(host.gpa, host.io, host.execution.env, host.cwd, scope, key) catch {
        _ = ctx.throwTypeError("the private MCP directory is unavailable or inside the workspace");
        return null;
    };
}

/// Answer the record text, or undefined when none exists.
fn jsRead(ctx: Context, _: Value, args: []const Value) Value {
    var record = openArg(ctx, args) orelse return module.throwPending(ctx);
    defer record.close();
    const text = (record.read() catch return ctx.throwTypeError("the MCP record is unreadable")) orelse return quickjs.UNDEFINED;
    return ctx.newString(text);
}

fn jsWrite(ctx: Context, _: Value, args: []const Value) Value {
    if (args.len != 3) return ctx.throwTypeError("an MCP record needs a scope, a key, and a text");
    const text = module.string(ctx, args[2]) orelse return ctx.throwTypeError("the MCP record must be a string");
    defer ctx.freeCString(text.ptr);
    if (text.len > max_record_bytes) return ctx.throwTypeError("the MCP record exceeds 64 KiB");
    var record = openArg(ctx, args) orelse return module.throwPending(ctx);
    defer record.close();
    record.write(text) catch return ctx.throwTypeError("the MCP record could not be saved");
    return quickjs.UNDEFINED;
}

fn jsRemove(ctx: Context, _: Value, args: []const Value) Value {
    var record = openArg(ctx, args) orelse return module.throwPending(ctx);
    defer record.close();
    record.remove() catch return ctx.throwTypeError("the MCP record could not be removed");
    return quickjs.UNDEFINED;
}

test "MCP records are private, named by a digest, and trust binds to one workspace" {
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

    var trust = try Record.open(t.allocator, t.io, &env, cwd, .@"mcp-trust", "server");
    defer trust.close();
    try t.expectEqual(null, try trust.read());
    try trust.write("{\"approved\":true}");
    try t.expectEqualStrings("{\"approved\":true}", (try trust.read()).?);
    const info = try trust.dir.statFile(t.io, &trust.name, .{});
    try t.expectEqual(@as(std.posix.mode_t, 0o600), info.permissions.toMode() & 0o777);
    try t.expectEqual(@as(std.posix.mode_t, 0o700), (try trust.dir.stat(t.io)).permissions.toMode() & 0o777);

    var elsewhere = try Record.open(t.allocator, t.io, &env, other, .@"mcp-trust", "server");
    defer elsewhere.close();
    try t.expectEqual(null, try elsewhere.read());
    var grant = try Record.open(t.allocator, t.io, &env, other, .@"mcp-oauth", "https://mcp.example.com/mcp");
    defer grant.close();
    try t.expect(std.mem.indexOf(u8, &grant.name, "example") == null);
    var same_grant = try Record.open(t.allocator, t.io, &env, cwd, .@"mcp-oauth", "https://mcp.example.com/mcp");
    defer same_grant.close();
    try t.expectEqualSlices(u8, &grant.name, &same_grant.name);

    try trust.dir.symLink(t.io, "elsewhere", &elsewhere.name, .{});
    try t.expectError(error.InvalidRecord, elsewhere.read());
    try trust.remove();
    try t.expectEqual(null, try trust.read());
    try env.put("XDG_DATA_HOME", cwd);
    try t.expectError(error.RecordInWorkspace, Record.open(t.allocator, t.io, &env, cwd, .@"mcp-trust", "server"));
}
