//! The operation types that the built-in host tools share.
//! `LocalHost` in `local.zig` implements every operation.

/// The file system's native errors map into this closed set, so a tool never sees an OS error code.
pub const HostError = error{
    NotFound,
    NotAFile,
    AccessDenied,
    TooLarge,
    InvalidUtf8,
    HostFailure,
    Canceled,
};

/// A handler adds argument errors and semantic refusals to `HostError`.
/// Each `ToolError` maps to one model-visible sentence.
/// A 1-indexed inclusive line range. A null bound selects the first or the last line.
pub const Range = struct { start: ?u32 = null, end: ?u32 = null };

/// The bounds a range read must respect. These limits bound the read itself. The local host must not
/// load the whole file. `max_bytes` bounds the file text; a caller adds its own numbering on top.
pub const ReadLimits = struct {
    max_lines: u32,
    max_line_bytes: u32,
    max_bytes: u32,
};

/// The result of a bounded range read. `text` holds whole lines, each with a newline. The first line
/// is always `Range.start`, so the caller already knows it.
pub const RangeRead = struct {
    text: []const u8,
    /// The first line the read did NOT return, or null when it reached the range or the file end.
    next_line: ?u32 = null,
    /// The number of lines the local host cut at `max_line_bytes`.
    long_lines: u32 = 0,
};

/// Metadata for one filesystem path. The local host follows a symbolic link.
pub const Stat = struct {
    is_dir: bool,
    /// The last modification time in epoch milliseconds.
    last_modified_ms: u64,
};

/// One entry of a directory page. `name` holds the basename only.
pub const DirItem = struct {
    name: []const u8,
    is_dir: bool,
    /// The local host sets this field only when a directory contains a `.git` entry.
    is_git_repo: bool = false,
};

/// The bounds of one directory page. The local host returns the first `limit` names after `after`.
pub const ListOptions = struct {
    /// Continue after this name. A null value starts at the first name.
    after: ?[]const u8 = null,
    limit: u32,
    /// A false value drops every entry that is not a directory.
    include_files: bool = false,
};

/// One directory page, sorted by name.
pub const DirPage = struct {
    items: []const DirItem,
    /// The name to continue after, or null at the end of the directory.
    next_after: ?[]const u8 = null,
};

/// One command to run. `cwd` is relative to the workspace root. A null `cwd` uses the root itself.
pub const ExecSpec = struct {
    command: []const u8,
    cwd: ?[]const u8 = null,
    timeout_ms: u32,
    /// The cap for each stream. The local host stops the read at this size and reports the cut.
    max_stream_bytes: u32,
};

/// How one command ended. The union makes an impossible pair unrepresentable.
pub const ExecOutcome = union(enum) {
    /// The command ended on its own with this code.
    exited: u8,
    /// A signal ended the command. The value is the signal number.
    signaled: u8,
    /// The deadline expired. The local host killed the process group.
    timed_out,
};

/// What one command produced. `stdout` and `stderr` come from `scratch`.
pub const ExecResult = struct {
    stdout: []const u8,
    stderr: []const u8,
    outcome: ExecOutcome,
    /// The bytes each stream dropped between its head and its tail. Zero means nothing was lost.
    stdout_dropped: u64 = 0,
    stderr_dropped: u64 = 0,
};
