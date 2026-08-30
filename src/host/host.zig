//! The primitives that run where a workspace lives. A backend runs them local or in a container.

const std = @import("std");

/// Backends map their native errors into this closed set. No backend-specific error reaches the
/// tool engine.
pub const HostError = error{
    NotFound,
    NotAFile,
    AccessDenied,
    TooLarge,
    InvalidUtf8,
    HostFailure,
    Canceled,
    OutOfMemory,
};

/// A handler adds argument errors and semantic refusals to `HostError`.
/// Each `ToolError` maps to one model-visible sentence.
/// A 1-indexed inclusive line range. A null bound selects the first or the last line.
pub const Range = struct { start: ?u32 = null, end: ?u32 = null };

/// The bounds a range read must respect. These limits bound the read itself. The backend must not
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
    /// The number of lines the backend cut at `max_line_bytes`.
    long_lines: u32 = 0,
};

/// One command to run. `cwd` is relative to the workspace root. A null `cwd` uses the root itself.
pub const ExecSpec = struct {
    command: []const u8,
    cwd: ?[]const u8 = null,
    timeout_ms: u32,
    /// The cap for each stream. The backend stops the read at this size and reports the cut.
    max_stream_bytes: u32,
};

/// How one command ended. The union makes an impossible pair unrepresentable.
pub const ExecOutcome = union(enum) {
    /// The command ended on its own with this code.
    exited: u8,
    /// A signal ended the command. The value is the signal number.
    signaled: u8,
    /// The deadline expired. The backend killed the process group.
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

/// A Host provides the native primitives a caller uses. The backend decides where they run.
/// The `ctx` and its borrowed data, for example the workspace root, must outlive every call.
pub const Host = struct {
    ctx: *anyopaque,
    vtable: *const VTable,

    pub const VTable = struct {
        /// Read a bounded line range. The result comes from `scratch`. The handler must copy the data
        /// it keeps into `out`. The backend rejects a RETURNED line that is not valid UTF-8.
        readRange: *const fn (ctx: *anyopaque, scratch: std.mem.Allocator, path: []const u8, range: Range, limits: ReadLimits) HostError!RangeRead,

        /// Read the exact bytes of a whole file. `max_bytes` limits the result.
        /// The result comes from `scratch`. The backend rejects invalid UTF-8.
        readAll: *const fn (ctx: *anyopaque, scratch: std.mem.Allocator, path: []const u8, max_bytes: u32) HostError![]const u8,

        /// Replace a file with `content`. The backend keeps the permissions and replaces atomically.
        /// The backend rejects a symlink, a hard link, or a special file.
        writeFile: *const fn (ctx: *anyopaque, scratch: std.mem.Allocator, path: []const u8, content: []const u8) HostError!void,

        /// Run one command through a shell. The backend puts it in its OWN process group and kills
        /// the whole group on a deadline or a cancel, so no descendant survives the call.
        exec: *const fn (ctx: *anyopaque, scratch: std.mem.Allocator, spec: ExecSpec) HostError!ExecResult,
    };

    pub fn readRange(self: Host, scratch: std.mem.Allocator, path: []const u8, range: Range, limits: ReadLimits) HostError!RangeRead {
        return self.vtable.readRange(self.ctx, scratch, path, range, limits);
    }

    pub fn readAll(self: Host, scratch: std.mem.Allocator, path: []const u8, max_bytes: u32) HostError![]const u8 {
        return self.vtable.readAll(self.ctx, scratch, path, max_bytes);
    }

    pub fn writeFile(self: Host, scratch: std.mem.Allocator, path: []const u8, content: []const u8) HostError!void {
        return self.vtable.writeFile(self.ctx, scratch, path, content);
    }

    pub fn exec(self: Host, scratch: std.mem.Allocator, spec: ExecSpec) HostError!ExecResult {
        return self.vtable.exec(self.ctx, scratch, spec);
    }
};
