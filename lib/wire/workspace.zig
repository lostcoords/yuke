//! Workspace directories and skill discovery. Every method here takes a workspace id.

const std = @import("std");
const ids = @import("ids.zig");
const enums = @import("enums.zig");

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

/// This payload describes `workspace.created`.
pub const WorkspaceCreatedData = struct {
    /// The newly known workspace.
    workspace: Workspace,
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
