//! Workspace directories, directory access, and skill discovery.

const std = @import("std");
const ids = @import("ids.zig");
const enums = @import("enums.zig");

/// This entry identifies one filesystem item in a browse result.
pub const DirEntry = struct {
    name: []const u8,
    path: []const u8,
    /// This field says whether this directory is a Git repository.
    is_git_repo: bool,
};

/// This type records Git status for a workspace root when it is a repository.
pub const GitInfo = struct {
    branch: []const u8,
    /// This field says whether the working tree has uncommitted changes.
    dirty: bool,
};

/// This type records discovered skill metadata.
pub const SkillInfo = struct {
    name: []const u8,
    description: []const u8,
    /// This scope identifies a project or personal skill.
    scope: enums.SkillScope,
    argument_hint: []const u8,
};

/// This type names a skill and holds its rendered arguments.
pub const SkillRef = struct {
    name: []const u8,
    arguments: []const u8,
};

/// This type describes a workspace known to the daemon.
pub const Workspace = struct {
    /// The daemon creates this opaque workspace ID.
    id: ids.WorkspaceId,
    /// The daemon supports only the local workspace kind at present.
    kind: enums.WorkspaceKind = .local,
    /// The canonical absolute path of the local root.
    root: []const u8,
    /// The display title.
    title: []const u8,
};

/// These are the parameters for `workspace.browse`.
pub const WorkspaceBrowseParams = struct {
    path: ?[]const u8 = null,
    /// The daemon uses its default page size when this field is absent.
    limit: ?u64 = null,
    /// An opaque cursor for continuation within the same directory.
    cursor: ?[]const u8 = null,
};

/// This result contains one browse page.
pub const WorkspaceBrowseResult = struct {
    path: []const u8,
    /// The daemon sets this field to null at the filesystem root.
    parent: ?[]const u8 = null,
    /// The directory contents.
    entries: []const DirEntry,
    /// An opaque continuation cursor; null on the final page.
    next_cursor: ?[]const u8 = null,
};

/// This payload describes `workspace.created`.
pub const WorkspaceCreatedData = struct {
    /// The newly known workspace.
    workspace: Workspace,
};

/// These are the parameters for `workspace.describe`.
pub const WorkspaceDescribeParams = struct {
    path: []const u8,
};

/// This result describes `workspace.describe`.
pub const WorkspaceDescribeResult = struct {
    /// The resolved workspace.
    workspace: Workspace,
    /// The daemon sets this field to null when the root is not a repository.
    git: ?GitInfo = null,
    /// The last filesystem modification time in epoch milliseconds.
    last_modified_ms: u64,
    /// The last model used in this workspace. The daemon leaves it null before the first run.
    last_used_model: ?[]const u8 = null,
};

/// These parameters name a workspace and nothing else.
pub const WorkspaceRef = struct {
    /// This field identifies the workspace that the request targets.
    workspace_id: ids.WorkspaceId,
};

/// Result of `workspace.remove`.
pub const WorkspaceRemoveResult = struct {};

/// This payload describes `workspace.removed`.
pub const WorkspaceRemovedData = struct {
    /// This field identifies the removed workspace.
    workspace_id: ids.WorkspaceId,
};

/// This result lists discovered skills.
pub const WorkspaceSkillsResult = struct {
    /// This field lists discovered skills.
    skills: []const SkillInfo,
};

const testing = std.testing;
const opts: std.json.ParseOptions = .{ .ignore_unknown_fields = true };

test "workspace defaults to local kind and emits it" {
    const json =
        \\{"id":"0123456789abcdef0123456789abcdef","root":"/home/x","title":"x"}
    ;
    const parsed = try std.json.parseFromSlice(Workspace, testing.allocator, json, opts);
    defer parsed.deinit();
    try testing.expectEqual(enums.WorkspaceKind.local, parsed.value.kind);

    var buf: std.Io.Writer.Allocating = .init(testing.allocator);
    defer buf.deinit();
    try std.json.Stringify.value(parsed.value, .{}, &buf.writer);
    try testing.expectEqualStrings(
        \\{"id":"0123456789abcdef0123456789abcdef","kind":"local","root":"/home/x","title":"x"}
    , buf.written());
}

test "workspace rejects unknown kind" {
    const json =
        \\{"id":"0123456789abcdef0123456789abcdef","kind":"vm","root":"/home/x","title":"x"}
    ;
    try testing.expectError(error.InvalidEnumTag, std.json.parseFromSlice(Workspace, testing.allocator, json, opts));
}

test "workspace browse params round-trips with optional fields" {
    const json =
        \\{"path":"/home/x","limit":50}
    ;
    const parsed = try std.json.parseFromSlice(WorkspaceBrowseParams, testing.allocator, json, opts);
    defer parsed.deinit();
    try testing.expectEqualStrings("/home/x", parsed.value.path.?);
    try testing.expectEqual(@as(?u64, 50), parsed.value.limit);
    try testing.expect(parsed.value.cursor == null);
}

test "workspace browse result round-trips with entries slice" {
    const json =
        \\{"path":"/a","parent":null,"entries":[{"name":"b","path":"/a/b","is_git_repo":false}],"next_cursor":null}
    ;
    const parsed = try std.json.parseFromSlice(WorkspaceBrowseResult, testing.allocator, json, opts);
    defer parsed.deinit();
    try testing.expect(parsed.value.parent == null);
    try testing.expectEqual(@as(usize, 1), parsed.value.entries.len);
    try testing.expectEqualStrings("b", parsed.value.entries[0].name);
    try testing.expect(parsed.value.entries[0].is_git_repo == false);
    try testing.expect(parsed.value.next_cursor == null);
}
