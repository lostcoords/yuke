const std = @import("std");
const utf8 = @import("../utf8.zig");
const quickjs = @import("quickjs");
const memory = @import("memory.zig");
const zio = @import("zio");
const term_pkg = @import("term");
const loader_mod = @import("loader.zig");
const term_module = @import("native/term.zig");
const engine_module = @import("native/engine.zig");
const fs_module = @import("native/fs.zig");
const utf8_module = @import("native/utf8.zig");
const env_module = @import("native/env.zig");
const mcp_module = @import("native/mcp.zig");
const net_module = @import("native/net.zig");
const oauth_module = @import("native/oauth.zig");
const exec_module = @import("native/exec.zig");
const http_module = @import("native/http.zig");
const process_module = @import("native/process.zig");
const jobs_module = @import("native/jobs.zig");
const diff_module = @import("native/diff.zig");
const tools_module = @import("native/tools.zig");
const hooks_module = @import("native/hooks.zig");
const interaction_module = @import("native/interaction.zig");
const tools_table = @import("tools.zig");
const hooks_table = @import("hooks.zig");
const interactions_table = @import("interactions.zig");
const call_run = @import("call_run.zig");
const pending = @import("pending.zig");
const cancellation = @import("native/cancellation.zig");
const execution_mod = @import("../execution.zig");
const Logs = @import("host/logs.zig").Logs;
const timers_mod = @import("timers.zig");
const baked = @import("baked");

/// Limit the client heap. Scripts fail when they exceed this limit.
const memory_limit: usize = 64 * 1024 * 1024;
/// Limit the QuickJS stack below the zio coroutine stack.
const stack_limit: usize = 4 * 1024 * 1024;
/// Limit jobs per drain so Promise chains do not starve the owner.
const job_budget: u32 = 1024;
/// Bound one evaluation by interrupt polls, a coarse CPU proxy, so scheduling jitter never aborts a script.
pub const default_interrupt_budget: u32 = 100_000;
/// Limit the fault text the Host stores, so `captureFault` runs from a fixed buffer without an allocation.
const fault_text_max: usize = 512;
/// Report this when QuickJS gives no readable text for the exception.
const unknown_fault = "script fault with no message";

pub const Error = error{JavaScriptFault};

/// Every frontend bakes every module, because `index.js` is one file that both frontends load.
pub const default_baked = blk: {
    const list = baked.modules;
    var modules: [list.len]loader_mod.BakedModule = undefined;
    for (list, 0..) |m, i| modules[i] = .{ .name = m.name, .code = .{ .bytecode = m.bytecode } };
    break :blk modules;
};

pub const Options = struct {
    /// The shared deadline for plugin stop timers and the native shutdown guard.
    plugin_stop_timeout_ms: i32 = 1000,
    max_file_bytes: usize = loader_mod.default_max_file_bytes,
    /// The directory the process runs in. A new session takes it as the workspace root.
    cwd: []const u8,
    /// The startup answers: the effective environment and the one command shell.
    execution: execution_mod.Context,
};

