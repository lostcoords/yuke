const std = @import("std");
const quickjs = @import("quickjs");
const utf8 = @import("../utf8.zig");

pub const default_max_file_bytes: usize = 256 * 1024;
/// Only `yuke` and `yuke:*` modules may import a name under this prefix.
const internal_prefix = "yuke:internal/";
pub const host_module_prefix = internal_prefix ++ "host/";

pub const BakedModule = struct {
    name: []const u8,
    code: union(enum) {
        /// QuickJS reads the sentinel byte, so module source must be NUL-terminated.
        source: [:0]const u8,
        /// `tools/jsbake` wrote these bytes from the same QuickJS sources, so the reader trusts them.
        bytecode: []const u8,
    },
};

const ResolveError = error{
    EmptyPath,
    MissingBase,
};

/// True for the public entries and every internal module name.
fn isBaked(name: []const u8) bool {
    return std.mem.eql(u8, name, "yuke") or std.mem.startsWith(u8, name, "yuke:");
}

/// Resolve a module name against `base` and keep baked names; the user owns the config directory, so nothing contains it.
pub fn resolve(
    allocator: std.mem.Allocator,
    base: []const u8,
    name: []const u8,
) ResolveError![]u8 {
    if (name.len == 0) return error.EmptyPath;
    if (isBaked(name)) return allocator.dupe(u8, name) catch @panic("out of memory");
    if (std.Io.Dir.path.isAbsolute(name)) return std.Io.Dir.path.resolve(allocator, &.{name}) catch @panic("out of memory");

    if (base.len == 0) return error.MissingBase;
    if (isBaked(base)) return error.MissingBase;
    const dir = std.Io.Dir.path.dirname(base) orelse return error.MissingBase;
    return std.Io.Dir.path.resolve(allocator, &.{ dir, name }) catch @panic("out of memory");
}

pub const Loader = struct {
    gpa: std.mem.Allocator,
    io: std.Io,
    baked: []const BakedModule,
    max_file_bytes: usize,

    pub fn onNormalize(
        self: *Loader,
        ctx: quickjs.Context,
        base: []const u8,
        name: []const u8,
    ) ?[:0]u8 {
        if (std.mem.startsWith(u8, name, internal_prefix) and !isBaked(base)) {
            _ = ctx.throwReferenceError("internal yuke module: use yuke, yuke:ui, yuke:chat, yuke:session, or yuke:plugins");
            return null;
        }
        if (isBaked(name)) return dupJs(ctx, name);
        const source_base = if (std.mem.startsWith(u8, base, host_module_prefix)) base[host_module_prefix.len..] else base;
        const path = resolve(self.gpa, source_base, name) catch |err| {
            throwLoad(ctx, "cannot resolve module '{s}' from '{s}': {s}", .{ name, base, @errorName(err) });
            return null;
        };
        defer self.gpa.free(path);
        return dupJs(ctx, path);
    }

    // QuickJS reads a null module with no exception as a fault with no text, so every null here throws first.
    pub fn onLoadModule(self: *Loader, ctx: quickjs.Context, name: []const u8) ?quickjs.Context.Module {
        if (isBaked(name)) {
            const module = findBaked(self.baked, name) orelse {
                throwLoad(ctx, "cannot load module '{s}': yuke has no module with this name", .{name});
                return null;
            };
            return switch (module.code) {
                .source => |source| compile(ctx, source, name),
                .bytecode => |bytecode| read(ctx, bytecode),
            };
        }
        const source = self.readModule(name) catch |err| {
            if (err == error.OutOfMemory) {
                _ = ctx.throwOutOfMemory();
                return null;
            }
            var buf: [message_max]u8 = undefined;
            throwLoad(ctx, "{s}", .{self.loadFailure(&buf, name, err)});
            return null;
        };
        defer self.gpa.free(source);
        return compile(ctx, source, name);
    }

    /// Read a module file the caller frees. It fails when the path is relative, the file is absent, too large, or unreadable.
    pub fn readModule(self: *Loader, path: []const u8) ReadError![:0]u8 {
        if (!std.Io.Dir.path.isAbsolute(path)) return error.NotAbsolute;
        var file = try std.Io.Dir.openFileAbsolute(self.io, path, .{});
        defer file.close(self.io);
        // Read to the end instead of to a stat size, so a file that grows cannot yield a prefix.
        var reader = file.readerStreaming(self.io, &.{});
        // The read stops with `StreamTooLong` when it reaches the limit, so one byte past the maximum marks a file that is too large.
        const limit: std.Io.Limit = .limited(self.max_file_bytes + 1);
        return reader.interface.allocRemainingAlignedSentinel(self.gpa, limit, .of(u8), 0) catch |err| switch (err) {
            error.StreamTooLong => error.FileTooLarge,
            else => |e| e,
        };
    }

    /// Write why `path` does not load into `buf`, and return the text. The text names the file and the reason.
    /// The caller handles `OutOfMemory` itself, because a resource failure is not a module fault.
    pub fn loadFailure(self: *const Loader, buf: []u8, path: []const u8, err: ReadError) []const u8 {
        std.debug.assert(err != error.OutOfMemory);
        return switch (err) {
            error.FileNotFound => printCut(buf, "cannot load module '{s}': the file does not exist", .{path}),
            error.FileTooLarge => printCut(buf, "cannot load module '{s}': the file is larger than {d} bytes", .{ path, self.max_file_bytes }),
            else => printCut(buf, "cannot load module '{s}': {s}", .{ path, @errorName(err) }),
        };
    }
};

