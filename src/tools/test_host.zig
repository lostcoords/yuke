//! A ToolHost for tool tests. It holds one file in memory and records the last write.

const std = @import("std");
const t = @import("tool.zig");

/// A vtable where every op fails. A test starts from this value and replaces the ops it calls.
/// It lives in test support, so production code cannot build a partial vtable by accident.
pub const unsupported: t.ToolHost.VTable = .{
    .readRange = struct {
        fn f(_: *anyopaque, _: std.mem.Allocator, _: []const u8, _: t.Range, _: t.ReadLimits) t.HostError!t.RangeRead {
            return error.HostFailure;
        }
    }.f,
    .readAll = struct {
        fn f(_: *anyopaque, _: std.mem.Allocator, _: []const u8, _: u32) t.HostError![]const u8 {
            return error.HostFailure;
        }
    }.f,
    .writeFile = struct {
        fn f(_: *anyopaque, _: std.mem.Allocator, _: []const u8, _: []const u8) t.HostError!void {
            return error.HostFailure;
        }
    }.f,
    .exec = struct {
        fn f(_: *anyopaque, _: std.mem.Allocator, _: t.ExecSpec) t.HostError!t.ExecResult {
            return error.HostFailure;
        }
    }.f,
};

/// A host over one in-memory file. Set `content` to null to report a missing file. Set `read_error`
/// to make every read fail. `written` holds the last write.
pub const FileHost = struct {
    content: ?[]const u8 = null,
    read_error: ?t.HostError = null,
    written: ?[]const u8 = null,

    const vtable: t.ToolHost.VTable = blk: {
        var v = unsupported;
        v.readAll = readAll;
        v.writeFile = writeFile;
        break :blk v;
    };

    pub fn host(self: *FileHost) t.ToolHost {
        return .{ .ctx = self, .vtable = &vtable };
    }

    fn readAll(ctx: *anyopaque, scratch: std.mem.Allocator, path: []const u8, max_bytes: u32) t.HostError![]const u8 {
        _ = .{ path, max_bytes };
        const self: *FileHost = @ptrCast(@alignCast(ctx));
        if (self.read_error) |err| return err;
        return scratch.dupe(u8, self.content orelse return error.NotFound);
    }

    fn writeFile(ctx: *anyopaque, scratch: std.mem.Allocator, path: []const u8, content: []const u8) t.HostError!void {
        _ = path;
        const self: *FileHost = @ptrCast(@alignCast(ctx));
        self.written = try scratch.dupe(u8, content);
    }
};