/// Own one QuickJS runtime and context. The TUI owner calls `eval` and `destroy`.
pub const Host = struct {
    gpa: std.mem.Allocator,
    runtime: *quickjs.Runtime,
    memory: memory.Allocator,
    ctx: quickjs.Context,
    loader: loader_mod.Loader,
    phase: Phase,
    interrupt_budget: u32,
    interrupt_count: u32,
    /// Hold the last script fault text. The Host owns these bytes and `report.zig` paints them.
    fault_text: [fault_text_max]u8,
    fault_text_len: usize,
    paint: term_module.Paint,
    /// Engine seam state for `yuke:engine-native`.
    engine: *engine_module.Engine,
    /// The directory the process runs in. The caller owns these bytes for the life of the host.
    cwd: []const u8,
    /// The reactor I/O. `yuke:fs` reads the file system through it.
    io: std.Io,
    /// The startup answers. The caller owns them for the life of the host.
    execution: execution_mod.Context,
    /// Every primitive call in flight. A task finishes one; the owner settles it.
    ops: pending.Ops,
    /// The tools `index.js` registered. The process reads its declarations after boot.
    tools: tools_table.Tools,
    /// The hook points a plugin holds, and the chain folder `yuke:ext` installs.
    hooks: hooks_table.Hooks,
    /// Every tool call a turn task waits on. The owner answers them in `pump`.
    calls: tools_table.Calls,
    /// Every headless interaction that waits for a correlated frontend answer.
    interactions: interactions_table.Table,
    /// The owner sleeps on this. A task sets it after work reaches the owner queue.
    wake: std.Io.Event = .unset,
    /// The tasks running those calls. `close` cancels them before the context dies.
    tasks: std.Io.Group = .init,
    /// The command logs. Only the owner makes a path.
    logs: Logs = .{},
    /// The `setTimeout` and `setInterval` table. Only the owner touches it.
    timers: timers_mod.Timers = .{},
    /// The `yuke:process` children. `close` ends them before it cancels their tasks.
    procs: process_module.Procs = .{},
    /// The background job table. A record outlives its process, and `close` frees it after the processes.
    jobs: jobs_module.Jobs = .{},

    net: net_module.Connections = .{},
    /// The loopback listeners of MCP sign-ins. Each one takes one callback.
    oauth: oauth_module.Listeners = .{},

    /// The shared `fetch` client. It loads the root bundle once and takes a fresh clock for each request.
    http: http_module.Client = .{},
    /// The response bodies that wait for reads. Each one holds a client connection until it ends.
    bodies: http_module.Bodies = .{},

    plugin_lifecycle: ?quickjs.Value = null,
    signal_class_id: quickjs.ClassID = 0,
    signal_waiters: std.ArrayList(cancellation.Waiter) = .empty,
    abort_listeners: std.ArrayList(cancellation.Listener) = .empty,
    /// The next listener id; zero is invalid.
    next_listener: u32 = 1,
    plugin_stop_timeout_ms: i32,

    pub const Phase = enum { open, stopping, closing, drained };

    /// Cleanup can use I/O until the host enters the close phase.
    pub fn acceptsIo(self: *const Host) bool {
        return self.phase == .open or self.phase == .stopping;
    }

    /// Allocate a host and install its limits, interrupt handler, and loader.
    pub fn createWith(gpa: std.mem.Allocator, io: std.Io, opts: Options) *Host {
        std.debug.assert(opts.plugin_stop_timeout_ms > 0);
        const self = gpa.create(Host) catch unreachable;
        self.memory = .{ .backing = gpa };
        const runtime = memory.createRuntime(&self.memory) catch unreachable;
        runtime.setMemoryLimit(memory_limit);
        runtime.setMaxStackSize(stack_limit);
        const ctx = quickjs.Context.init(runtime);
        std.debug.assert(ctx.ptr != null);

        const ld: loader_mod.Loader = .{
            .gpa = gpa,
            .io = io,
            .baked = &default_baked,
            .max_file_bytes = opts.max_file_bytes,
        };
        const eng = engine_module.Engine.create(gpa, ctx, io, &self.wake) catch unreachable;

        self.* = .{
            .gpa = gpa,
            .runtime = runtime,
            .memory = self.memory,
            .ctx = ctx,
            .loader = ld,
            .phase = .open,
            .plugin_stop_timeout_ms = opts.plugin_stop_timeout_ms,
            .interrupt_budget = default_interrupt_budget,
            .interrupt_count = 0,
            .fault_text = undefined,
            .fault_text_len = 0,
            .paint = .{},
            .engine = eng,
            .cwd = opts.cwd,
            .io = io,
            .execution = opts.execution,
            .ops = .{ .gpa = gpa, .io = io, .wake = &self.wake },
            .tools = .{ .gpa = gpa },
            .hooks = .{},
            .calls = .{ .gpa = gpa },
            .interactions = .{ .gpa = gpa },
        };
        runtime.setRuntimeOpaque(self);
        ctx.setContextOpaque(self);
        runtime.setInterruptHandler(self);
        runtime.setModuleLoader(&self.loader);
        // A host with no renderer still installs the term module, because every draw call refuses a null render.
        const installers = [_]*const fn (*Host) void{
            term_module.install,  engine_module.install,  fs_module.install,          env_module.install,
            http_module.install,  utf8_module.install,    net_module.install,         exec_module.install,
            timers_mod.install,   process_module.install, jobs_module.install,        diff_module.install,
            tools_module.install, hooks_module.install,   interaction_module.install, cancellation.install,
            mcp_module.install,   oauth_module.install,
        };
        for (installers) |install| install(self);
        return self;
    }

    /// What a primitive binds before its task starts. The host keeps its own reference to each value.
    pub const StartOptions = struct {
        /// A cancellation signal, or undefined.
        signal: quickjs.Value = quickjs.UNDEFINED,
        /// A function that takes the live text of `pending.Op.stream`, or undefined.
        on_text: quickjs.Value = quickjs.UNDEFINED,
    };

    /// Start one primitive on its own task and answer its promise. The task reads only what `payload` owns, a refusal rejects, and only a full QuickJS heap throws.
    pub fn startTask(self: *Host, comptime Payload: type, comptime task: fn (*Host, *pending.Op, Payload) void, payload: Payload, options: StartOptions) quickjs.Value {
        const signal = options.signal;
        std.debug.assert(self.ctx.isUndefined(options.on_text) or self.ctx.isFunction(options.on_text));
        if (!self.acceptsIo()) {
            payload.free(self.gpa);
            return pending.rejected(self.ctx, "the host is closed");
        }
        const token = if (self.ctx.isUndefined(signal)) null else cancellation.get(self.ctx, signal) orelse {
            payload.free(self.gpa);
            return pending.rejected(self.ctx, "invalid cancellation signal");
        };
        if (token) |held| if (held.aborted) {
            payload.free(self.gpa);
            return pending.rejected(self.ctx, "the operation was canceled");
        };
        const started = self.ops.start(self.ctx) orelse {
            payload.free(self.gpa);
            return self.ctx.throw(self.ctx.getException());
        };
        started.op.signal = self.ctx.dupValue(signal);
        started.op.on_text = self.ctx.dupValue(options.on_text);
        if (token) |held| held.retain();
        if (self.calls.callForSignal(self.ctx, signal)) |call| if (call.work) |work| {
            work.retain(&started.op.operation);
            started.op.work = work;
        };
        self.tasks.concurrent(self.io, task, .{ self, started.op, payload }) catch {
            payload.free(self.gpa);
            started.op.finish(.{ .failed = .{ .message = "the host cannot start another operation" } });
        };
        return started.promise;
    }

    /// Settle finished operations and run the jobs they wake in two ordered phases, because the first phase settles a promise a handler awaited and the second runs what that handler queued.
    pub fn pump(self: *Host) Error!void {
        std.debug.assert(self.phase == .open);
        self.enterSlice();
        self.net.reap(self.gpa);
        self.oauth.reap(self.gpa);
        self.bodies.reap(self.gpa);
        // Engine events reach JavaScript here, on the owner, never from an engine task.
        if (engine_module.drain(self.engine, self.ctx)) return error.JavaScriptFault;
        call_run.abortLeft(self); // A continuation below must read a left call's signal as aborted.
        // Output reaches its callback before `settle`, so every chunk of a child arrives before a promise its exit settles.
        var faulted = self.procs.drain(self);
        if (self.ops.settle(self)) faulted = true;
        // A timer fires before the drain, so a promise it settles runs its reactions in this pump.
        if (self.timers.fire(self, std.Io.Timestamp.now(self.io, .awake))) faulted = true;
        try self.drainJobs();
        // The first drain settles a promise a handler awaited, the poll reads it, and the second drain runs what the handler queued.
        call_run.pump(self);
        if (self.ops.settle(self)) faulted = true;
        try self.drainJobs();
        // The last drain can settle a call Promise, so this pump reads it before the owner sleeps.
        call_run.pollRunning(self);
        // A callback can cancel a native interaction; hasPending schedules its completion for the next pass.
        if (faulted) {
            self.dropPendingException();
            return error.JavaScriptFault;
        }
    }

    /// Report whether the owner has work to run. The owner asks before it sleeps.
    pub fn hasPending(self: *const Host) bool {
        return self.runtime.isJobPending() or self.ops.anyReady() or self.engine.hasPending() or
            self.calls.hasWork(self.ctx) or self.procs.hasWork() or self.timers.isDue(std.Io.Timestamp.now(self.io, .awake));
    }

    /// Sleep until a task sets the wake, the next timer is due, or `deadline` passes; a passed deadline is `error.Timeout`.
    pub fn waitForWork(self: *Host, deadline: ?std.Io.Clock.Timestamp) error{ Canceled, Timeout }!void {
        if (self.hasPending()) return;
        const timer: ?std.Io.Clock.Timestamp = if (self.timers.nextDeadline()) |due| .{ .raw = due, .clock = .awake } else null;
        const until = if (timer) |t| (if (deadline) |d| (if (t.raw.nanoseconds < d.raw.nanoseconds) t else d) else t) else deadline orelse return self.wake.wait(self.io);
        self.wake.waitTimeout(self.io, .{ .deadline = until }) catch |err| switch (err) {
            error.Canceled => return error.Canceled,
            // A spurious wakeup also answers Timeout, so only a passed deadline counts.
            error.Timeout => if (deadline) |d| if (d.durationFromNow(self.io).raw.nanoseconds <= 0) return error.Timeout,
        };
    }

    /// Pump until `done(context)` holds; the condition is read after each pump, because a settle inside the pump sets no wake.
    pub fn pumpUntil(self: *Host, deadline: ?std.Io.Clock.Timestamp, context: anytype, comptime done: fn (@TypeOf(context)) bool) (Error || error{ Canceled, Timeout })!void {
        std.debug.assert(self.phase == .open);
        while (true) {
            self.wake.reset();
            try self.pump();
            if (done(context)) return;
            // Work that stays ready never sleeps, so the deadline is read on every pass too.
            if (deadline) |d| if (d.durationFromNow(self.io).raw.nanoseconds <= 0) return error.Timeout;
            try self.waitForWork(deadline);
        }
    }

    /// Drain jobs, release QuickJS resources, and destroy the host.
    pub fn destroy(self: *Host) void {
        if (self.acceptsIo()) {
            self.close() catch {};
        }
        self.finishDrain();
        std.debug.assert(self.phase == .drained);
        self.ops.deinit(self.ctx);
        cancellation.deinit(self);
        self.logs.deinit(self.gpa, self.io);
        self.interactions.deinit();
        self.calls.deinit(self.ctx);
        self.tools.deinit(self.ctx);
        self.hooks.deinit(self.ctx);
        if (self.plugin_lifecycle) |callback| self.ctx.freeValue(callback);
        self.engine.destroy();
        self.paint.freeRoots(self.ctx);
        self.ctx.deinit();
        self.runtime.deinit();
        self.memory.deinit();
        self.gpa.destroy(self);
    }

    /// Stop JavaScript work, drain jobs, and close the host.
    pub fn close(self: *Host) Error!void {
        std.debug.assert(self.acceptsIo());
        self.stopPlugins();
        self.phase = .closing;
        // Phase 1: stop event delivery so no engine task reaches a closing context.
        self.engine.detach();
        // A turn task may wait on a tool call. Answer each one, or that task never wakes.
        call_run.abortAll(self);
        self.endChildren();
        self.net.closeAll();
        self.oauth.closeAll();
        // `Group.cancel` cancels and joins, so every task has returned here and `Ops.deinit` can free the ops a task pointed to.
        self.tasks.cancel(self.io);
        self.net.deinit(self.gpa);
        self.oauth.deinit(self.gpa);
        // Only idle response bodies remain after all HTTP tasks return.
        self.bodies.closeAll();
        // Every body has released its connection, so the client can free the pool.
        self.bodies.deinit(self.gpa);
        self.http.deinit();
        self.timers.deinit(self.ctx, self.gpa);
        self.procs.deinit(self);
        self.jobs.deinit(self.gpa);
        self.interactions.close();
        if (self.ops.settle(self)) {
            self.dropPendingException();
            return error.JavaScriptFault;
        }
        var rounds: u32 = 0;
        while (self.runtime.isJobPending()) {
            try self.drainJobs();
            rounds += 1;
            if (rounds == 16) break;
        }
        if (self.runtime.isJobPending()) return error.JavaScriptFault;
        self.phase = .drained;
    }

    /// Stop plugins while I/O remains available, with one deadline for the whole registry.
    pub fn stopPlugins(self: *Host) void {
        if (self.phase != .open) return;
        self.phase = .stopping;
        const callback = self.plugin_lifecycle orelse return;
        var guard: DeadlineGuard = .{
            .host = self,
            .deadline = std.Io.Timestamp.now(self.io, .awake).addDuration(.fromMilliseconds(self.plugin_stop_timeout_ms)),
        };
        self.runtime.setInterruptHandler(&guard);
        defer self.runtime.setInterruptHandler(self);
        defer {
            // Forced scope disposal gets a fresh CPU slice after the async deadline.
            guard.deadline = std.Io.Timestamp.now(self.io, .awake).addDuration(.fromMilliseconds(100));
            self.enterSlice();
            const result = self.ctx.call(callback, quickjs.UNDEFINED, &.{quickjs.TRUE});
            if (self.ctx.isException(result)) self.noteFault();
            self.ctx.freeValue(result);
        }
        call_run.abortAll(self);
        self.enterSlice();
        const promise = self.ctx.call(callback, quickjs.UNDEFINED, &.{quickjs.FALSE});
        defer self.ctx.freeValue(promise);
        if (self.ctx.isException(promise)) return self.noteFault();
        if (!self.ctx.isPromise(promise)) return;
        while (self.ctx.promiseState(promise) == .Pending) {
            if (std.Io.Timestamp.now(self.io, .awake).nanoseconds >= guard.deadline.nanoseconds) {
                self.fault_text_len = 0;
                self.appendFaultText("plugin shutdown timed out");
                return;
            }
            self.wake.reset();
            self.enterSlice();
            self.net.reap(self.gpa);
            self.oauth.reap(self.gpa);
            self.bodies.reap(self.gpa);
            if (self.procs.drain(self)) self.dropPendingException();
            if (self.ops.settle(self)) self.dropPendingException();
            if (self.timers.fire(self, std.Io.Timestamp.now(self.io, .awake))) self.dropPendingException();
            self.drainJobs() catch return;
            if (self.ctx.promiseState(promise) != .Pending) break;
            if (self.runtime.isJobPending() or self.ops.anyReady() or self.procs.hasWork()) continue;
            const timer = self.timers.nextDeadline() orelse guard.deadline;
            const due = if (timer.nanoseconds < guard.deadline.nanoseconds) timer else guard.deadline;
            self.wake.waitTimeout(self.io, .{ .deadline = .{ .raw = due, .clock = .awake } }) catch |err| switch (err) {
                error.Timeout => {},
                error.Canceled => return,
            };
        }
        if (self.ctx.promiseState(promise) == .Rejected) {
            const reason = self.ctx.promiseResult(promise);
            defer self.ctx.freeValue(reason);
            self.fault_text_len = 0;
            self.captureFault(reason);
        }
    }

    const DeadlineGuard = struct {
        host: *Host,
        deadline: std.Io.Timestamp,

        pub fn onInterrupt(self: *DeadlineGuard) bool {
            return self.host.onInterrupt() or std.Io.Timestamp.now(self.host.io, .awake).nanoseconds >= self.deadline.nanoseconds;
        }
    };

    /// Request all child stops before `tasks.cancel`, so their grace periods overlap.
    pub fn endChildren(self: *Host) void {
        self.procs.stopAll(self.io);
    }

    /// Recover the host from a QuickJS context opaque pointer.
    pub fn fromContext(ctx: quickjs.Context) *Host {
        const ptr = ctx.getContextOpaque() orelse unreachable;
        return @ptrCast(@alignCast(ptr));
    }

    /// Evaluate source on the owner, then drain jobs.
    pub fn eval(self: *Host, source: [:0]const u8, filename: [:0]const u8) Error!void {
        std.debug.assert(self.phase == .open);
        self.enterSlice();
        const value = self.ctx.eval(source, filename, .{}) catch {
            self.noteFault();
            return error.JavaScriptFault;
        };
        self.ctx.freeValue(value);
        try self.drainJobs();
    }

    /// Mark host-owned source so its internal imports remain valid after this call returns.
    pub fn evalModule(self: *Host, source: [:0]const u8, filename: [:0]const u8) Error!void {
        std.debug.assert(self.phase == .open);
        std.debug.assert(filename.len > 0);
        const name = std.fmt.allocPrintSentinel(self.gpa, "{s}{s}", .{ loader_mod.host_module_prefix, filename }, 0) catch unreachable;
        defer self.gpa.free(name);
        try self.evalModuleSource(source, name, false);
    }

    /// Evaluate a module and drain its jobs; the filename determines its import access.
    fn evalModuleSource(self: *Host, source: [:0]const u8, filename: [:0]const u8, wait: bool) Error!void {
        std.debug.assert(self.phase == .open);
        std.debug.assert(filename.len > 0);
        self.enterSlice();
        const value = self.ctx.eval(source, filename, .{ .type = .module }) catch {
            self.noteFault();
            return error.JavaScriptFault;
        };
        defer self.ctx.freeValue(value);
        try self.drainJobs();
        if (wait) try self.awaitStartup(value);
        try self.checkModulePromise(value);
    }

    /// Pump native I/O while an entry module waits for plugin startup.
    pub fn evalStartup(self: *Host, source: [:0]const u8, filename: [:0]const u8) Error!void {
        const name = std.fmt.allocPrintSentinel(self.gpa, "{s}{s}", .{ loader_mod.host_module_prefix, filename }, 0) catch unreachable;
        defer self.gpa.free(name);
        try self.evalModuleSource(source, name, true);
    }

    fn awaitStartup(self: *Host, promise: quickjs.Value) Error!void {
        std.debug.assert(self.phase == .open);
        if (!self.ctx.isPromise(promise) or self.ctx.promiseState(promise) != .Pending) return;
        var guard: DeadlineGuard = .{
            .host = self,
            .deadline = std.Io.Timestamp.now(self.io, .awake).addDuration(.fromSeconds(10)),
        };
        self.runtime.setInterruptHandler(&guard);
        defer self.runtime.setInterruptHandler(self);
        self.pumpUntil(.{ .raw = guard.deadline, .clock = .awake }, PendingPromise{ .ctx = self.ctx, .promise = promise }, PendingPromise.settled) catch |err| switch (err) {
            error.JavaScriptFault, error.Canceled => return error.JavaScriptFault,
            error.Timeout => {
                self.fault_text_len = 0;
                self.appendFaultText("plugin startup timed out");
                return error.JavaScriptFault;
            },
        };
    }

    /// A promise the owner waits on with `pumpUntil`.
    pub const PendingPromise = struct {
        ctx: quickjs.Context,
        promise: quickjs.Value,

        pub fn settled(self: PendingPromise) bool {
            return self.ctx.promiseState(self.promise) != .Pending;
        }
    };

    /// Turn a rejected module promise into a fault, because QuickJS never throws it at the caller.
    fn checkModulePromise(self: *Host, value: quickjs.Value) Error!void {
        if (!self.ctx.isPromise(value)) return;
        switch (self.ctx.promiseState(value)) {
            .Fulfilled => return,
            .Rejected => {
                const reason = self.ctx.promiseResult(value);
                defer self.ctx.freeValue(reason);
                self.fault_text_len = 0;
                self.captureFault(reason);
            },
            .Pending => {
                self.fault_text_len = 0;
                self.appendFaultText("module did not settle: a top-level await cannot complete");
            },
        }
        return error.JavaScriptFault;
    }

    /// Evaluate a module file from disk. Return false when the loader cannot read the file.
    pub fn evalFile(self: *Host, path: [:0]const u8) Error!bool {
        std.debug.assert(self.phase == .open);
        const source = self.loader.readModule(path) orelse return false;
        defer self.gpa.free(source);
        try self.evalModuleSource(source, path, true);
        return true;
    }

    /// Evaluate source and return its result as `i32`. Tests use this helper.
    pub fn evalInt(self: *Host, source: [:0]const u8) Error!i32 {
        std.debug.assert(self.phase == .open);
        self.enterSlice();
        const value = self.ctx.eval(source, "evalInt.js", .{}) catch {
            self.noteFault();
            return error.JavaScriptFault;
        };
        defer self.ctx.freeValue(value);
        const n = self.ctx.toInt32(value) catch {
            self.noteFault();
            return error.JavaScriptFault;
        };
        try self.drainJobs();
        return n;
    }

    /// Drain at most `job_budget` jobs and leave the rest for the owner.
    pub fn drainJobs(self: *Host) Error!void {
        var n: u32 = 0;
        while (self.runtime.isJobPending()) {
            if (n == job_budget) return;
            self.enterSlice();
            _ = self.runtime.executePendingJob() catch {
                self.noteFault();
                return error.JavaScriptFault;
            };
            n += 1;
        }
    }

    /// QuickJS calls this in the bytecode loop: do not allocate or run JavaScript, and bound every live phase.
    pub fn onInterrupt(self: *Host) bool {
        self.interrupt_count = self.interrupt_count +| 1;
        return self.interrupt_count > self.interrupt_budget;
    }

    pub fn enterSlice(self: *Host) void {
        self.interrupt_count = 0;
    }

    pub fn noteFault(self: *Host) void {
        self.fault_text_len = 0;
        if (!self.ctx.hasException()) return;
        const exc = self.ctx.getException();
        defer self.ctx.freeValue(exc);
        self.captureFault(exc);
        // QuickJS can return a string and still leave an exception. Handle it; do not assert it.
        self.dropPendingException();
    }

    /// Copy the exception text into the fixed buffer, because the Host allocates nothing after an out-of-memory fault.
    fn captureFault(self: *Host, exc: quickjs.Value) void {
        std.debug.assert(self.fault_text_len == 0);
        // A conversion can call a user `toString`, so a zero budget stops it at the first poll.
        const saved = self.interrupt_budget;
        defer self.interrupt_budget = saved;
        self.interrupt_budget = 0;

        _ = self.appendFaultValue(exc);
        self.appendStack(exc);
        // A fault always carries text, so `faultText` alone reports that a fault happened.
        if (self.fault_text_len == 0) self.appendFaultText(unknown_fault);
        std.debug.assert(self.fault_text_len != 0);
    }

    /// Append the first line of `.stack` after a separator. A plain `throw` carries no `.stack`.
    fn appendStack(self: *Host, exc: quickjs.Value) void {
        if (self.fault_text_len == 0) return;
        const stack = self.ctx.getPropertyStr(exc, "stack");
        defer self.ctx.freeValue(stack);
        if (self.ctx.isException(stack)) return self.dropPendingException();
        if (!self.ctx.isString(stack)) return;
        const mark = self.fault_text_len;
        self.appendFaultText(" ");
        if (!self.appendFaultValue(stack)) self.fault_text_len = mark;
    }

    /// Append the first line of the string form of `val`. Return true when it appends bytes.
    fn appendFaultValue(self: *Host, val: quickjs.Value) bool {
        const s = self.ctx.toCStringLen(val) catch {
            self.dropPendingException();
            return false;
        };
        defer self.ctx.freeCString(s.ptr);
        const line = firstLine(s);
        if (line.len == 0) return false;
        self.appendFaultText(line);
        return true;
    }

    /// Append `text` until the buffer has no space. Cut on a UTF-8 boundary.
    fn appendFaultText(self: *Host, text: []const u8) void {
        std.debug.assert(self.fault_text_len <= self.fault_text.len);
        const room = self.fault_text.len - self.fault_text_len;
        const n = utf8.floor(text, room);
        std.debug.assert(n <= room);
        @memcpy(self.fault_text[self.fault_text_len..][0..n], text[0..n]);
        self.fault_text_len += n;
    }

    /// Drop a pending exception before the next owner turn.
    fn dropPendingException(self: *Host) void {
        pending.dropException(self.ctx);
    }

    /// Return the last script fault text, or an empty slice when the Host has no fault.
    pub fn faultText(self: *const Host) []const u8 {
        std.debug.assert(self.fault_text_len <= self.fault_text.len);
        return self.fault_text[0..self.fault_text_len];
    }

    /// Clear the fault text; the next successful frame calls this.
    pub fn clearFault(self: *Host) void {
        self.fault_text_len = 0;
    }

    fn finishDrain(self: *Host) void {
        var n: u32 = 0;
        while (self.runtime.isJobPending() and n < job_budget) : (n += 1) {
            _ = self.runtime.executePendingJob() catch break;
        }
        self.phase = .drained;
    }
};

