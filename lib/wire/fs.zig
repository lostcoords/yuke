//! Filesystem reads for the workspace picker. Each method takes a path, not a workspace id.

const std = @import("std");

/// One directory entry in a browse page.
pub const DirEntry = struct {
    name: []const u8,
    path: []const u8,
    is_dir: bool,
    /// True when this directory contains a `.git` entry.
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
    /// The entries of this page in name order.
    entries: []const DirEntry,
    /// An opaque continuation cursor; null on the final page.
    next_cursor: ?[]const u8 = null,
};

/// These are the parameters for `fs.stat`.
pub const FsStatParams = struct {
    path: []const u8,
};

/// Metadata for one filesystem path. A symbolic link reports its target.
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
