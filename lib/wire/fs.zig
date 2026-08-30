//! Filesystem reads for the workspace picker. Each method takes a path, not a workspace id.

const std = @import("std");

/// This entry identifies one item in a browse page.
pub const DirEntry = struct {
    name: []const u8,
    path: []const u8,
    is_dir: bool,
    /// This field says whether this directory is a Git repository.
    is_git_repo: bool,
};

/// This type records Git state for a repository directory.
pub const GitInfo = struct {
    /// The current branch. Null means a detached HEAD.
    branch: ?[]const u8 = null,
};

/// These are the parameters for `fs.browse`.
pub const FsBrowseParams = struct {
    /// The directory to list. A null path selects the daemon home directory.
    path: ?[]const u8 = null,
    /// The daemon uses its default page size when this field is absent.
    limit: ?u64 = null,
    /// An opaque cursor for continuation within the same directory.
    cursor: ?[]const u8 = null,
    /// A false value lists directories only.
    include_files: bool = false,
};

/// This result contains one browse page.
pub const FsBrowseResult = struct {
    path: []const u8,
    /// The daemon sets this field to null at the filesystem root.
    parent: ?[]const u8 = null,
    /// The entries of this page, directories first, then each name in order.
    entries: []const DirEntry,
    /// An opaque continuation cursor; null on the final page.
    next_cursor: ?[]const u8 = null,
};

/// These are the parameters for `fs.stat`.
pub const FsStatParams = struct {
    path: []const u8,
};

/// This type describes one filesystem item. A symbolic link reports its target.
pub const FsEntry = struct {
    is_dir: bool,
    /// The last modification time in epoch milliseconds.
    last_modified_ms: u64,
    /// The daemon sets this field only for a Git repository.
    git: ?GitInfo = null,
};

/// This result describes one path. A null `entry` means the path does not exist.
pub const FsStatResult = struct {
    /// The absolute path that the daemon resolved.
    path: []const u8,
    entry: ?FsEntry = null,
};

const testing = std.testing;
const opts: std.json.ParseOptions = .{ .ignore_unknown_fields = true };

test "browse params round-trips with optional fields" {
    const json =
        \\{"path":"/home/x","limit":50}
    ;
    const parsed = try std.json.parseFromSlice(FsBrowseParams, testing.allocator, json, opts);
    defer parsed.deinit();
    try testing.expectEqualStrings("/home/x", parsed.value.path.?);
    try testing.expectEqual(@as(?u64, 50), parsed.value.limit);
    try testing.expect(parsed.value.cursor == null);
    try testing.expect(!parsed.value.include_files); // A picker asks for directories by default.
}

test "browse result round-trips with entries slice" {
    const json =
        \\{"path":"/a","parent":null,"entries":[{"name":"b","path":"/a/b","is_dir":true,"is_git_repo":true},
        \\{"name":"c.txt","path":"/a/c.txt","is_dir":false,"is_git_repo":false}],"next_cursor":null}
    ;
    const parsed = try std.json.parseFromSlice(FsBrowseResult, testing.allocator, json, opts);
    defer parsed.deinit();
    try testing.expect(parsed.value.parent == null);
    try testing.expectEqual(@as(usize, 2), parsed.value.entries.len);
    try testing.expectEqualStrings("b", parsed.value.entries[0].name);
    try testing.expect(parsed.value.entries[0].is_dir and parsed.value.entries[0].is_git_repo);
    try testing.expect(!parsed.value.entries[1].is_dir and !parsed.value.entries[1].is_git_repo);
    try testing.expect(parsed.value.next_cursor == null);
}

test "stat omits the entry for a path that does not exist" {
    var buf: std.Io.Writer.Allocating = .init(testing.allocator);
    defer buf.deinit();
    const result: FsStatResult = .{ .path = "/gone" };
    try std.json.Stringify.value(result, .{ .emit_null_optional_fields = false }, &buf.writer);
    try testing.expectEqualStrings(
        \\{"path":"/gone"}
    , buf.written());
}

test "stat reports a repository branch and omits a detached head" {
    const json =
        \\{"path":"/a","entry":{"is_dir":true,"last_modified_ms":7,"git":{"branch":"main"}}}
    ;
    const parsed = try std.json.parseFromSlice(FsStatResult, testing.allocator, json, opts);
    defer parsed.deinit();
    try testing.expect(parsed.value.entry.?.is_dir);
    try testing.expectEqual(@as(u64, 7), parsed.value.entry.?.last_modified_ms);
    try testing.expectEqualStrings("main", parsed.value.entry.?.git.?.branch.?);

    const detached =
        \\{"path":"/a","entry":{"is_dir":true,"last_modified_ms":7,"git":{}}}
    ;
    const head = try std.json.parseFromSlice(FsStatResult, testing.allocator, detached, opts);
    defer head.deinit();
    try testing.expect(head.value.entry.?.git.?.branch == null);
}