/// Return the text before the first line break. A fault line uses one row.
fn firstLine(text: []const u8) []const u8 {
    const end = std.mem.indexOfAny(u8, text, "\r\n") orelse text.len;
    return std.mem.trim(u8, text[0..end], " \t");
}

test "eval returns an integer" {
    const host = support.createHost();
    defer support.destroyHost(host);

    try host.eval("globalThis.n = 40 + 2", "smoke.js");
    try std.testing.expectEqual(@as(i32, 42), try host.evalInt("globalThis.n"));
}

test "two hosts do not share globals" {
    const a = support.createHost();
    defer support.destroyHost(a);
    const b = support.createHost();
    defer support.destroyHost(b);

    try a.eval("globalThis.n = 1", "a.js");
    try b.eval("globalThis.n = 2", "b.js");
    try std.testing.expectEqual(@as(i32, 1), try a.evalInt("globalThis.n"));
    try std.testing.expectEqual(@as(i32, 2), try b.evalInt("globalThis.n"));
}

test "a syntax error is a JavaScriptFault" {
    const host = support.createHost();
    defer support.destroyHost(host);
    try std.testing.expectError(error.JavaScriptFault, host.eval("this is not js", "bad.js"));
    try std.testing.expect(std.mem.indexOf(u8, host.faultText(), "bad.js:1") != null);
    try host.eval("globalThis.n = 1", "after.js");
    try std.testing.expectEqual(@as(i32, 1), try host.evalInt("globalThis.n"));
}

