const std = @import("std");
const builtin = @import("builtin");
const quickjs = @import("quickjs");
const zio = @import("zio");
const term_pkg = @import("term");
const loader_mod = @import("loader.zig");
const term_module = @import("modules/term.zig");
const client_module = @import("modules/client.zig");

pub const loader = loader_mod;
pub const term = term_module;

/// Limit the client heap. Scripts fail when they exceed this limit.
pub const memory_limit: usize = 64 * 1024 * 1024;
/// Limit the QuickJS stack below the zio coroutine stack.
pub const stack_limit: usize = 4 * 1024 * 1024;
/// Limit jobs per drain so Promise chains do not starve the owner.
pub const job_budget: u32 = 1024;
/// Bound one evaluation or callback by interrupt polls, a coarse CPU proxy. Wall time is not used,
/// so scheduling jitter never aborts a script. QuickJS polls about every 10000 bytecode operations.
pub const default_interrupt_budget: u32 = 100_000;
/// Limit the fault text that the Host stores.
/// A fixed buffer lets `captureFault` run without an allocation.
pub const fault_text_max: usize = 512;
/// Report this when QuickJS gives no readable text for the exception.
pub const unknown_fault = "script fault with no message";

pub const Error = error{
    OutOfMemory,
    JavaScriptFault,
};

pub const default_baked = [_]loader_mod.BakedModule{
    .{ .name = "yuke:core", .source = @embedFile("js/core.js") },
    .{ .name = "yuke:ext", .source = @embedFile("js/ext.js") },
    .{ .name = "yuke:md", .source = @embedFile("js/md.js") },
    .{ .name = "yuke:ui", .source = @embedFile("js/ui.js") },
    .{ .name = "yuke:client", .source = @embedFile("js/client.js") },
    .{ .name = "yuke:vim", .source = @embedFile("js/vim.js") },
    .{ .name = "yuke:notice", .source = @embedFile("js/notice.js") },
    .{ .name = "yuke:sidebar", .source = @embedFile("js/sidebar.js") },
    .{ .name = "yuke:command-ui", .source = @embedFile("js/command-ui.js") },
    .{ .name = "yuke:catalog", .source = @embedFile("js/catalog.js") },
    .{ .name = "yuke:chat", .source = @embedFile("js/chat.js") },
    .{ .name = "yuke:fzy", .source = @embedFile("js/fzy.js") },
    .{ .name = "yuke:transcript", .source = @embedFile("js/transcript.js") },
    .{ .name = "yuke:explorer", .source = @embedFile("js/explorer.js") },
    .{ .name = "yuke:composer-vim", .source = @embedFile("js/composer-vim.js") },
    .{ .name = "yuke:transcript-vim", .source = @embedFile("js/transcript-vim.js") },
    .{ .name = "yuke:defaults", .source = @embedFile("js/defaults.js") },
};

pub const Options = struct {
    /// An empty slice uses `default_baked`. A non-empty slice replaces it.
    baked: []const loader_mod.BakedModule = &.{},
    max_file_bytes: usize = loader_mod.default_max_file_bytes,
    /// The directory the TUI runs in. A new session takes it as the workspace root.
    cwd: []const u8 = "",
};

/// State shared by the renderer and the `yuke:term` module.
pub const Paint = struct {
    render: ?*term_pkg.Render = null,
    writer: ?*std.Io.Writer = null,
    width: u16 = 80,
    height: u16 = 24,
    dirty: bool = false,
    in_frame: bool = false,
    /// True while the owner drains its queue. The frame then paints once, after the last event.
    defer_frame: bool = false,
    needs_tick: bool = false,
    tick_period_ms: u32 = 450,
    quit_requested: bool = false,
    /// The reactor tick task waits on this. `setNeedsTick` wakes it when a tick arms or the period changes.
    /// Null outside `app.run` (tests do not run the tick task).
    tick_wake: ?*zio.ResetEvent = null,
    term_obj: quickjs.Value = quickjs.UNDEFINED,
    size_obj: quickjs.Value = quickjs.UNDEFINED,
    /// Own grapheme bytes for the open frame. Reset after the grid clears.
    glyphs: std.heap.ArenaAllocator = undefined,
};

