//! Workspace directories, browsing, and skill discovery.

const std = @import("std");
const ids = @import("ids.zig");
const enums = @import("enums.zig");

/// A single filesystem entry in a browse listing.
pub const DirEntry = struct {
    name: []const u8,
    path: []const u8,
    /// Whether this directory is itself a git repo.
    is_git_repo: bool,
};

/// Git status for a workspace root, when it is a repo.
pub const GitInfo = struct {
    branch: []const u8,
    /// Whether the working tree has uncommitted changes.
    dirty: bool,
};

/// Discovered skill metadata.
pub const SkillInfo = struct {
    name: []const u8,
    description: []const u8,
    /// Project- or personal-scoped.
    scope: enums.SkillScope,
    argument_hint: []const u8,
};

/// A named skill invocation with its rendered arguments.
pub const SkillRef = struct {
    name: []const u8,
    arguments: []const u8,
};

/// Daemon-known workspace directory.
pub const Workspace = struct {
    /// Derived workspace id.
    id: ids.WorkspaceId,
    /// Canonical absolute path.
    root: []const u8,
    /// Display title.
    title: []const u8,
};

/// workspace.browse input.
pub const WorkspaceBrowseParams = struct {
    path: ?[]const u8 = null,
    /// Page size; omitted means daemon default.
    limit: ?u64 = null,
    /// Opaque continuation within the same directory.
    cursor: ?[]const u8 = null,
};

/// workspace.browse result.
pub const WorkspaceBrowseResult = struct {
    path: []const u8,
    /// Parent directory path; null at the filesystem root.
    parent: ?[]const u8 = null,
    /// Directory contents.
    entries: []const DirEntry,
    /// Opaque continuation; required null on the final page.
    next_cursor: ?[]const u8 = null,
};

/// Payload for `workspace.created`.
pub const WorkspaceCreatedData = struct {
    /// The newly known workspace.
    workspace: Workspace,
};

/// workspace.describe input.
pub const WorkspaceDescribeParams = struct {
    path: []const u8,
};

/// workspace.describe result.
pub const WorkspaceDescribeResult = struct {
    /// Resolved workspace.
    workspace: Workspace,
    /// Git status; null when the root is not a repo.
    git: ?GitInfo = null,
    /// Last filesystem modification epoch ms.
    last_modified_ms: u64,
    /// Last model used in this workspace; null if never run.
    last_used_model: ?[]const u8 = null,
};

/// Params naming a workspace and nothing else.
pub const WorkspaceRef = struct {
    /// Workspace the request targets.
    workspace_id: ids.WorkspaceId,
};

/// workspace.remove result.
pub const WorkspaceRemoveResult = struct {
    /// Cron jobs that referenced the removed workspace.
    related_job_ids: []const ids.JobId,
};

/// Payload for `workspace.removed`.
pub const WorkspaceRemovedData = struct {
    /// Id of the removed workspace.
    workspace_id: ids.WorkspaceId,
};

/// workspace.skills.list result.
pub const WorkspaceSkillsResult = struct {
    /// Discovered skills.
    skills: []const SkillInfo,
};

const testing = std.testing;
const opts: std.json.ParseOptions = .{ .ignore_unknown_fields = true };

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