test "an infinite loop hits the interrupt budget" {
    const host = support.createHost();
    defer support.destroyHost(host);
    host.interrupt_budget = 0;
    try std.testing.expectError(error.JavaScriptFault, host.eval("while (true) {}", "spin.js"));
    try std.testing.expect(std.mem.indexOf(u8, host.faultText(), "interrupted") != null);
}

test "close interrupts a leftover spinning job" {
    const host = support.createHost();
    defer support.destroyHost(host);
    const queued = try host.ctx.eval("Promise.resolve().then(() => { while (true) {} })", "spin.js", .{});
    host.ctx.freeValue(queued);
    try std.testing.expect(host.runtime.isJobPending());
    host.interrupt_budget = 0;
    try std.testing.expectError(error.JavaScriptFault, host.close());
    // The host stopped inside the drain, so it never reached `drained`.
    try std.testing.expectEqual(Host.Phase.closing, host.phase);
    try std.testing.expect(std.mem.indexOf(u8, host.faultText(), "interrupted") != null);
}

test "close drains then destroy frees the runtime" {
    const host = support.createHost();
    defer support.destroyHost(host);
    const queued = try host.ctx.eval("Promise.resolve().then(() => {})", "close.js", .{});
    host.ctx.freeValue(queued);
    try std.testing.expect(host.runtime.isJobPending());
    try host.close();
    try std.testing.expectEqual(Host.Phase.drained, host.phase);
    try std.testing.expect(!host.runtime.isJobPending());
}

