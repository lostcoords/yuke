//! The test doubles for the ToolHost. Each double serves one seam and records the request.

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

/// A host over one bounded range read. It returns a fixed result and records the request.
pub const RangeHost = struct {
    result: t.RangeRead,
    seen: ?t.Range = null,
    seen_limits: ?t.ReadLimits = null,

    const vtable: t.ToolHost.VTable = blk: {
        var v = unsupported;
        v.readRange = readRange;
        break :blk v;
    };

    pub fn host(self: *RangeHost) t.ToolHost {
        return .{ .ctx = self, .vtable = &vtable };
    }

    fn readRange(ctx: *anyopaque, scratch: std.mem.Allocator, path: []const u8, range: t.Range, lim: t.ReadLimits) t.HostError!t.RangeRead {
        _ = path;
        const self: *RangeHost = @ptrCast(@alignCast(ctx));
        self.seen = range;
        self.seen_limits = lim;
        // The real backend returns text that borrows `scratch`, so the double must do the same.
        var copy = self.result;
        copy.text = try scratch.dupe(u8, self.result.text);
        return copy;
    }
};

/// A host over one command. It returns a fixed result and records the request.
pub const ExecHost = struct {
    result: t.ExecResult,
    seen: ?t.ExecSpec = null,

    const vtable: t.ToolHost.VTable = blk: {
        var v = unsupported;
        v.exec = run;
        break :blk v;
    };

    pub fn host(self: *ExecHost) t.ToolHost {
        return .{ .ctx = self, .vtable = &vtable };
    }

    fn run(ctx: *anyopaque, scratch: std.mem.Allocator, spec: t.ExecSpec) t.HostError!t.ExecResult {
        _ = scratch;
        const self: *ExecHost = @ptrCast(@alignCast(ctx));
        self.seen = spec;
        return self.result;
    }
};
