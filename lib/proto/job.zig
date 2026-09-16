//! Background jobs that the model `exec` tool starts, and the calls a client uses to see, read, and stop them.

const ids = @import("ids.zig");

pub const JobState = enum { running, exited, stopped };

/// One background job. `exit_code` and `signal` stay null while it runs, and at most one of them is set after the end.
pub const Job = struct {
    id: u32,
    session_id: ?ids.SessionId = null,
    command: []const u8,
    cwd: []const u8,
    state: JobState,
    exit_code: ?u8 = null,
    signal: ?u8 = null,
    started_at_ms: u64,
    ended_at_ms: ?u64 = null,
};

/// These parameters filter the job list to one session.
pub const JobListParams = struct {
    session_id: ?ids.SessionId = null,
};

/// The jobs, newest first. The host keeps every running job and the 32 jobs that ended last.
pub const JobListResult = struct {
    jobs: []const Job,
};

pub const JobStopParams = struct {
    id: u32,
};

/// The job as it is when the stop starts. Its end arrives as `job.changed`.
pub const JobStopResult = struct {
    job: Job,
};

/// These parameters read the job output from a byte offset. `max_bytes` is at most 262144.
pub const JobReadParams = struct {
    id: u32,
    offset: u64,
    max_bytes: u32,
};

/// The output text, cut at a character boundary. Read again from `next` to follow a running job; `size` is the log size now.
pub const JobReadResult = struct {
    text: []const u8,
    next: u64,
    size: u64,
};

/// This payload describes `job.changed`: a job started or ended.
pub const JobChangedData = struct {
    job: Job,
};