test "the job budget yields to the owner and pump completes the jobs" {
    const host = support.createHost();
    defer support.destroyHost(host);
    const source = std.fmt.comptimePrint(
        \\globalThis.n = 0;
        \\function next() {{ if (++globalThis.n < {d}) Promise.resolve().then(next); }}
        \\Promise.resolve().then(next);
    , .{job_budget + 1});
    try host.eval(source, "budget.js");
    try std.testing.expect(host.runtime.isJobPending());
    const global = host.ctx.getGlobalObject();
    defer host.ctx.freeValue(global);
    const count = host.ctx.getPropertyStr(global, "n");
    defer host.ctx.freeValue(count);
    try std.testing.expectEqual(@as(i64, job_budget), try host.ctx.toInt64(count));
    try std.testing.expect(host.hasPending());
    try host.pump();
    try std.testing.expect(!host.hasPending());
    try std.testing.expectEqual(@as(i32, job_budget + 1), try host.evalInt("globalThis.n"));
}

test "a memory-limit hit is a catchable fault" {
    const host = support.createHost();
    defer support.destroyHost(host);
    host.runtime.setMemoryLimit(256 * 1024);
    try std.testing.expectEqual(@as(i64, 256 * 1024), host.runtime.computeMemoryUsage().malloc_limit);
    try host.eval("1", "tiny.js");
    try std.testing.expectError(
        error.JavaScriptFault,
        host.eval("globalThis.s = 'x'.repeat(2 * 1024 * 1024)", "oom.js"),
    );
    try std.testing.expect(std.mem.indexOf(u8, host.faultText(), "out of memory") != null);
}