/// Own one QuickJS runtime and context. The TUI owner calls `eval` and `destroy`.
pub const Host = struct {
    gpa: std.mem.Allocator,
    runtime: *quickjs.Runtime,
    ctx: quickjs.Context,
    loader: loader_mod.Loader,
    phase: Phase,
    interrupt_budget: u32,
    interrupt_count: u32,
    budget: u32,
    /// Hold the last script fault text. The Host owns these bytes and `report.zig` paints them.
    fault_text: [fault_text_max]u8,
    fault_text_len: usize,
    paint: Paint,
    /// Client state for `yuke:client-native`.
    client: *client_module.Client,
    /// The directory the TUI runs in. The caller owns these bytes for the life of the host.
    cwd: []const u8,

    pub const Phase = enum { open, closing, drained, destroyed };

    /// Allocate a host with the test I/O.
    pub fn create(gpa: std.mem.Allocator) Error!*Host {
        std.debug.assert(builtin.is_test);
        return createWith(gpa, std.testing.io, .{});
    }

    /// Allocate a host and install its limits, interrupt handler, and loader.
    pub fn createWith(gpa: std.mem.Allocator, io: std.Io, opts: Options) Error!*Host {
        const self = try gpa.create(Host);
        errdefer gpa.destroy(self);

        const runtime = quickjs.Runtime.init(gpa) catch return error.OutOfMemory;
        errdefer runtime.deinit();
        runtime.setMemoryLimit(memory_limit);
        runtime.setMaxStackSize(stack_limit);

        const ctx = quickjs.Context.init(runtime);
        if (ctx.ptr == null) return error.OutOfMemory;
        errdefer ctx.deinit();

        const baked: []const loader_mod.BakedModule = if (opts.baked.len == 0) &default_baked else opts.baked;
        var ld: loader_mod.Loader = .{
            .gpa = gpa,
            .io = io,
            .baked = baked,
            .max_file_bytes = opts.max_file_bytes,
        };
        errdefer ld.deinit();

        const cl = client_module.Client.create(gpa, io) catch return error.OutOfMemory;
        errdefer cl.destroy();

        self.* = .{
            .gpa = gpa,
            .runtime = runtime,
            .ctx = ctx,
            .loader = ld,
            .phase = .open,
            .interrupt_budget = default_interrupt_budget,
            .interrupt_count = 0,
            .budget = job_budget,
            .fault_text = undefined,
            .fault_text_len = 0,
            .paint = .{ .glyphs = .init(gpa) },
            .client = cl,
            .cwd = opts.cwd,
        };
        errdefer self.paint.glyphs.deinit();
        runtime.setRuntimeOpaque(self);
        ctx.setContextOpaque(self);
        runtime.setInterruptHandler(self);
        runtime.setModuleLoader(&self.loader);
        try term_module.install(self);
        try client_module.install(self);
        return self;
    }

    /// Drain jobs, release QuickJS resources, and destroy the host.
    pub fn destroy(self: *Host) void {
        std.debug.assert(self.phase != .destroyed);
        if (self.phase == .open) {
            self.close() catch {};
        }
        self.finishDrain();
        std.debug.assert(self.phase == .drained);
        self.client.destroy();
        self.freePaintRoots();
        self.paint.glyphs.deinit();
        self.ctx.deinit();
        self.runtime.deinit();
        self.loader.deinit();
        const gpa = self.gpa;
        self.phase = .destroyed;
        gpa.destroy(self);
    }

    /// Stop JavaScript work, drain jobs, and close the host.
    pub fn close(self: *Host) Error!void {
        std.debug.assert(self.phase == .open);
        self.phase = .closing;
        // Phase 1: reject pending client promises and free their roots before the final drain.
        self.client.shutdown(self);
        var rounds: u32 = 0;
        while (self.runtime.isJobPending()) {
            try self.drainJobs();
            rounds += 1;
            if (rounds == 16) break;
        }
        if (self.runtime.isJobPending()) return error.JavaScriptFault;
        self.phase = .drained;
    }

    /// Recover the host from a QuickJS context opaque pointer.
    pub fn fromContext(ctx: quickjs.Context) *Host {
        const ptr = ctx.getContextOpaque() orelse unreachable;
        return @ptrCast(@alignCast(ptr));
    }

    /// Apply a terminal size to the renderer and cached JavaScript objects.
    pub fn resize(self: *Host, winsize: term_pkg.Winsize) void {
        std.debug.assert(self.phase == .open);
        if (winsize.cols == 0 or winsize.rows == 0) return;
        if (self.paint.width == winsize.cols and self.paint.height == winsize.rows) return;
        // A failed write after the grid swapped keeps the frame dirty, so the next commit flushes.
        var resize_dirty = false;
        if (self.paint.render) |render| {
            // `bindRender` sets the render and the writer together, so a render implies a writer.
            std.debug.assert(self.paint.writer != null);
            const writer = self.paint.writer.?;
            render.resize(writer, winsize) catch {
                if (render.window().width != winsize.cols or render.window().height != winsize.rows)
                    return;
                resize_dirty = true;
            };
            render.vx.screen.width_method = .unicode;
        }
        self.paint.width = winsize.cols;
        self.paint.height = winsize.rows;
        self.paint.dirty = resize_dirty;
        self.paint.in_frame = false;
        self.syncSizeProps();
    }

    /// Bind a renderer and writer. This path is for tests without a TTY.
    pub fn bindRender(self: *Host, render: *term_pkg.Render, writer: *std.Io.Writer) void {
        std.debug.assert(self.phase == .open);
        render.vx.caps.unicode = .unicode;
        render.vx.screen.width_method = .unicode;
        self.paint.render = render;
        self.paint.writer = writer;
        const win = render.window();
        self.paint.width = win.width;
        self.paint.height = win.height;
        self.syncSizeProps();
    }

    /// Copy the cached size to retained JavaScript objects.
    pub fn syncSizeProps(self: *Host) void {
        const ctx = self.ctx;
        const w = ctx.newInt32(self.paint.width);
        const h = ctx.newInt32(self.paint.height);
        if (!ctx.isUndefined(self.paint.size_obj)) {
            ctx.setPropertyStr(self.paint.size_obj, "w", ctx.dupValue(w)) catch {};
            ctx.setPropertyStr(self.paint.size_obj, "h", ctx.dupValue(h)) catch {};
        }
        if (!ctx.isUndefined(self.paint.term_obj)) {
            ctx.setPropertyStr(self.paint.term_obj, "width", ctx.dupValue(w)) catch {};
            ctx.setPropertyStr(self.paint.term_obj, "height", ctx.dupValue(h)) catch {};
        }
        ctx.freeValue(w);
        ctx.freeValue(h);
    }

    fn freePaintRoots(self: *Host) void {
        if (!self.ctx.isUndefined(self.paint.term_obj)) {
            self.ctx.freeValue(self.paint.term_obj);
            self.paint.term_obj = quickjs.UNDEFINED;
        }
        if (!self.ctx.isUndefined(self.paint.size_obj)) {
            self.ctx.freeValue(self.paint.size_obj);
            self.paint.size_obj = quickjs.UNDEFINED;
        }
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

    /// Evaluate a module on the owner, then drain jobs.
    /// Module evaluation returns a promise, so a top-level throw becomes a rejection.
    pub fn evalModule(self: *Host, source: [:0]const u8, filename: [:0]const u8) Error!void {
        std.debug.assert(self.phase == .open);
        self.enterSlice();
        const value = self.ctx.eval(source, filename, .{ .type = .module }) catch {
            self.noteFault();
            return error.JavaScriptFault;
        };
        defer self.ctx.freeValue(value);
        try self.drainJobs();
        try self.checkModulePromise(value);
    }

    /// Turn a rejected module promise into a fault. QuickJS never throws it at the caller.
    /// No host function returns a promise yet, so a pending module cannot settle later.
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
        const source = (try self.loader.readModule(path)) orelse return false;
        defer self.gpa.free(source);
        try self.evalModule(source, path);
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

    /// Drain up to `budget` jobs. Leave extra jobs queued for the owner.
    pub fn drainJobs(self: *Host) Error!void {
        var n: u32 = 0;
        while (self.runtime.isJobPending()) {
            if (n == self.budget) return;
            self.enterSlice();
            _ = self.runtime.executePendingJob() catch {
                self.noteFault();
                return error.JavaScriptFault;
            };
            n += 1;
        }
    }

    /// QuickJS calls this in the bytecode loop. Do not allocate or run JavaScript.
    /// Apply the deadline in every live phase so close cannot hang.
    pub fn onInterrupt(self: *Host) bool {
        if (self.phase == .destroyed) return true;
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

    /// Copy the exception text into the fixed buffer.
    /// The Host allocates no memory after an out-of-memory fault.
    fn captureFault(self: *Host, exc: quickjs.Value) void {
        std.debug.assert(self.fault_text_len == 0);
        // A conversion can call a user `toString`. A zero budget stops it at the first poll, while
        // a built-in C conversion still runs.
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
        const n = utf8PrefixLen(text, room);
        std.debug.assert(n <= room);
        @memcpy(self.fault_text[self.fault_text_len..][0..n], text[0..n]);
        self.fault_text_len += n;
    }

    /// Drop a pending exception before the next owner turn.
    fn dropPendingException(self: *Host) void {
        if (!self.ctx.hasException()) return;
        const exc = self.ctx.getException();
        self.ctx.freeValue(exc);
    }

    /// Return the last script fault text.
    /// Return an empty slice when the Host has no fault.
    pub fn faultText(self: *const Host) []const u8 {
        std.debug.assert(self.fault_text_len <= self.fault_text.len);
        return self.fault_text[0..self.fault_text_len];
    }

    /// Clear the fault text.
    /// The next successful frame calls `clearFault`.
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

/// Return the longest prefix of `text` that fits in `max` bytes and ends a UTF-8 sequence.
fn utf8PrefixLen(text: []const u8, max: usize) usize {
    if (text.len <= max) return text.len;
    var n = max;
    while (n > 0 and std.unicode.utf8ByteSequenceLength(text[n]) == error.Utf8InvalidStartByte) n -= 1;
    return n;
}

/// Return the text before the first line break. A fault line uses one row.
fn firstLine(text: []const u8) []const u8 {
    const end = std.mem.indexOfAny(u8, text, "\r\n") orelse text.len;
    return std.mem.trim(u8, text[0..end], " \t");
}

test "eval returns an integer" {
    var gpa = std.heap.DebugAllocator(.{}).init;
    defer std.debug.assert(gpa.deinit() == .ok);

    const host = try Host.create(gpa.allocator());
    defer host.destroy();

    try host.eval("globalThis.n = 40 + 2", "smoke.js");
    try std.testing.expectEqual(@as(i32, 42), try host.evalInt("globalThis.n"));
}

test "two hosts do not share globals" {
    var gpa = std.heap.DebugAllocator(.{}).init;
    defer std.debug.assert(gpa.deinit() == .ok);

    const a = try Host.create(gpa.allocator());
    defer a.destroy();
    const b = try Host.create(gpa.allocator());
    defer b.destroy();

    try a.eval("globalThis.n = 1", "a.js");
    try b.eval("globalThis.n = 2", "b.js");
    try std.testing.expectEqual(@as(i32, 1), try a.evalInt("globalThis.n"));
    try std.testing.expectEqual(@as(i32, 2), try b.evalInt("globalThis.n"));
}

test "a syntax error is a JavaScriptFault" {
    var gpa = std.heap.DebugAllocator(.{}).init;
    defer std.debug.assert(gpa.deinit() == .ok);

    const host = try Host.create(gpa.allocator());
    defer host.destroy();
    try std.testing.expectError(error.JavaScriptFault, host.eval("this is not js", "bad.js"));
    try std.testing.expect(std.mem.indexOf(u8, host.faultText(), "bad.js:1") != null);
    try host.eval("globalThis.n = 1", "after.js");
    try std.testing.expectEqual(@as(i32, 1), try host.evalInt("globalThis.n"));
}

test "drainJobs runs a then callback" {
    var gpa = std.heap.DebugAllocator(.{}).init;
    defer std.debug.assert(gpa.deinit() == .ok);

    const host = try Host.create(gpa.allocator());
    defer host.destroy();
    try host.eval("globalThis.hit = 0; Promise.resolve().then(() => { globalThis.hit = 7; })", "job.js");
    try std.testing.expectEqual(@as(i32, 7), try host.evalInt("globalThis.hit"));
}

test "an infinite loop hits the interrupt budget" {
    var gpa = std.heap.DebugAllocator(.{}).init;
    defer std.debug.assert(gpa.deinit() == .ok);

    const host = try Host.create(gpa.allocator());
    defer host.destroy();
    host.interrupt_budget = 0;
    try std.testing.expectError(error.JavaScriptFault, host.eval("while (true) {}", "spin.js"));
    try std.testing.expect(std.mem.indexOf(u8, host.faultText(), "interrupted") != null);
}

test "close interrupts a leftover spinning job" {
    var gpa = std.heap.DebugAllocator(.{}).init;
    defer std.debug.assert(gpa.deinit() == .ok);

    const host = try Host.create(gpa.allocator());
    defer host.destroy();
    host.budget = 0;
    try host.eval("Promise.resolve().then(() => { while (true) {} })", "spin.js");
    try std.testing.expect(host.runtime.isJobPending());
    host.budget = job_budget;
    host.interrupt_budget = 0;
    try std.testing.expectError(error.JavaScriptFault, host.close());
    // The host stopped inside the drain, so it never reached `drained`.
    try std.testing.expectEqual(Host.Phase.closing, host.phase);
    try std.testing.expect(std.mem.indexOf(u8, host.faultText(), "interrupted") != null);
}

test "close drains then destroy frees the runtime" {
    var gpa = std.heap.DebugAllocator(.{}).init;
    defer std.debug.assert(gpa.deinit() == .ok);

    const host = try Host.create(gpa.allocator());
    defer host.destroy();
    host.budget = 0;
    try host.eval("Promise.resolve().then(() => {})", "close.js");
    try std.testing.expect(host.runtime.isJobPending());
    host.budget = job_budget;
    try host.close();
    try std.testing.expectEqual(Host.Phase.drained, host.phase);
    try std.testing.expect(!host.runtime.isJobPending());
}

test "drainJobs yields when the budget is hit" {
    var gpa = std.heap.DebugAllocator(.{}).init;
    defer std.debug.assert(gpa.deinit() == .ok);

    const host = try Host.create(gpa.allocator());
    defer host.destroy();
    host.budget = 1;
    try host.eval(
        \\globalThis.n = 0;
        \\Promise.resolve().then(() => { globalThis.n++; }).then(() => { globalThis.n++; });
    , "budget.js");
    try std.testing.expect(host.runtime.isJobPending());
    try std.testing.expectEqual(@as(usize, 0), host.faultText().len);
    try host.drainJobs();
    try std.testing.expectEqual(@as(i32, 2), try host.evalInt("globalThis.n"));
}

test "a memory-limit hit is a catchable fault" {
    var gpa = std.heap.DebugAllocator(.{}).init;
    defer std.debug.assert(gpa.deinit() == .ok);

    const host = try Host.create(gpa.allocator());
    defer host.destroy();
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
    var gpa = std.heap.DebugAllocator(.{}).init;
    defer std.debug.assert(gpa.deinit() == .ok);

    const host = try Host.create(gpa.allocator());
    defer host.destroy();
    try std.testing.expectError(
        error.JavaScriptFault,
        host.evalModule("await new Promise(() => {});", "hang.js"),
    );
    try std.testing.expect(std.mem.indexOf(u8, host.faultText(), "did not settle") != null);
}

test "a rejected module reports the reason" {
    var gpa = std.heap.DebugAllocator(.{}).init;
    defer std.debug.assert(gpa.deinit() == .ok);

    const host = try Host.create(gpa.allocator());
    defer host.destroy();
    try std.testing.expectError(
        error.JavaScriptFault,
        host.evalModule("throw new Error('top level');", "reject.js"),
    );
    try std.testing.expect(std.mem.indexOf(u8, host.faultText(), "top level") != null);
}

test "fault text truncates on a UTF-8 boundary" {
    var gpa = std.heap.DebugAllocator(.{}).init;
    defer std.debug.assert(gpa.deinit() == .ok);

    const host = try Host.create(gpa.allocator());
    defer host.destroy();
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
    var gpa = std.heap.DebugAllocator(.{}).init;
    defer std.debug.assert(gpa.deinit() == .ok);

    const host = try Host.create(gpa.allocator());
    defer host.destroy();
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
    var gpa = std.heap.DebugAllocator(.{}).init;
    defer std.debug.assert(gpa.deinit() == .ok);

    const host = try Host.create(gpa.allocator());
    defer host.destroy();
    try std.testing.expectError(
        error.JavaScriptFault,
        host.evalModule("import { n } from 'yuke:missing';", "entry.js"),
    );
}

test "resize keeps unicode width after a write fail" {
    var gpa = std.heap.DebugAllocator(.{}).init;
    defer std.debug.assert(gpa.deinit() == .ok);

    var env_map = try std.testing.environ.createMap(gpa.allocator());
    defer env_map.deinit();
    var render = try term_pkg.Render.init(std.testing.io, gpa.allocator(), &env_map, .{});
    var sink: std.Io.Writer.Allocating = .init(gpa.allocator());
    defer sink.deinit();
    defer render.deinit(&sink.writer);
    try render.resize(&sink.writer, .{ .rows = 2, .cols = 4, .x_pixel = 0, .y_pixel = 0 });

    var fail: std.Io.Writer = .failing;
    const host = try Host.create(gpa.allocator());
    defer host.destroy();
    host.bindRender(&render, &fail);
    // Only `resize` can put the method back, so the assertion cannot pass on `bindRender` alone.
    render.vx.screen.width_method = .wcwidth;
    host.resize(.{ .rows = 3, .cols = 8, .x_pixel = 0, .y_pixel = 0 });
    try std.testing.expectEqual(term_pkg.gwidth.Method.unicode, render.vx.screen.width_method);
    try std.testing.expectEqual(@as(u16, 8), host.paint.width);
    try std.testing.expectEqual(@as(u16, 3), host.paint.height);
}

test "an event asks for a frame and the flush paints it once" {
    var gpa = std.heap.DebugAllocator(.{}).init;
    defer std.debug.assert(gpa.deinit() == .ok);

    var env_map = try std.testing.environ.createMap(gpa.allocator());
    defer env_map.deinit();
    var render = try term_pkg.Render.init(std.testing.io, gpa.allocator(), &env_map, .{});
    var sink: std.Io.Writer.Allocating = .init(gpa.allocator());
    defer sink.deinit();
    defer render.deinit(&sink.writer);
    try render.resize(&sink.writer, .{ .rows = 2, .cols = 8, .x_pixel = 0, .y_pixel = 0 });

    var out: std.Io.Writer.Allocating = .init(gpa.allocator());
    defer out.deinit();
    const host = try Host.create(gpa.allocator());
    defer host.destroy();
    host.bindRender(&render, &out.writer);

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

    const loop = @import("loop.zig");
    // A deferred run applies three keys and paints once.
    host.paint.defer_frame = true;
    for (0..3) |_| try loop.step(host, .{ .key_press = .{ .codepoint = 'a' } });
    try std.testing.expectEqual(@as(i32, 0), try host.evalInt("globalThis.paints"));
    host.paint.defer_frame = false;
    try loop.flushFrame(host);
    try std.testing.expectEqual(@as(i32, 1), try host.evalInt("globalThis.paints"));

    // A second flush with no new event paints nothing.
    try loop.flushFrame(host);
    try std.testing.expectEqual(@as(i32, 1), try host.evalInt("globalThis.paints"));

    // Outside a deferred run, one event still paints on its own.
    try loop.step(host, .{ .key_press = .{ .codepoint = 'a' } });
    try std.testing.expectEqual(@as(i32, 2), try host.evalInt("globalThis.paints"));
}

test "import a file beside the entry" {
    var gpa = std.heap.DebugAllocator(.{}).init;
    defer std.debug.assert(gpa.deinit() == .ok);

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "util.js", .data = "export const n = 9;\n" });
    var root_buf: [std.fs.max_path_bytes]u8 = undefined;
    const root_len = try tmp.dir.realPath(std.testing.io, &root_buf);
    const root = root_buf[0..root_len];

    const host = try Host.createWith(gpa.allocator(), std.testing.io, .{});
    defer host.destroy();

    var entry_buf: [std.fs.max_path_bytes]u8 = undefined;
    const entry = try std.fmt.bufPrintZ(&entry_buf, "{s}/index.js", .{root});
    try host.evalModule("import { n } from './util.js'; globalThis.result = n;", entry);
    try std.testing.expectEqual(@as(i32, 9), try host.evalInt("globalThis.result"));
}

test "a file outside the entry directory loads" {
    var gpa = std.heap.DebugAllocator(.{}).init;
    defer std.debug.assert(gpa.deinit() == .ok);

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

    const host = try Host.createWith(gpa.allocator(), std.testing.io, .{});
    defer host.destroy();
    var entry_buf: [std.fs.max_path_bytes]u8 = undefined;
    const entry = try std.fmt.bufPrintZ(&entry_buf, "{s}/index.js", .{root});
    var src_buf: [std.fs.max_path_bytes + 64]u8 = undefined;
    const src = try std.fmt.bufPrintZ(&src_buf, "import {{ n }} from '{s}'; globalThis.result = n;", .{shared});
    try host.evalModule(src, entry);
    try std.testing.expectEqual(@as(i32, 4), try host.evalInt("globalThis.result"));
}

test "an oversize module file does not load" {
    var gpa = std.heap.DebugAllocator(.{}).init;
    defer std.debug.assert(gpa.deinit() == .ok);

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(std.testing.io, .{
        .sub_path = "big.js",
        .data = "export const n = 1;\n",
    });
    var root_buf: [std.fs.max_path_bytes]u8 = undefined;
    const root_len = try tmp.dir.realPath(std.testing.io, &root_buf);
    const root = root_buf[0..root_len];

    const host = try Host.createWith(gpa.allocator(), std.testing.io, .{ .max_file_bytes = 8 });
    defer host.destroy();
    var entry_buf: [std.fs.max_path_bytes]u8 = undefined;
    const entry = try std.fmt.bufPrintZ(&entry_buf, "{s}/index.js", .{root});
    try std.testing.expectError(
        error.JavaScriptFault,
        host.evalModule("import { n } from './big.js';", entry),
    );
}

test {
    _ = @import("loop.zig");
    _ = @import("app.zig");
    _ = @import("report.zig");
    _ = @import("owner.zig");
    _ = @import("modules/client.zig");
    _ = @import("host_js_test.zig");
}