/// The reasons a module file does not load.
pub const ReadError = std.Io.File.OpenError || std.Io.Reader.ShortError || error{ OutOfMemory, FileTooLarge, NotAbsolute };

/// The space for one load failure text: a path of the maximum length and its reason. A longer text is cut.
pub const message_max = std.Io.Dir.max_path_bytes + 128;

/// Format into `buf` and keep the part that fits. The cut falls on a UTF-8 boundary, so the text stays valid.
fn printCut(buf: []u8, comptime fmt: []const u8, args: anytype) []const u8 {
    var writer: std.Io.Writer = .fixed(buf);
    writer.print(fmt, args) catch {};
    const text = writer.buffered();
    return text[0..utf8.floor(text, text.len)];
}

/// Throw a `ReferenceError` like the default QuickJS loader. QuickJS reads the text as a printf format, so each `%` doubles.
fn throwLoad(ctx: quickjs.Context, comptime fmt: []const u8, args: anytype) void {
    var text: [message_max]u8 = undefined;
    const message = printCut(&text, fmt, args);
    var escaped: [message_max * 2 + 1]u8 = undefined;
    var n: usize = 0;
    for (message) |byte| {
        escaped[n] = byte;
        n += 1;
        if (byte == '%') {
            escaped[n] = '%';
            n += 1;
        }
    }
    escaped[n] = 0;
    _ = ctx.throwReferenceError(escaped[0..n :0]);
}

fn findBaked(baked: []const BakedModule, name: []const u8) ?BakedModule {
    for (baked) |m| {
        if (std.mem.eql(u8, m.name, name)) return m;
    }
    return null;
}

fn read(ctx: quickjs.Context, bytecode: []const u8) ?quickjs.Context.Module {
    const val = ctx.readObject(bytecode, .{ .bytecode = true });
    if (ctx.isException(val)) return null;
    return ctx.moduleFromValue(val);
}

fn compile(ctx: quickjs.Context, source: [:0]const u8, name: []const u8) ?quickjs.Context.Module {
    var name_z: [std.Io.Dir.max_path_bytes]u8 = undefined;
    if (name.len >= name_z.len) {
        throwLoad(ctx, "cannot load module '{s}': the path is too long", .{name});
        return null;
    }
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

test "a module file over the size limit does not load" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "fits.js", .data = "12345678" });
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "big.js", .data = "123456789" });
    var root_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const root = root_buf[0..try tmp.dir.realPath(std.testing.io, &root_buf)];
    var loader: Loader = .{ .gpa = std.testing.allocator, .io = std.testing.io, .baked = &.{}, .max_file_bytes = 8 };

    var path_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const fits = try loader.readModule(try std.fmt.bufPrint(&path_buf, "{s}/fits.js", .{root}));
    defer std.testing.allocator.free(fits);
    try std.testing.expectEqualStrings("12345678", fits);
    try std.testing.expectError(error.FileTooLarge, loader.readModule(try std.fmt.bufPrint(&path_buf, "{s}/big.js", .{root})));
}

test "resolve keeps yuke names and rejects a relative name with no base" {
    const gpa = std.testing.allocator;
    const a = try resolve(gpa, "", "yuke:internal/core");
    defer gpa.free(a);
    try std.testing.expectEqualStrings("yuke:internal/core", a);

    try std.testing.expectError(error.EmptyPath, resolve(gpa, "/cfg/a.js", ""));
    try std.testing.expectError(error.MissingBase, resolve(gpa, "", "./b.js"));
    try std.testing.expectError(error.MissingBase, resolve(gpa, "yuke:internal/core", "./b.js"));
    try std.testing.expectError(error.MissingBase, resolve(gpa, "yuke", "./b.js"));
}

test "the facade name is reserved and never reaches the config directory" {
    const gpa = std.testing.allocator;
    // A file named `yuke.js` beside `index.js` must not shadow the public facade.
    const bare = try resolve(gpa, "/cfg/index.js", "yuke");
    defer gpa.free(bare);
    try std.testing.expectEqualStrings("yuke", bare);

    for ([_][]const u8{ "yuke:ui", "yuke:chat", "yuke:session", "yuke:plugins", "yuke:unknown" }) |name| {
        const public = try resolve(gpa, "/cfg/index.js", name);
        defer gpa.free(public);
        try std.testing.expectEqualStrings(name, public);
        try std.testing.expectError(error.MissingBase, resolve(gpa, name, "./other.js"));
    }

    // A longer name that only starts with the facade name stays an ordinary relative import.
    const other = try resolve(gpa, "/cfg/index.js", "yukebox");
    defer gpa.free(other);
    const expected = try std.Io.Dir.path.resolve(gpa, &.{ "/cfg", "yukebox" });
    defer gpa.free(expected);
    try std.testing.expectEqualStrings(expected, other);
}

test "resolve joins a relative import, leaves the config directory, and keeps an absolute path" {
    const gpa = std.testing.allocator;
    for ([_]struct { base: []const u8, name: []const u8, want: []const []const u8 }{
        .{ .base = "/cfg/a.js", .name = "./b.js", .want = &.{ "/cfg", "b.js" } },
        .{ .base = "/cfg/a.js", .name = "../sibling/b.js", .want = &.{ "/sibling", "b.js" } },
        .{ .base = "", .name = "/other/x.js", .want = &.{"/other/x.js"} },
    }) |case| {
        errdefer std.debug.print("case: {s} + {s}\n", .{ case.base, case.name });
        const got = try resolve(gpa, case.base, case.name);
        defer gpa.free(got);
        const want = try std.Io.Dir.path.resolve(gpa, case.want);
        defer gpa.free(want);
        try std.testing.expectEqualStrings(want, got);
    }
}