test "a module that never settles is a fault" {
    const host = support.createHost();
    defer support.destroyHost(host);
    try std.testing.expectError(
        error.JavaScriptFault,
        host.evalModule("await new Promise(() => {});", "hang.js"),
    );
    try std.testing.expect(std.mem.indexOf(u8, host.faultText(), "did not settle") != null);
}

test "a rejected module reports the reason" {
    const host = support.createHost();
    defer support.destroyHost(host);
    try std.testing.expectError(
        error.JavaScriptFault,
        host.evalModule("throw new Error('top level');", "reject.js"),
    );
    try std.testing.expect(std.mem.indexOf(u8, host.faultText(), "top level") != null);
}

test "fault text truncates on a UTF-8 boundary" {
    const host = support.createHost();
    defer support.destroyHost(host);
    try std.testing.expectError(
        error.JavaScriptFault,
        host.eval("throw new Error('あ'.repeat(400));", "wide.js"),
    );
    const text = host.faultText();
    // The buffer holds the real message, not the fallback, and the cut keeps it valid.
    try std.testing.expect(!std.mem.eql(u8, text, unknown_fault));
    try std.testing.expect(text.len > fault_text_max - 4);
    try std.testing.expect(text.len <= fault_text_max);
    try std.testing.expect(std.unicode.utf8ValidateSlice(text));
}

