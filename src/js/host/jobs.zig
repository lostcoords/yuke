//! The background jobs of one host. Only the owner adds, finds, and frees a job; one waiter task reaps each job.

const std = @import("std");

/// The most jobs that run at once. A start past this limit fails.
pub const max_jobs = 16;

pub const Job = struct {
    id: u32,
    pid: std.posix.pid_t,
    child: std.process.Child,
    /// The waiter sets this after the reap and the group end. The owner frees a job only after it reads true.
    done: std.atomic.Value(bool) = .init(false),
};

pub const Jobs = struct {
    live: std.ArrayList(*Job) = .empty,
    last_id: u32 = 0,

    /// Free every job whose waiter finished, and answer whether a new job fits.
    pub fn prune(self: *Jobs, gpa: std.mem.Allocator) bool {
        var i: usize = 0;
        while (i < self.live.items.len) {
            const job = self.live.items[i];
            if (!job.done.load(.monotonic)) {
                i += 1;
                continue;
            }
            _ = self.live.swapRemove(i);
            gpa.destroy(job);
        }
        return self.live.items.len < max_jobs;
    }

    /// Take a started child. The caller starts its waiter.
    pub fn add(self: *Jobs, gpa: std.mem.Allocator, child: std.process.Child) *Job {
        std.debug.assert(self.live.items.len < max_jobs);
        self.last_id += 1;
        const job = gpa.create(Job) catch unreachable;
        job.* = .{ .id = self.last_id, .pid = child.id.?, .child = child };
        self.live.append(gpa, job) catch unreachable;
        return job;
    }

    /// Answer the running job with `id`, or null when it ended or never existed.
    pub fn find(self: *const Jobs, id: u32) ?*Job {
        for (self.live.items) |job| if (job.id == id and !job.done.load(.monotonic)) return job;
        return null;
    }

    /// Write the pid of every running job into `out` and answer the count. `Host.close` ends them before it cancels the waiters.
    pub fn runningPids(self: *const Jobs, out: []std.posix.pid_t) usize {
        var count: usize = 0;
        for (self.live.items) |job| if (!job.done.load(.monotonic)) {
            out[count] = job.pid;
            count += 1;
        };
        return count;
    }

    /// Free every job. Every waiter has returned, so no job runs and no task holds a pointer.
    pub fn deinit(self: *Jobs, gpa: std.mem.Allocator) void {
        for (self.live.items) |job| {
            std.debug.assert(job.done.load(.monotonic));
            gpa.destroy(job);
        }
        self.live.deinit(gpa);
        self.* = undefined;
    }
};
