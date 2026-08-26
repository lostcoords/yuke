const std = @import("std");
const quickjs = @import("quickjs");

pub const default_max_file_bytes: usize = 256 * 1024;

pub const BakedModule = struct {
    name: []const u8,
    source: []const u8,
};

pub const ResolveError = error{
    EmptyPath,
    MissingBase,
    NotContained,
    OutOfMemory,
};

/// Return true when `path` is `root` or a child. Reject prefix siblings.
pub fn contained(root: []const u8, path: []const u8) bool {
    const r = stripTrailingSep(root);
    const p = stripTrailingSep(path);
    if (r.len == 0) return false;
    if (r.len == 1 and std.fs.path.isSep(r[0]))
        return p.len > 0 and std.fs.path.isAbsolute(p);
    if (std.mem.eql(u8, r, p)) return true;
    if (p.len <= r.len) return false;
    if (!std.mem.startsWith(u8, p, r)) return false;
    return std.fs.path.isSep(p[r.len]);
}

/// Resolve a module name against `base`. Keep `yuke:` names unchanged.
pub fn resolve(
    allocator: std.mem.Allocator,
    config_root: []const u8,
    base: []const u8,
    name: []const u8,
) ResolveError![]u8 {
    if (name.len == 0) return error.EmptyPath;
    if (std.mem.startsWith(u8, name, "yuke:")) return allocator.dupe(u8, name);

    if (std.fs.path.isAbsolute(name)) {
        const path = try std.fs.path.resolve(allocator, &.{name});
        errdefer allocator.free(path);
        if (!contained(config_root, path)) return error.NotContained;
        return path;
    }

    if (base.len == 0) return error.MissingBase;
    if (std.mem.startsWith(u8, base, "yuke:")) return error.MissingBase;
    const dir = std.fs.path.dirname(base) orelse return error.MissingBase;
    const path = try std.fs.path.resolve(allocator, &.{ dir, name });
    errdefer allocator.free(path);
    if (!contained(config_root, path)) return error.NotContained;
    return path;
}

pub const Loader = struct {
    gpa: std.mem.Allocator,
    io: std.Io,
    config_root: []u8,
    baked: []const BakedModule,
    max_file_bytes: usize,

    pub fn init(
        gpa: std.mem.Allocator,
        io: std.Io,
        config_root: []const u8,
        baked: []const BakedModule,
        max_file_bytes: usize,
    ) error{ OutOfMemory, NotAbsolute }!Loader {
        const stripped = stripTrailingSep(config_root);
        const root = if (stripped.len == 0)
            try gpa.dupe(u8, "")
        else blk: {
            if (!std.fs.path.isAbsolute(stripped)) return error.NotAbsolute;
            break :blk try std.fs.path.resolve(gpa, &.{stripped});
        };
        return .{
            .gpa = gpa,
            .io = io,
            .config_root = root,
            .baked = baked,
            .max_file_bytes = max_file_bytes,
        };
    }

    pub fn deinit(self: *Loader) void {
        self.gpa.free(self.config_root);
        self.* = undefined;
    }

    pub fn onNormalize(
        self: *Loader,
        ctx: quickjs.Context,
        base: []const u8,
        name: []const u8,
    ) ?[:0]u8 {
        const path = resolve(self.gpa, self.config_root, base, name) catch return null;
        defer self.gpa.free(path);
        return dupJs(ctx, path);
    }

    pub fn onLoadModule(self: *Loader, ctx: quickjs.Context, name: []const u8) ?quickjs.Context.Module {
        if (std.mem.startsWith(u8, name, "yuke:")) {
            const source = findBaked(self.baked, name) orelse return null;
            return compile(ctx, source, name);
        }
        if (!contained(self.config_root, name)) return null;
        const source = self.readFile(name) orelse return null;
        defer self.gpa.free(source);
        return compile(ctx, source, name);
    }

    fn readFile(self: *Loader, path: []const u8) ?[]u8 {
        if (!std.fs.path.isAbsolute(path)) return null;
        var file = std.Io.Dir.openFileAbsolute(self.io, path, .{}) catch return null;
        defer file.close(self.io);
        const st = file.stat(self.io) catch return null;
        if (st.size > self.max_file_bytes) return null;
        const size: usize = @intCast(st.size);
        const buf = self.gpa.alloc(u8, size) catch return null;
        var reader = file.readerStreaming(self.io, &.{});
        reader.interface.readSliceAll(buf) catch {
            self.gpa.free(buf);
            return null;
        };
        return buf;
    }
};

fn findBaked(baked: []const BakedModule, name: []const u8) ?[]const u8 {
    for (baked) |m| {
        if (std.mem.eql(u8, m.name, name)) return m.source;
    }
    return null;
}

fn compile(ctx: quickjs.Context, source: []const u8, name: []const u8) ?quickjs.Context.Module {
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

fn stripTrailingSep(p: []const u8) []const u8 {
    var end = p.len;
    while (end > 1 and std.fs.path.isSep(p[end - 1])) end -= 1;
    return p[0..end];
}

test "contained rejects a prefix sibling" {
    try std.testing.expect(contained("/config", "/config"));
    try std.testing.expect(contained("/config", "/config/a.js"));
    try std.testing.expect(contained("/config/", "/config/a.js"));
    try std.testing.expect(!contained("/config", "/config-other"));
    try std.testing.expect(!contained("/config", "/config-other/a.js"));
    try std.testing.expect(!contained("/config", "/etc/passwd"));
    try std.testing.expect(!contained("", "/config/a.js"));
    try std.testing.expect(contained("/", "/a.js"));
}

test "resolve keeps yuke names and rejects a relative name with no base" {
    const gpa = std.testing.allocator;
    const a = try resolve(gpa, "/cfg", "", "yuke:core");
    defer gpa.free(a);
    try std.testing.expectEqualStrings("yuke:core", a);

    try std.testing.expectError(error.EmptyPath, resolve(gpa, "/cfg", "/cfg/a.js", ""));
    try std.testing.expectError(error.MissingBase, resolve(gpa, "/cfg", "", "./b.js"));
    try std.testing.expectError(error.MissingBase, resolve(gpa, "/cfg", "yuke:core", "./b.js"));
}

test "resolve joins a relative import and drops a path that leaves the root" {
    const gpa = std.testing.allocator;
    const inside = try resolve(gpa, "/cfg", "/cfg/a.js", "./b.js");
    defer gpa.free(inside);
    const expected = try std.fs.path.resolve(gpa, &.{ "/cfg", "b.js" });
    defer gpa.free(expected);
    try std.testing.expectEqualStrings(expected, inside);

    try std.testing.expectError(error.NotContained, resolve(gpa, "/cfg", "/cfg/a.js", "../secret.js"));
    try std.testing.expectError(error.NotContained, resolve(gpa, "/cfg", "", "/cfg-other/x.js"));
}