test "a throwing toString still leaves the context clean" {
    const host = support.createHost();
    defer support.destroyHost(host);
    try std.testing.expectError(error.JavaScriptFault, host.eval(
        "throw { toString() { throw new Error('nested'); } };",
        "nasty.js",
    ));
    try std.testing.expectEqualStrings(unknown_fault, host.faultText());
    try std.testing.expect(!host.ctx.hasException());
    try host.eval("globalThis.n = 3;", "after.js");
    try std.testing.expectEqual(@as(i32, 3), try host.evalInt("globalThis.n"));
}

test "an unknown yuke module is a JavaScriptFault" {
    const host = support.createHost();
    defer support.destroyHost(host);
    try std.testing.expectError(
        error.JavaScriptFault,
        host.evalModule("import { n } from 'yuke:missing';", "entry.js"),
    );
}

test "user files can import public entries but cannot import cached internal modules" {
    const host = Host.createWith(std.testing.allocator, std.testing.io, support.hostOptions(""));
    defer host.destroy();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var root_buf: [std.fs.max_path_bytes]u8 = undefined;
    const root = root_buf[0..try tmp.dir.realPath(std.testing.io, &root_buf)];
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "public.js", .data =
        \\import { fs, plugins } from "yuke";
        \\import { Composer } from "yuke/ui";
        \\import { composerVim, transcriptVim, agents } from "yuke/plugins";
        \\import { Chat } from "yuke/chat";
        \\globalThis.publicOK = typeof fs.readFile === "function"
        \\  && typeof Composer === "function" && typeof Chat === "function"
        \\  && typeof agents === "function" && typeof composerVim.apply === "function"
        \\  && typeof transcriptVim.apply === "function" && plugins.names().length === 0;
    });
    const public_path = try std.fs.path.joinZ(std.testing.allocator, &.{ root, "public.js" });
    defer std.testing.allocator.free(public_path);
    try std.testing.expect(try host.evalFile(public_path));
    try std.testing.expectEqual(@as(i32, 1), try host.evalInt("globalThis.publicOK"));

    const private_path = try std.fs.path.joinZ(std.testing.allocator, &.{ root, "private.js" });
    defer std.testing.allocator.free(private_path);
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "private.js", .data = "export { fs } from 'yuke:fs';" });
    try std.testing.expectError(error.JavaScriptFault, host.evalFile(private_path));
    try std.testing.expect(std.mem.indexOf(u8, host.faultText(), "internal yuke module") != null);
    try std.testing.expectError(error.JavaScriptFault, host.evalModule("import './private.js';", public_path));

    const dynamic_path = try std.fs.path.joinZ(std.testing.allocator, &.{ root, "dynamic.js" });
    defer std.testing.allocator.free(dynamic_path);
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "dynamic.js", .data =
        \\globalThis.loadPrivate = () => import("yuke:core");
        \\globalThis.evalPrivate = () => eval('import("yuke:core")');
    });
    try std.testing.expect(try host.evalFile(dynamic_path));
    try std.testing.expectError(error.JavaScriptFault, host.evalModule("await loadPrivate();", "callback.js"));
    try std.testing.expectError(error.JavaScriptFault, host.evalModule("await evalPrivate();", "callback-eval.js"));
}

test "resize keeps unicode width after a write fail" {
    var paint: TestPaint = undefined;
    try paint.setup(std.testing.allocator, 2, 4);
    defer paint.deinit();

    var fail: std.Io.Writer = .failing;
    const host = support.createHost();
    defer support.destroyHost(host);
    host.paint.bindRender(host.ctx, &paint.render, &fail);
    // Only `resize` can put the method back, so the assertion cannot pass on `bindRender` alone.
    paint.render.vx.screen.width_method = .wcwidth;
    host.paint.resize(host.ctx, .{ .rows = 3, .cols = 8, .x_pixel = 0, .y_pixel = 0 });
    try std.testing.expectEqual(term_pkg.gwidth.Method.unicode, paint.render.vx.screen.width_method);
    try std.testing.expectEqual(@as(u16, 8), host.paint.width);
    try std.testing.expectEqual(@as(u16, 3), host.paint.height);
    try std.testing.expectEqual(.pending, paint.render.frame);
    try std.testing.expect(try paint.render.commitFrame(&paint.sink.writer));
    try std.testing.expectEqual(.idle, paint.render.frame);
}

test "an event asks for a frame and the flush paints it once" {
    var paint: TestPaint = undefined;
    try paint.setup(std.testing.allocator, 2, 8);
    defer paint.deinit();
    const host = support.createHost();
    defer support.destroyHost(host);
    paint.bind(host);

    try host.evalModule(
        \\import { term } from "yuke:term";
        \\import { root, View } from "yuke:core";
        \\globalThis.paints = 0;
        \\class Counter extends View {
        \\  draw() { globalThis.paints++; term.text(0, 0, "x"); }
        \\  onKey() { return true; }
        \\}
        \\root.setActive(new Counter());
    , "boot.js");
    // An event batch applies three keys and paints once.
    for (0..3) |_| try loop.step(host, .{ .key_press = .{ .codepoint = 'a' } });
    try std.testing.expectEqual(@as(i32, 0), try host.evalInt("globalThis.paints"));
    try loop.flushFrame(host);
    try std.testing.expectEqual(@as(i32, 1), try host.evalInt("globalThis.paints"));

    // A second flush with no new event paints nothing.
    try loop.flushFrame(host);
    try std.testing.expectEqual(@as(i32, 1), try host.evalInt("globalThis.paints"));

    // One event also waits for the owner to flush.
    try loop.step(host, .{ .key_press = .{ .codepoint = 'a' } });
    try std.testing.expectEqual(@as(i32, 1), try host.evalInt("globalThis.paints"));
    try loop.flushFrame(host);
    try std.testing.expectEqual(@as(i32, 2), try host.evalInt("globalThis.paints"));
}

