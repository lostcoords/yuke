//! Load the `yuked.json` daemon config. It seeds a new session, and it lists the admitted browser origins.
//! The file holds no secrets. A missing file returns built-in defaults. A `session.create` field overrides a default.

const std = @import("std");

const Allocator = std.mem.Allocator;

/// Limit the file size.
const max_file_bytes = 256 << 10;

/// The daemon defaults. Each string borrows the `Loaded` arena.
pub const Defaults = struct {
    system_prompt: ?[]const u8 = null,
};

// The parser ignores unknown fields for forward compatibility. It rejects duplicate keys.
const FileDoc = struct {
    version: u32,
    system_prompt: ?[]const u8 = null,
    allowed_origins: ?[]const []const u8 = null,
};

/// The arena owns every string. The daemon holds one `Loaded` for its lifetime.
pub const Loaded = struct {
    arena: std.heap.ArenaAllocator,
    defaults: Defaults = .{},
    /// The browser origins that admission accepts beyond the official client.
    allowed_origins: []const []const u8 = &.{},

    pub fn deinit(self: *Loaded) void {
        self.arena.deinit();
        self.* = undefined;
    }
};

/// Read `path` and resolve it. A missing file returns built-in defaults. An invalid file returns an error.
/// `path` must be absolute. The daemon builds it from the config directory.
pub fn load(gpa: Allocator, io: std.Io, path: []const u8) !Loaded {
    const raw = readFile(gpa, io, path) catch |err| switch (err) {
        error.FileNotFound => return empty(gpa),
        else => |e| return e,
    };
    defer gpa.free(raw);
    return loadBytes(gpa, raw);
}

/// Parse one document. The caller owns `bytes`. `alloc_always` copies each value into the arena.
pub fn loadBytes(gpa: Allocator, bytes: []const u8) !Loaded {
    if (bytes.len > max_file_bytes) return error.FileTooLarge;

    var out: Loaded = empty(gpa);
    errdefer out.deinit();
    const arena = out.arena.allocator();

    const doc = try std.json.parseFromSliceLeaky(FileDoc, arena, bytes, .{
        .allocate = .alloc_always,
        .ignore_unknown_fields = true,
        .duplicate_field_behavior = .@"error",
    });

    if (doc.version != 1) return error.BadVersion;
    // The daemon does not validate a model selector. A client validates it before it sends the request.
    out.defaults = .{ .system_prompt = doc.system_prompt };
    if (doc.allowed_origins) |origins| {
        // An origin holds a scheme, a host, and an optional port. A browser never sends more.
        for (origins) |origin| {
            const scheme_end = std.mem.indexOf(u8, origin, "://") orelse return error.BadOrigin;
            const authority = origin[scheme_end + 3 ..];
            if (scheme_end == 0 or authority.len == 0) return error.BadOrigin;
            if (std.mem.indexOfAny(u8, authority, "/?#") != null) return error.BadOrigin;
        }
        out.allowed_origins = origins;
    }
    return out;
}

fn empty(gpa: Allocator) Loaded {
    return .{ .arena = std.heap.ArenaAllocator.init(gpa) };
}

/// Do not follow symlinks. Reject non-regular files. Read the file into a size-limited buffer.
fn readFile(gpa: Allocator, io: std.Io, path: []const u8) ![]u8 {
    const file = try std.Io.Dir.openFileAbsolute(io, path, .{ .follow_symlinks = false });
    defer file.close(io);

    const st = try file.stat(io);
    if (st.kind != .file) return error.NotRegularFile;
    if (st.size > max_file_bytes) return error.FileTooLarge;

    var buf: [4096]u8 = undefined;
    var reader = file.reader(io, &buf);
    return reader.interface.readAlloc(gpa, @intCast(st.size));
}

const testing = std.testing;

test "loadBytes reads the defaults" {
    var loaded = try loadBytes(testing.allocator,
        \\{"version":1,"system_prompt":"be brief"}
    );
    defer loaded.deinit();
    try testing.expectEqualStrings("be brief", loaded.defaults.system_prompt.?);
}

test "loadBytes copies values out of the input" {
    const bytes = try testing.allocator.dupe(u8, "{\"version\":1,\"system_prompt\":\"be brief\"}");
    defer testing.allocator.free(bytes);
    var loaded = try loadBytes(testing.allocator, bytes);
    defer loaded.deinit();
    @memset(bytes, 'x');
    try testing.expectEqualStrings("be brief", loaded.defaults.system_prompt.?);
}

test "loadBytes reads the allowed origins" {
    var loaded = try loadBytes(testing.allocator,
        \\{"version":1,"allowed_origins":["https://a.example","http://localhost:5173"]}
    );
    defer loaded.deinit();
    try testing.expectEqual(@as(usize, 2), loaded.allowed_origins.len);
    try testing.expectEqualStrings("https://a.example", loaded.allowed_origins[0]);
    try testing.expectEqualStrings("http://localhost:5173", loaded.allowed_origins[1]);
}

test "an absent allowed_origins admits the official client alone" {
    var loaded = try loadBytes(testing.allocator,
        \\{"version":1}
    );
    defer loaded.deinit();
    try testing.expectEqual(@as(usize, 0), loaded.allowed_origins.len);
}

test "loadBytes rejects an origin that carries a path or no scheme" {
    try testing.expectError(error.BadOrigin, loadBytes(testing.allocator,
        \\{"version":1,"allowed_origins":["https://a.example/"]}
    ));
    try testing.expectError(error.BadOrigin, loadBytes(testing.allocator,
        \\{"version":1,"allowed_origins":["https://a.example/path"]}
    ));
    try testing.expectError(error.BadOrigin, loadBytes(testing.allocator,
        \\{"version":1,"allowed_origins":["a.example"]}
    ));
    try testing.expectError(error.BadOrigin, loadBytes(testing.allocator,
        \\{"version":1,"allowed_origins":[""]}
    ));
}

test "loadBytes rejects a bad version" {
    try testing.expectError(error.BadVersion, loadBytes(testing.allocator,
        \\{"version":2}
    ));
}

test "loadBytes ignores an unknown field" {
    var loaded = try loadBytes(testing.allocator,
        \\{"version":1,"system_prompt":"go","nope":true}
    );
    defer loaded.deinit();
    try testing.expectEqualStrings("go", loaded.defaults.system_prompt.?);
}

test "loadBytes rejects a duplicate field" {
    try testing.expectError(error.DuplicateField, loadBytes(testing.allocator,
        \\{"version":1,"version":1}
    ));
}
