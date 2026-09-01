const std = @import("std");
const quickjs = @import("quickjs");

pub const default_max_file_bytes: usize = 256 * 1024;

pub const BakedModule = struct {
    name: []const u8,
    /// QuickJS reads the sentinel byte, so module source must be NUL-terminated.
    source: [:0]const u8,
};

pub const ResolveError = error{
    EmptyPath,
    MissingBase,
    OutOfMemory,
};

/// Resolve a module name against `base` and keep `yuke:` names; the user owns the config directory, so nothing contains it.
pub fn resolve(
    allocator: std.mem.Allocator,
    base: []const u8,
    name: []const u8,
) ResolveError![]u8 {
    if (name.len == 0) return error.EmptyPath;
    if (std.mem.startsWith(u8, name, "yuke:")) return allocator.dupe(u8, name);
    if (std.fs.path.isAbsolute(name)) return std.fs.path.resolve(allocator, &.{name});

    if (base.len == 0) return error.MissingBase;
    if (std.mem.startsWith(u8, base, "yuke:")) return error.MissingBase;
    const dir = std.fs.path.dirname(base) orelse return error.MissingBase;
    return std.fs.path.resolve(allocator, &.{ dir, name });
}

pub const Loader = struct {
    gpa: std.mem.Allocator,
    io: std.Io,
    baked: []const BakedModule,
    max_file_bytes: usize,

    pub fn deinit(self: *Loader) void {
        self.* = undefined;
    }

    pub fn onNormalize(
        self: *Loader,
        ctx: quickjs.Context,
        base: []const u8,
        name: []const u8,
    ) ?[:0]u8 {
        const path = resolve(self.gpa, base, name) catch return null;
        defer self.gpa.free(path);
        return dupJs(ctx, path);
    }

    /// QuickJS wants null for every failure, so an out-of-memory result also reads as null here.
    pub fn onLoadModule(self: *Loader, ctx: quickjs.Context, name: []const u8) ?quickjs.Context.Module {
        if (std.mem.startsWith(u8, name, "yuke:")) {
            const source = findBaked(self.baked, name) orelse return null;
            return compile(ctx, source, name);
        }
        const source = (self.readModule(name) catch null) orelse return null;
        defer self.gpa.free(source);
        return compile(ctx, source, name);
    }

    /// Read a module file the caller frees, or null when it is absent, too large, or unreadable.
    pub fn readModule(self: *Loader, path: []const u8) error{OutOfMemory}!?[:0]u8 {
        if (!std.fs.path.isAbsolute(path)) return null;
        var file = std.Io.Dir.openFileAbsolute(self.io, path, .{}) catch return null;
        defer file.close(self.io);
        // Read to the end instead of to a stat size, so a file that grows cannot yield a prefix.
        var reader = file.readerStreaming(self.io, &.{});
        const limit: std.Io.Limit = .limited(self.max_file_bytes + 1);
        const buf = reader.interface.allocRemainingAlignedSentinel(self.gpa, limit, .of(u8), 0) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            else => return null,
        };
        if (buf.len > self.max_file_bytes) {
            self.gpa.free(buf);
            return null;
        }
        return buf;
    }
};

fn findBaked(baked: []const BakedModule, name: []const u8) ?[:0]const u8 {
    for (baked) |m| {
        if (std.mem.eql(u8, m.name, name)) return m.source;
    }
    return null;
}

fn compile(ctx: quickjs.Context, source: [:0]const u8, name: []const u8) ?quickjs.Context.Module {
    var name_z: [std.fs.max_path_bytes]u8 = undefined;
    if (name.len >= name_z.len) return null;
    @memcpy(name_z[0..name.len], name);
    name_z[name.len] = 0;
    const filename: [:0]const u8 = name_z[0..name.len :0];
    const val = ctx.eval(source, filename, .{ .type = .module, .compile_only = true }) catch return null;
    return ctx.moduleFromValue(val);
}

fn dupJs(ctx: quickjs.Context, s: []const u8) ?[:0]u8 {
    const ptr = ctx.strndup(s, s.len) orelse return null;
    return std.mem.span(ptr);
}

test "resolve keeps yuke names and rejects a relative name with no base" {
    const gpa = std.testing.allocator;
    const a = try resolve(gpa, "", "yuke:core");
    defer gpa.free(a);
    try std.testing.expectEqualStrings("yuke:core", a);

    try std.testing.expectError(error.EmptyPath, resolve(gpa, "/cfg/a.js", ""));
    try std.testing.expectError(error.MissingBase, resolve(gpa, "", "./b.js"));
    try std.testing.expectError(error.MissingBase, resolve(gpa, "yuke:core", "./b.js"));
}

test "resolve joins a relative import against the importing file" {
    const gpa = std.testing.allocator;
    const inside = try resolve(gpa, "/cfg/a.js", "./b.js");
    defer gpa.free(inside);
    const expected = try std.fs.path.resolve(gpa, &.{ "/cfg", "b.js" });
    defer gpa.free(expected);
    try std.testing.expectEqualStrings(expected, inside);
}

test "resolve leaves the config directory when the user asks for it" {
    const gpa = std.testing.allocator;
    const up = try resolve(gpa, "/cfg/a.js", "../sibling/b.js");
    defer gpa.free(up);
    const expected = try std.fs.path.resolve(gpa, &.{ "/sibling", "b.js" });
    defer gpa.free(expected);
    try std.testing.expectEqualStrings(expected, up);

    const abs = try resolve(gpa, "", "/other/x.js");
    defer gpa.free(abs);
    const expected_abs = try std.fs.path.resolve(gpa, &.{"/other/x.js"});
    defer gpa.free(expected_abs);
    try std.testing.expectEqualStrings(expected_abs, abs);
}