test "import a file beside the entry" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "util.js", .data = "export const n = 9;\n" });
    var root_buf: [std.fs.max_path_bytes]u8 = undefined;
    const root_len = try tmp.dir.realPath(std.testing.io, &root_buf);
    const root = root_buf[0..root_len];

    const host = support.createHost();
    defer support.destroyHost(host);

    var entry_buf: [std.fs.max_path_bytes]u8 = undefined;
    const entry = try std.fmt.bufPrintZ(&entry_buf, "{s}/index.js", .{root});
    try host.evalModule("import { n } from './util.js'; globalThis.result = n;", entry);
    try std.testing.expectEqual(@as(i32, 9), try host.evalInt("globalThis.result"));
}

test "a file outside the entry directory loads" {
    var inside = std.testing.tmpDir(.{});
    defer inside.cleanup();
    var outside = std.testing.tmpDir(.{});
    defer outside.cleanup();
    try outside.dir.writeFile(std.testing.io, .{ .sub_path = "shared.js", .data = "export const n = 4;\n" });

    var root_buf: [std.fs.max_path_bytes]u8 = undefined;
    const root_len = try inside.dir.realPath(std.testing.io, &root_buf);
    const root = root_buf[0..root_len];
    var shared_buf: [std.fs.max_path_bytes]u8 = undefined;
    const shared_len = try outside.dir.realPathFile(std.testing.io, "shared.js", &shared_buf);
    const shared = shared_buf[0..shared_len];

    const host = support.createHost();
    defer support.destroyHost(host);
    var entry_buf: [std.fs.max_path_bytes]u8 = undefined;
    const entry = try std.fmt.bufPrintZ(&entry_buf, "{s}/index.js", .{root});
    var src_buf: [std.fs.max_path_bytes + 64]u8 = undefined;
    const src = try std.fmt.bufPrintZ(&src_buf, "import {{ n }} from '{s}'; globalThis.result = n;", .{shared});
    try host.evalModule(src, entry);
    try std.testing.expectEqual(@as(i32, 4), try host.evalInt("globalThis.result"));
}

test "an oversize module file does not load" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(std.testing.io, .{
        .sub_path = "big.js",
        .data = "export const n = 1;\n",
    });
    var root_buf: [std.fs.max_path_bytes]u8 = undefined;
    const root_len = try tmp.dir.realPath(std.testing.io, &root_buf);
    const root = root_buf[0..root_len];

    var pool: support.Pool = .{ .backing_allocator = std.testing.allocator };
    defer _ = pool.deinit();
    const host = Host.createWith(pool.allocator(), std.testing.io, .{ .max_file_bytes = 8, .cwd = "", .execution = support.hostOptions("").execution });
    defer host.destroy();
    var entry_buf: [std.fs.max_path_bytes]u8 = undefined;
    const entry = try std.fmt.bufPrintZ(&entry_buf, "{s}/index.js", .{root});
    try std.testing.expectError(
        error.JavaScriptFault,
        host.evalModule("import { n } from './big.js';", entry),
    );
}

test "every baked module reads back from its bytecode under its own name" {
    const host = support.createHost();
    defer support.destroyHost(host);
    try std.testing.expect(default_baked.len > 0);
    for (default_baked) |m| {
        const value = host.ctx.readObject(m.code.bytecode, .{ .bytecode = true });
        const module = host.ctx.moduleFromValue(value) orelse return error.UnreadableBytecode;
        const atom = host.ctx.getModuleName(module);
        defer host.ctx.freeAtom(atom);
        const name = try host.ctx.atomToCStringLen(atom);
        defer host.ctx.freeCString(name.ptr);
        try std.testing.expectEqualStrings(m.name, name);
    }
}

test "every native name the bake stubs is a module a host installs" {
    const host = support.createHost();
    defer support.destroyHost(host);
    const native = baked.native;
    try std.testing.expect(native.len > 0);
    for (native) |name| {
        var source: [128]u8 = undefined;
        try host.evalModule(try std.fmt.bufPrintZ(&source, "import \"{s}\";", .{name}), "native.js");
    }
}

test "a stack trace from a baked module keeps its line numbers" {
    const host = support.createHost();
    defer support.destroyHost(host);
    try host.evalModule(
        \\import { grow } from "yuke:layout";
        \\try { grow(0); } catch (error) { globalThis.stack = String(error.stack); }
    , "stack.js");
    const value = try host.ctx.eval("globalThis.stack", "read-stack.js", .{});
    defer host.ctx.freeValue(value);
    const stack = try host.ctx.toCStringLen(value);
    defer host.ctx.freeCString(stack.ptr);
    const at = std.mem.indexOf(u8, stack, "yuke:layout:") orelse return error.MissingBakedFrame;
    try std.testing.expect(std.ascii.isDigit(stack[at + "yuke:layout:".len]));
}

test {
    _ = @import("loop.zig");
    _ = @import("driver.zig");
    _ = @import("report.zig");
    _ = @import("native/engine.zig");
    _ = @import("native/fs.zig");
    _ = @import("native/exec.zig");
    _ = @import("native/diff.zig");
    _ = @import("native/tools.zig");
    _ = @import("native/hooks.zig");
    _ = @import("tools.zig");
    _ = @import("call_run.zig");
    _ = @import("hooks.zig");
    _ = @import("tests/app_test.zig");
    _ = @import("tests/ui_test.zig");
    _ = @import("tests/plugins_test.zig");
    _ = @import("tests/native_tools_test.zig");
    _ = @import("tests/net_test.zig");
    _ = @import("tests/http_test.zig");
    _ = @import("tests/mcp_test.zig");
    _ = @import("native/mcp.zig");
    _ = @import("native/oauth.zig");
    _ = @import("timers.zig");
    _ = @import("native/jobs.zig");
    _ = @import("tests/interaction_test.zig");
}

const support = @import("tests/support.zig");
const TestPaint = @import("tests/paint.zig").Paint;
const loop = @import("loop.zig");
