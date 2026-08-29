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
    .{ .name = "yuke:defaults", .source = @embedFile("js/defaults.js") },
};

pub const Options = struct {
    /// An empty slice uses `default_baked`. A non-empty slice replaces it.
    baked: []const loader_mod.BakedModule = &.{},
    max_file_bytes: usize = loader_mod.default_max_file_bytes,
};

/// State shared by the renderer and the `yuke:term` module.
pub const Paint = struct {
    render: ?*term_pkg.Render = null,
    writer: ?*std.Io.Writer = null,
    width: u16 = 80,
    height: u16 = 24,
    dirty: bool = false,
    in_frame: bool = false,
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
    host.budget = 0;
    try host.eval("Promise.resolve().then(() => {})", "close.js");
    try std.testing.expect(host.runtime.isJobPending());
    host.budget = job_budget;
    try host.close();
    try std.testing.expectEqual(Host.Phase.drained, host.phase);
    try std.testing.expect(!host.runtime.isJobPending());
    host.destroy();
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

test "yuke:core clip wrap and style.resolve" {
    var gpa = std.heap.DebugAllocator(.{}).init;
    defer std.debug.assert(gpa.deinit() == .ok);
    const host = try Host.create(gpa.allocator());
    defer host.destroy();
    try host.evalModule(
        \\import { clip, wrap, style } from "yuke:core";
        \\const lines = wrap("hello world\n\nabcdef", 5);
        \\const before = style.resolve("Normal").fg;
        \\style.palette.fg = "red";
        \\const stale = style.resolve("Normal").fg;
        \\style.invalidate();
        \\globalThis.result = (
        \\  clip("", 3) === "" &&
        \\  clip("abc", 0) === "" &&
        \\  clip("abc", 10) === "abc" &&
        \\  clip("abc", 1) === "a" &&
        \\  clip("abcd", 3) === "ab…" &&
        \\  clip("中文", 3) === "中…" &&
        \\  lines.length === 5 &&
        \\  lines[0] === "hello" &&
        \\  lines[1] === "world" &&
        \\  lines[2] === "" &&
        \\  lines[3] === "abcde" &&
        \\  lines[4] === "f" &&
        \\  before === "reset" &&
        \\  stale === "reset" &&
        \\  style.resolve("Normal").fg === "red" &&
        \\  style.resolve("YukeHeader").fg === "red" &&
        \\  style.resolve("YukeHeader").dim === true &&
        \\  style.resolve("YukeBrand").bold === true
        \\) ? 1 : 0;
    , "core.js");
    try std.testing.expectEqual(@as(i32, 1), try host.evalInt("globalThis.result"));
}

test "yuke:core wrapOffsets keeps every byte and caretRowCol places the caret" {
    var gpa = std.heap.DebugAllocator(.{}).init;
    defer std.debug.assert(gpa.deinit() == .ok);
    const host = try Host.create(gpa.allocator());
    defer host.destroy();
    try host.evalModule(
        \\import { wrapOffsets, caretRowCol } from "yuke:core";
        \\const join = (s, rows) => rows.map((r) => s.slice(r.start, r.end)).join("|");
        \\// A row plus its break covers the whole string, so no byte is lost.
        \\const covers = (s, rows) => {
        \\  let out = "";
        \\  for (let i = 0; i < rows.length; i++) {
        \\    out += s.slice(rows[i].start, rows[i].end);
        \\    if (i + 1 < rows.length && !rows[i].soft) out += "\n";
        \\  }
        \\  return out === s;
        \\};
        \\const indent = "  keep   spaces";
        \\const para = "hello world";
        \\const rows = wrapOffsets(para, 5);
        \\globalThis.result = (
        \\  join(para, rows) === "hello |world" &&
        \\  rows[0].soft === true &&
        \\  covers(para, rows) &&
        \\  covers(indent, wrapOffsets(indent, 7)) &&
        \\  join(indent, wrapOffsets(indent, 7)) === "  keep   |spaces" &&
        \\  join("abcdefghij", wrapOffsets("abcdefghij", 4)) === "abcd|efgh|ij" &&
        \\  join("a\nb", wrapOffsets("a\nb", 9)) === "a|b" &&
        \\  wrapOffsets("a\nb", 9)[0].soft === false &&
        \\  covers("a\nb", wrapOffsets("a\nb", 9)) &&
        \\  join("", wrapOffsets("", 5)) === "" &&
        \\  covers("one\n\ntwo words", wrapOffsets("one\n\ntwo words", 4)) &&
        \\  caretRowCol(para, rows, 0).row === 0 &&
        \\  caretRowCol(para, rows, 3).col === 3 &&
        \\  caretRowCol(para, rows, 6).row === 1 &&
        \\  caretRowCol(para, rows, 6).col === 0 &&
        \\  caretRowCol(para, rows, 11).row === 1 &&
        \\  caretRowCol(para, rows, 11).col === 5
        \\) ? 1 : 0;
    , "wrap.js");
    try std.testing.expectEqual(@as(i32, 1), try host.evalInt("globalThis.result"));
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

test "yuke:core RootView paints and q quits" {
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
        \\import { View, root, text } from "yuke:core";
        \\class Hello extends View {
        \\  get name() { return "hello"; }
        \\  draw() { text(this.rect.x, this.rect.y, "hi", "Normal"); }
        \\}
        \\root.setActive(new Hello());
    , "ui.js");
    const loop = @import("loop.zig");
    try loop.start(host);
    try std.testing.expect(std.mem.indexOf(u8, out.written(), "hi") != null);
    try loop.step(host, .{ .key_press = .{ .codepoint = 'q' } });
    try std.testing.expect(host.paint.quit_requested);
}

test "wrap keeps an unsplittable grapheme on its own line" {
    var gpa = std.heap.DebugAllocator(.{}).init;
    defer std.debug.assert(gpa.deinit() == .ok);

    const host = try Host.create(gpa.allocator());
    defer host.destroy();
    try host.evalModule(
        \\import { wrap } from "yuke:core";
        \\const eq = (a, b) => JSON.stringify(a) === JSON.stringify(b);
        \\globalThis.result = (
        \\  eq(wrap("abcd", 1), ["a", "b", "c", "d"]) &&
        \\  eq(wrap("ab\u4e2dcd", 3), ["ab", "\u4e2dc", "d"]) &&
        \\  eq(wrap("\u4e2d\u4e2d", 1), ["\u4e2d", "\u4e2d"]) &&
        \\  eq(wrap("\ud83d\udc69\u200d\ud83d\udcbb", 1), ["\ud83d\udc69\u200d\ud83d\udcbb"])
        \\) ? 1 : 0;
    , "wrap.js");
    try std.testing.expectEqual(@as(i32, 1), try host.evalInt("globalThis.result"));
}

test "yuke:ext kernel: scope, advice, services, and the plugin lifecycle" {
    var gpa = std.heap.DebugAllocator(.{}).init;
    defer std.debug.assert(gpa.deinit() == .ok);

    const host = try Host.create(gpa.allocator());
    defer host.destroy();
    try host.evalModule(
        \\import { command, keymap, events, Emitter } from "yuke:core";
        \\import { Scope, Context, advice, services, plugins } from "yuke:ext";
        \\const fail = [];
        \\const check = (name, cond) => { if (!cond) fail.push(name); };
        \\
        \\// A scope reverts its effects newest first.
        \\{
        \\  const order = [];
        \\  const s = new Scope("t");
        \\  s.effect(() => { order.push("a-set"); return () => order.push("a"); });
        \\  s.effect(() => { order.push("b-set"); return () => order.push("b"); });
        \\  s.effect(() => { order.push("c-set"); return () => order.push("c"); });
        \\  s.dispose();
        \\  check("lifo", order.join(",") === "a-set,b-set,c-set,c,b,a");
        \\}
        \\
        \\// A disposer cleans up once, by hand or through dispose.
        \\{
        \\  let n = 0;
        \\  const s = new Scope("t2");
        \\  const off = s.effect(() => () => n++);
        \\  off(); off();
        \\  s.dispose();
        \\  check("effect-idempotent", n === 1);
        \\}
        \\
        \\// A throwing teardown reports on the bus and never stops the rest.
        \\{
        \\  const seen = [];
        \\  const off = events.on("ext:error", (e, name) => seen.push(name));
        \\  const s = new Scope("t3");
        \\  s.effect(() => () => { throw new Error("boom"); });
        \\  s.effect(() => () => seen.push("after"));
        \\  s.dispose();
        \\  off();
        \\  check("dispose-isolate", seen.join(",") === "after,t3");
        \\}
        \\
        \\// emit runs every listener and isolates a throwing one.
        \\{
        \\  const em = new Emitter();
        \\  em.onError = () => {};
        \\  let hits = 0;
        \\  em.on("x", () => { hits++; throw new Error("boom"); });
        \\  em.on("x", () => { hits++; });
        \\  em.emit("x");
        \\  check("emit-isolate", hits === 2);
        \\}
        \\
        \\// bail stops at the first listener that claims the event.
        \\{
        \\  const em = new Emitter();
        \\  const seen = [];
        \\  em.on("k", () => { seen.push(1); });
        \\  em.on("k", () => { seen.push(2); return "claimed"; });
        \\  em.on("k", () => { seen.push(3); });
        \\  check("bail", em.bail("k") === "claimed" && seen.join(",") === "1,2");
        \\}
        \\
        \\// Context.on subscribes on the shared bus and goes away with its scope.
        \\{
        \\  const s = new Scope("t5");
        \\  const ctx = new Context(s, "p5");
        \\  let got = 0;
        \\  ctx.on("evt5", () => got++);
        \\  events.emit("evt5");
        \\  s.dispose();
        \\  events.emit("evt5");
        \\  check("ctx-on-dispose", got === 1);
        \\}
        \\
        \\// command.add returns a disposer that removes exactly what it added.
        \\{
        \\  const off = command.add(null, { "test:cmd6": () => {} });
        \\  const present = !!command.map["test:cmd6"];
        \\  off();
        \\  check("command-dispose", present && !command.map["test:cmd6"]);
        \\}
        \\
        \\// keymap.add removes the bind and clears a prefix nothing uses.
        \\{
        \\  const off = keymap.add({ "ctrl+x g": () => true });
        \\  const hadPrefix = keymap.prefixes["ctrl+x"] === true;
        \\  off();
        \\  check("keymap-dispose", hadPrefix && !keymap.map["ctrl+x g"] && !keymap.prefixes["ctrl+x"]);
        \\}
        \\
        \\// advice folds before, around, filterReturn, and after, then restores on removal.
        \\{
        \\  const obj = { hits: [], greet(n) { this.hits.push("orig:" + n); return "hi " + n; } };
        \\  const original = obj.greet;
        \\  const offs = [
        \\    advice.advise(obj, "greet", "before", function (n) { this.hits.push("before:" + n); }, { owner: "o", name: "b" }),
        \\    advice.advise(obj, "greet", "after", function (n) { this.hits.push("after:" + n); }, { owner: "o", name: "a" }),
        \\    advice.advise(obj, "greet", "around", function (orig, n) { return orig(n.toUpperCase()); }, { owner: "o", name: "ar" }),
        \\    advice.advise(obj, "greet", "filterReturn", function (r) { return r + "!"; }, { owner: "o", name: "f" }),
        \\  ];
        \\  const out = obj.greet("bob");
        \\  check("advice-compose", out === "hi BOB!" && obj.hits.join(",") === "before:bob,orig:BOB,after:bob");
        \\  for (const off of offs) off();
        \\  check("advice-restore", obj.greet === original);
        \\}
        \\
        \\// Advice with no `around` still folds the other kinds.
        \\{
        \\  const obj = { log: [], f(n) { this.log.push("orig:" + n); return n; } };
        \\  const off = advice.advise(obj, "f", "filterReturn", (r) => r * 2, { owner: "o", name: "d" });
        \\  check("advice-no-around", obj.f(3) === 6 && obj.log.join(",") === "orig:3");
        \\  off();
        \\}
        \\
        \\// The same owner and name replaces in place rather than stacking.
        \\{
        \\  const obj = { log: [], f() { this.log.push("orig"); } };
        \\  advice.advise(obj, "f", "before", function () { this.log.push("v1"); }, { owner: "o", name: "n" });
        \\  const off2 = advice.advise(obj, "f", "before", function () { this.log.push("v2"); }, { owner: "o", name: "n" });
        \\  const replaced = advice.list(obj, "f").length === 1;
        \\  obj.f();
        \\  off2();
        \\  check("advice-replace", replaced && obj.log.join(",") === "v2,orig" && advice.list(obj, "f").length === 0);
        \\}
        \\
        \\// A service announces its arrival and its withdrawal.
        \\{
        \\  const seen = [];
        \\  const off = events.on("service:svc", (v) => seen.push(v === undefined ? "gone" : v));
        \\  const drop = services.provide("svc", "here");
        \\  const got = services.get("svc");
        \\  drop();
        \\  off();
        \\  check("service", got === "here" && seen.join(",") === "here,gone" && services.get("svc") === undefined);
        \\}
        \\
        \\// A plugin registers on use, reverts on dispose, and comes back on reload.
        \\{
        \\  const p = { name: "demo9", apply(ctx) { ctx.command(null, { act: () => {} }); } };
        \\  plugins.use(p);
        \\  const present = !!command.map["demo9:act"];
        \\  plugins.dispose("demo9");
        \\  const gone = !command.map["demo9:act"];
        \\  plugins.use(p);
        \\  const back = !!command.map["demo9:act"];
        \\  plugins.dispose("demo9");
        \\  check("plugin-lifecycle", present && gone && back);
        \\}
        \\
        \\// A second use of a live name disposes the first, so nothing stacks on reload.
        \\{
        \\  let disposals = 0;
        \\  const p = { name: "dup", apply(ctx) { ctx.effect(() => () => disposals++); } };
        \\  plugins.use(p);
        \\  plugins.use(p);
        \\  const once = disposals === 1;
        \\  plugins.dispose("dup");
        \\  check("plugin-reload-disposes", once && disposals === 2 && plugins.names().indexOf("dup") < 0);
        \\}
        \\
        \\// A throwing apply reverts what it already registered and leaves no live plugin.
        \\{
        \\  const bad = { name: "bad", apply(ctx) { ctx.command(null, { act: () => {} }); throw new Error("nope"); } };
        \\  let threw = false;
        \\  try { plugins.use(bad); } catch (e) { threw = true; }
        \\  check("plugin-partial-revert", threw && !command.map["bad:act"] && !plugins.get("bad"));
        \\}
        \\
        \\// A child scope disposes with its parent, newest first.
        \\{
        \\  const order = [];
        \\  const parent = new Scope("p");
        \\  parent.effect(() => () => order.push("parent"));
        \\  const kid = parent.child("kid");
        \\  kid.effect(() => () => order.push("kid"));
        \\  parent.dispose();
        \\  check("scope-child", order.join(",") === "kid,parent" && !kid.alive);
        \\}
        \\
        \\// An effect on a disposed scope throws.
        \\{
        \\  const s = new Scope("dead");
        \\  s.dispose();
        \\  let threw = false;
        \\  try { s.effect(() => {}); } catch (e) { threw = true; }
        \\  check("scope-dead-effect", threw);
        \\}
        \\
        \\// filterArgs rewrites the arguments that the original and `after` both see.
        \\{
        \\  const obj = { log: [], f(a, b) { this.log.push("orig:" + a + b); return a + b; } };
        \\  const off = advice.advise(obj, "f", "filterArgs", (as) => [as[0] * 2, as[1] * 2], { owner: "o", name: "fa" });
        \\  const seen = [];
        \\  const off2 = advice.advise(obj, "f", "after", (a, b) => seen.push(a + "," + b), { owner: "o", name: "af" });
        \\  const out = obj.f(1, 2);
        \\  off(); off2();
        \\  check("advice-filter-args", out === 6 && obj.log.join(",") === "orig:24" && seen.join(",") === "2,4");
        \\}
        \\
        \\// An accessor is not a method, so advise refuses it.
        \\{
        \\  const obj = { get g() { return () => 1; } };
        \\  let threw = false;
        \\  const want = "is an accessor";
        \\  try { advice.advise(obj, "g", "before", () => {}); } catch (e) { threw = e instanceof TypeError && e.message.indexOf(want) >= 0; }
        \\  check("advice-accessor", threw);
        \\}
        \\
        \\// A Context forces its own id as the advice owner and keeps a qualified name intact.
        \\{
        \\  const s = new Scope("t7");
        \\  const ctx = new Context(s, "p7");
        \\  const obj = { f() { return 1; } };
        \\  ctx.advise(obj, "f", "filterReturn", (r) => r + 1, { name: "inc" });
        \\  const owned = advice.list(obj, "f")[0];
        \\  ctx.command(null, { bare: () => {}, "other:kept": () => {} });
        \\  ctx.keymap({ "ctrl+y": "p7:bare" });
        \\  ctx.provide("svc7", 42);
        \\  const ok = owned.owner === "p7" && obj.f() === 2 &&
        \\    !!command.map["p7:bare"] && !!command.map["other:kept"] &&
        \\    !!keymap.map["ctrl+y"] && ctx.use("svc7") === 42;
        \\  s.dispose();
        \\  const gone = !command.map["p7:bare"] && !command.map["other:kept"] &&
        \\    !keymap.map["ctrl+y"] && services.get("svc7") === undefined &&
        \\    obj.f() === 1 && advice.list(obj, "f").length === 0;
        \\  check("context-surface", ok && gone);
        \\}
        \\
        \\globalThis.result = fail.length ? fail.join(",") : "ok";
    , "ext.js");
    const out = try host.ctx.eval("globalThis.result", "r.js", .{});
    defer host.ctx.freeValue(out);
    const text = try host.ctx.toCStringLen(out);
    defer host.ctx.freeCString(text.ptr);
    try std.testing.expectEqualStrings("ok", text);
}

test "yuke:core config validates and TextInput inserts committed text" {
    var gpa = std.heap.DebugAllocator(.{}).init;
    defer std.debug.assert(gpa.deinit() == .ok);

    const host = try Host.create(gpa.allocator());
    defer host.destroy();
    try host.evalModule(
        \\import { config, defineConfig, TextInput } from "yuke:core";
        \\const fail = [];
        \\const check = (name, cond) => { if (!cond) fail.push(name); };
        \\const throws = (fn) => { try { fn(); return false; } catch (e) { return true; } };
        \\
        \\// defineConfig merges values and rejects invalid fields.
        \\defineConfig({ daemon: { host: "10.0.0.1", port: 1234 }, vim: true });
        \\check("cfg-merge", config.daemon.host === "10.0.0.1" && config.daemon.port === 1234 && config.vim === true);
        \\check("cfg-unknown-key", throws(() => defineConfig({ nope: 1 })));
        \\check("cfg-prototype-key", throws(() => defineConfig({ daemon: { toString: undefined } })));
        \\check("cfg-bad-port", throws(() => defineConfig({ daemon: { port: 0 } })));
        \\check("cfg-bad-vim", throws(() => defineConfig({ vim: "yes" })));
        \\// A bad patch changes no config value.
        \\const before = config.daemon.host;
        \\const beforeVim = config.vim;
        \\throws(() => defineConfig({ vim: false, daemon: { host: "9.9.9.9", retryMs: -1 } }));
        \\check("cfg-atomic", config.daemon.host === before && config.vim === beforeVim);
        \\
        \\// TextInput uses committed text before the folded key.
        \\const key = (o) => Object.assign({ type: "key", code: "char", event: "press", char: "", text: "", mods: 0 }, o);
        \\const insert = (evs) => { const ti = new TextInput(); for (const e of evs) ti.onKey(e); return ti.text; };
        \\check("upper", insert([key({ char: "a", text: "A", mods: 1 }), key({ char: "b", text: "B", mods: 1 })]) === "AB");
        \\check("shifted-symbol", insert([key({ char: "1", text: "!", mods: 1 })]) === "!");
        \\check("ime-cjk", insert([key({ char: "あ", text: "あ", mods: 0 })]) === "あ");
        \\check("ime-zwj", insert([key({ char: "👨", text: "👨‍👩‍👧", mods: 0 })]) === "👨‍👩‍👧");
        \\check("fallback-char", insert([key({ char: "x", text: "", mods: 1 })]) === "x");
        \\check("altgr-text", insert([key({ char: "q", text: "@", mods: 6 })]) === "@");
        \\// A command has no committed text.
        \\check("ctrl-no-insert", insert([key({ char: "z", text: "", mods: 4 })]) === "");
        \\
        \\globalThis.result = fail.length ? fail.join(",") : "ok";
    , "cfg.js");
    const out = try host.ctx.eval("globalThis.result", "r.js", .{});
    defer host.ctx.freeValue(out);
    const text = try host.ctx.toCStringLen(out);
    defer host.ctx.freeCString(text.ptr);
    try std.testing.expectEqualStrings("ok", text);
}

test "yuke:md renders the GFM subset and caches finalized blocks" {
    var gpa = std.heap.DebugAllocator(.{}).init;
    defer std.debug.assert(gpa.deinit() == .ok);

    const host = try Host.create(gpa.allocator());
    defer host.destroy();
    try host.evalModule(
        \\import { renderRows, Document } from "yuke:md";
        \\const fail = [];
        \\const check = (name, cond) => { if (!cond) fail.push(name); };
        \\const has = (rows, group, text) => rows.some((r) => r.segments.some((s) => s.group === group && s.text === text));
        \\
        \\check("inline", has(renderRows("hello **bold** and `code`", 80), "MdStrong", "bold") &&
        \\  has(renderRows("x `y` z", 80), "MdCode", "y"));
        \\check("emphasis", has(renderRows("an *word* here", 80), "MdEm", "word"));
        \\check("heading", has(renderRows("# Title", 80), "MdHeading", "Title"));
        \\check("code", has(renderRows("```js\nx=1\n```", 80), "MdCodeBlock", "x=1"));
        \\check("hr", renderRows("---", 80).some((r) => r.segments.some((s) => s.group === "MdRule")));
        \\check("list", has(renderRows("- a\n- b", 80), "MdListMark", "• "));
        \\check("quote", renderRows("> hi", 80).some((r) => r.segments.some((s) => s.group === "MdQuote")));
        \\const noGroup = (rows, group) => !rows.some((r) => r.segments.some((s) => s.group === group));
        \\// An underscore inside a word is not emphasis (code identifiers stay literal).
        \\check("intraword-underscore", noGroup(renderRows("call foo_bar_baz now", 80), "MdEm"));
        \\// A backslash escapes a marker, so it stays literal text.
        \\check("escape", noGroup(renderRows("not \\*bold\\* here", 80), "MdStrong"));
        \\// A link shows its text, never the URL.
        \\{
        \\  const rows = renderRows("see [docs](http://x) ok", 80);
        \\  check("link-text", has(rows, "MdText", "docs") &&
        \\    !rows.some((r) => r.segments.some((s) => s.text.indexOf("http") >= 0)));
        \\}
        \\// Double backticks let inline code hold a backtick.
        \\check("code-backtick", has(renderRows("use ``a`b`` now", 80), "MdCode", "a`b"));
        \\// Triple markers are strong and emphasis together.
        \\check("strong-em", has(renderRows("***wow***", 80), "MdStrongEm", "wow"));
        \\// Nested emphasis: the inner strong span keeps the outer emphasis.
        \\{
        \\  const rows = renderRows("*x **y** z*", 80);
        \\  check("nested-emph", has(rows, "MdStrongEm", "y") && has(rows, "MdEm", "x") && has(rows, "MdEm", "z"));
        \\}
        \\// A malformed link (a space in the destination) stays literal, not dropped.
        \\check("bad-link", renderRows("[foo](bad url)", 80).some((r) => r.segments.some((s) => s.text.indexOf("bad") >= 0)));
        \\// A table renders a column border.
        \\check("table", renderRows("| a | b |\n|---|---|\n| 1 | 2 |", 80).some((r) => r.segments.some((s) => s.group === "MdTableBorder")));
        \\
        \\// A long paragraph wraps to width and keeps every word.
        \\const wrapped = renderRows("alpha bravo charlie delta", 11);
        \\check("wrap", wrapped.length > 1);
        \\
        \\// An unclosed fence stays provisional code and is never cached.
        \\{
        \\  const doc = new Document();
        \\  doc.setText("# H\n\n```\nx=1");
        \\  check("open-fence", has(doc.rows(80), "MdCodeBlock", "x=1"));
        \\  check("open-uncached", !doc._cache.has("```\nx=1"));
        \\  check("final-cached", doc._cache.has("# H"));
        \\}
        \\
        \\// A finalized block keeps its cache entry when the open tail grows.
        \\{
        \\  const doc = new Document();
        \\  doc.setText("# H\n\npara one");
        \\  doc.rows(80);
        \\  doc.setText("# H\n\npara one two");
        \\  const rows = doc.rows(80);
        \\  check("append-heading", has(rows, "MdHeading", "H") && doc._cache.has("# H"));
        \\  check("append-tail", rows.some((r) => r.segments.some((s) => s.text.indexOf("two") >= 0)));
        \\}
        \\
        \\globalThis.result = fail.length ? fail.join(",") : "ok";
    , "md.js");
    const out = try host.ctx.eval("globalThis.result", "r.js", .{});
    defer host.ctx.freeValue(out);
    const text = try host.ctx.toCStringLen(out);
    defer host.ctx.freeCString(text.ptr);
    try std.testing.expectEqualStrings("ok", text);
}

test "yuke:ui List itemHeight, fzy ranking, and Transcript rows" {
    var gpa = std.heap.DebugAllocator(.{}).init;
    defer std.debug.assert(gpa.deinit() == .ok);

    const host = try Host.create(gpa.allocator());
    defer host.destroy();
    try host.evalModule(
        \\import { List, fuzzyMatch, fuzzyRank, Transcript, Picker } from "yuke:ui";
        \\const fail = [];
        \\const check = (name, cond) => { if (!cond) fail.push(name); };
        \\
        \\// A two-line list shows floor(h / itemHeight) items and scrolls in item units.
        \\const l = new List({ items: [0, 1, 2, 3, 4, 5], itemHeight: 2 });
        \\check("visible", l._visible(6) === 3);
        \\l.moveToEdge(1);
        \\check("sel-end", l.selectedIndex() === 5);
        \\l.ensureVisible(6);
        \\check("scroll-bottom", l.scroll === 3);
        \\l.moveToEdge(-1);
        \\l.ensureVisible(6);
        \\check("scroll-top", l.scroll === 0 && l.selectedIndex() === 0);
        \\
        \\// fzy requires a subsequence and prefers a word boundary.
        \\check("nomatch", fuzzyMatch("abc", "xyz") === null);
        \\check("empty", fuzzyMatch("abc", "") === 0);
        \\const ranked = fuzzyRank(["afboo", "foo_bar", "random"], "fb", String);
        \\check("boundary-first", ranked[0] === "foo_bar");
        \\const dog = fuzzyRank(["cat", "dog"], "og", String);
        \\check("subsequence", dog.length === 1 && dog[0] === "dog");
        \\check("over-long-cap", fuzzyMatch("a".repeat(1025), "a") === -Infinity);
        \\// Assigning the query refilters the result list.
        \\const p = new Picker({ items: ["apple", "banana"], filterText: String });
        \\p.query = "ban";
        \\check("picker-refilter", p.list.items.length === 1 && p.list.items[0] === "banana");
        \\
        \\// A user turn is a tinted band with a gutter marker; an assistant turn renders markdown.
        \\const texts = { u1: "hello world", a1: "**bold** text" };
        \\const t = new Transcript({ textOf: (id) => texts[id] || "" });
        \\t.setOutline([{ id: "u1", type: "user" }, { id: "a1", type: "assistant" }], null);
        \\const rows = t.rows(40, 0, 100);
        \\check("user-band", rows.some((r) => r.marker === "⟩" && r.bg === "TxUser"));
        \\check("assistant-md", rows.some((r) => r.segments && r.segments.some((s) => s.group === "MdStrong" && s.text === "bold")));
        \\
        \\// A draft delta re-renders the assistant turn through yuke:md.
        \\texts.a2 = "streamed";
        \\t.setActive("a2");
        \\const rows2 = t.rows(40, 0, 100);
        \\check("draft", rows2.some((r) => r.segments && r.segments.some((s) => s.text.indexOf("streamed") >= 0)));
        \\
        \\globalThis.result = fail.length ? fail.join(",") : "ok";
    , "ui.js");
    const out = try host.ctx.eval("globalThis.result", "r.js", .{});
    defer host.ctx.freeValue(out);
    const text = try host.ctx.toCStringLen(out);
    defer host.ctx.freeCString(text.ptr);
    try std.testing.expectEqualStrings("ok", text);
}

test "yuke:ui Composer grows, pastes in one edit, and owns the vertical keys" {
    var gpa = std.heap.DebugAllocator(.{}).init;
    defer std.debug.assert(gpa.deinit() == .ok);

    const host = try Host.create(gpa.allocator());
    defer host.destroy();
    try host.evalModule(
        \\import { Composer } from "yuke:ui";
        \\const fail = [];
        \\const check = (name, cond) => { if (!cond) fail.push(name); };
        \\const key = (code, extra) => Object.assign({ type: "key", code, char: "", text: "", mods: 0 }, extra);
        \\const paste = (t) => key("paste", { text: t });
        \\
        \\// The prompt takes two cells, so a width of 12 wraps the text at 10.
        \\const c = new Composer({ onSubmit: () => true });
        \\c.rect = { x: 0, y: 0, w: 12, h: 4 };
        \\check("empty-one-row", c.height(12) === 1);
        \\
        \\// One paste is one edit, and the text keeps its newline.
        \\check("paste-taken", c.onKey(paste("hello world\nsecond")) === true);
        \\check("paste-text", c.text === "hello world\nsecond");
        \\check("paste-caret", c.input.caret === c.text.length);
        \\check("grew", c.height(12) === 3);
        \\
        \\// A newline key adds a line. Enter still submits.
        \\c.onKey(key("enter", { mods: 2 }));
        \\check("alt-enter", c.text === "hello world\nsecond\n");
        \\check("grew-again", c.height(12) === 4);
        \\
        \\// The composer never returns false for a vertical key, so the transcript never scrolls.
        \\c.input.caret = c.text.length;
        \\check("up-taken", c.onKey(key("up")) === true);
        \\check("up-moved", c.input.caret < c.text.length);
        \\const mid = c.input.caret;
        \\check("down-taken", c.onKey(key("down")) === true);
        \\check("down-moved", c.input.caret !== mid);
        \\c.input.caret = 0;
        \\c.onKey(key("up"));
        \\check("up-at-top", c.input.caret === 0);
        \\
        \\// The height stops at maxRows for text the user typed.
        \\const big = new Composer();
        \\big.rect = { x: 0, y: 0, w: 12, h: 4 };
        \\big.text = "a\n".repeat(20);
        \\check("capped", big.height(12) === big.maxRows);
        \\
        \\// Submit clears the buffer, so the composer shrinks back to one row.
        \\const sent = [];
        \\const s = new Composer({ onSubmit: (t) => { sent.push(t); } });
        \\s.rect = { x: 0, y: 0, w: 12, h: 4 };
        \\s.onKey(paste("one\ntwo"));
        \\s.onKey(key("enter"));
        \\check("submitted", sent.length === 1 && sent[0] === "one\ntwo");
        \\check("cleared", s.text === "" && s.height(12) === 1);
        \\
        \\// setText fires onChange, so a programmatic set never leaves a stale wrap.
        \\s.text = "a\nb\nc";
        \\check("set-text-rewrapped", s.height(12) === 3);
        \\
        \\// A vertical move holds the goal column across a short row, as vim and helix do.
        \\const goal = new Composer();
        \\goal.rect = { x: 0, y: 0, w: 12, h: 4 };
        \\goal.text = "12345\nx\n12345";
        \\goal.input.caret = 5;
        \\goal.onKey(key("down"));
        \\check("goal-short-row", goal.input.caret === 7);
        \\goal.onKey(key("down"));
        \\check("goal-restored", goal.input.caret === 13);
        \\// A horizontal key drops the goal column.
        \\goal.input.caret = 5;
        \\goal.onKey(key("down"));
        \\goal.onKey(key("left"));
        \\goal.onKey(key("down"));
        \\check("goal-dropped", goal.input.caret === 8);
        \\
        \\globalThis.result = fail.length ? fail.join(",") : "ok";
    , "composer.js");
    const out = try host.ctx.eval("globalThis.result", "r.js", .{});
    defer host.ctx.freeValue(out);
    const text = try host.ctx.toCStringLen(out);
    defer host.ctx.freeCString(text.ptr);
    try std.testing.expectEqualStrings("ok", text);
}

test "yuke:ui Transcript draws markdown segments through the pager" {
    var gpa = std.heap.DebugAllocator(.{}).init;
    defer std.debug.assert(gpa.deinit() == .ok);

    var env_map = try std.testing.environ.createMap(gpa.allocator());
    defer env_map.deinit();
    var render = try term_pkg.Render.init(std.testing.io, gpa.allocator(), &env_map, .{});
    var sink: std.Io.Writer.Allocating = .init(gpa.allocator());
    defer sink.deinit();
    defer render.deinit(&sink.writer);
    try render.resize(&sink.writer, .{ .rows = 6, .cols = 24, .x_pixel = 0, .y_pixel = 0 });

    var out: std.Io.Writer.Allocating = .init(gpa.allocator());
    defer out.deinit();
    const host = try Host.create(gpa.allocator());
    defer host.destroy();
    host.bindRender(&render, &out.writer);

    try host.evalModule(
        \\import { term } from "yuke:term";
        \\import { Transcript } from "yuke:ui";
        \\const t = new Transcript({ textOf: () => "**hi** there" });
        \\t.setOutline([{ id: "a1", type: "assistant" }], null);
        \\term.beginFrame();
        \\t.draw({ x: 0, y: 0, w: 24, h: 6 });
        \\term.endFrame();
    , "draw.js");
    try std.testing.expect(std.mem.indexOf(u8, out.written(), "hi") != null);
    try std.testing.expect(std.mem.indexOf(u8, out.written(), "there") != null);
}

test "yuke:ui Composer draws a wrapped row whole and puts the caret on it" {
    var gpa = std.heap.DebugAllocator(.{}).init;
    defer std.debug.assert(gpa.deinit() == .ok);

    var env_map = try std.testing.environ.createMap(gpa.allocator());
    defer env_map.deinit();
    var render = try term_pkg.Render.init(std.testing.io, gpa.allocator(), &env_map, .{});
    var sink: std.Io.Writer.Allocating = .init(gpa.allocator());
    defer sink.deinit();
    defer render.deinit(&sink.writer);
    try render.resize(&sink.writer, .{ .rows = 4, .cols = 7, .x_pixel = 0, .y_pixel = 0 });

    var out: std.Io.Writer.Allocating = .init(gpa.allocator());
    defer out.deinit();
    const host = try Host.create(gpa.allocator());
    defer host.destroy();
    host.bindRender(&render, &out.writer);

    // The prompt takes two cells of the seven, so "hello world" wraps at five.
    try host.evalModule(
        \\import { term } from "yuke:term";
        \\import { Composer } from "yuke:ui";
        \\const c = new Composer();
        \\c.rect = { x: 0, y: 0, w: 7, h: 2 };
        \\c.text = "hello world";
        \\term.beginFrame();
        \\c.draw(true);
        \\const cur = c.cursor();
        \\term.endFrame();
        \\globalThis.result = cur.x === 2 + 5 - 1 && cur.y === 1 && cur.visible ? "ok" : "x=" + cur.x + " y=" + cur.y;
    , "composer_draw.js");

    // The hanging space must not turn the row into an ellipsis.
    try std.testing.expect(std.mem.indexOf(u8, out.written(), "hello") != null);
    try std.testing.expect(std.mem.indexOf(u8, out.written(), "world") != null);
    try std.testing.expect(std.mem.indexOf(u8, out.written(), "…") == null);

    const res = try host.ctx.eval("globalThis.result", "r.js", .{});
    defer host.ctx.freeValue(res);
    const text = try host.ctx.toCStringLen(res);
    defer host.ctx.freeCString(text.ptr);
    try std.testing.expectEqualStrings("ok", text);
}

test "yuke:client wraps the native and rejects an unimplemented connect" {
    var gpa = std.heap.DebugAllocator(.{}).init;
    defer std.debug.assert(gpa.deinit() == .ok);
    const host = try Host.create(gpa.allocator());
    defer host.destroy();
    try host.evalModule(
        \\import * as client from "yuke:client";
        \\const surface = ["connect", "disconnect", "connectionState", "connections", "devices", "sessionList",
        \\  "sessionOpen", "sessionClose", "sessionRev", "sessionResync", "sessionOutline", "sessionText",
        \\  "sessionSendInput", "sessionCancelRun", "workspaceBrowse"].every((k) => typeof client[k] === "function");
        \\let code = "";
        \\try { await client.connect({}); } catch (e) { code = e.code; }
        \\globalThis.result = surface && code === "bad_options" && client.connectionState("local") === "disconnected" ? "ok" : "fail";
    , "c.js");
    const out = try host.ctx.eval("globalThis.result", "r.js", .{});
    defer host.ctx.freeValue(out);
    const text = try host.ctx.toCStringLen(out);
    defer host.ctx.freeCString(text.ptr);
    try std.testing.expectEqualStrings("ok", text);
}

test "yuke:defaults boots the shell, seeds the sidebar, and wires commands" {
    var gpa = std.heap.DebugAllocator(.{}).init;
    defer std.debug.assert(gpa.deinit() == .ok);

    var env_map = try std.testing.environ.createMap(gpa.allocator());
    defer env_map.deinit();
    var render = try term_pkg.Render.init(std.testing.io, gpa.allocator(), &env_map, .{});
    var sink: std.Io.Writer.Allocating = .init(gpa.allocator());
    defer sink.deinit();
    defer render.deinit(&sink.writer);
    try render.resize(&sink.writer, .{ .rows = 24, .cols = 80, .x_pixel = 0, .y_pixel = 0 });

    var out: std.Io.Writer.Allocating = .init(gpa.allocator());
    defer out.deinit();
    const host = try Host.create(gpa.allocator());
    defer host.destroy();
    host.interrupt_budget = std.math.maxInt(u32); // the boot graph is CPU work, not a runaway script
    host.bindRender(&render, &out.writer);

    try host.evalModule("import \"yuke:core\";\nimport \"yuke:defaults\";", "boot.js");

    const loop = @import("loop.zig");
    // R0 has no transport, so boot renders only the shell chrome.
    try loop.start(host);
    try loop.stepTick(host);
    try std.testing.expect(std.mem.indexOf(u8, out.written(), "yuke") != null);

    // the command registry and the vim toggle are wired.
    try host.evalModule(
        \\import { command, root } from "yuke:core";
        \\import { plugins } from "yuke:ext";
        \\import { SessionList } from "yuke:defaults";
        \\const fail = [];
        \\command.perform("ui:palette");
        \\if (root.overlays.length !== 1) fail.push("palette");
        \\root.popOverlay();
        \\const before = !!plugins.get("vim");
        \\command.perform("vim:toggle");
        \\if (!!plugins.get("vim") === before) fail.push("vim-toggle");
        \\command.perform("vim:toggle");
        \\// An active, working row keeps both the activity mark and the "▸" active cue.
        \\const sl = new SessionList();
        \\sl.active = { connKey: "local", sessionId: "z" };
        \\const row = { connKey: "local", id: "z", session: { updated_at_ms: Date.now(), model: "m" }, activity: { state: { type: "working" } }, workspace: null };
        \\const line0 = sl._format(row).lines[0];
        \\if (line0.marker !== "●" || !line0.text.startsWith("▸ ")) fail.push("active-mark");
        \\globalThis.result = fail.length ? fail.join(",") : "ok";
    , "act.js");
    const res = try host.ctx.eval("globalThis.result", "r.js", .{});
    defer host.ctx.freeValue(res);
    const text = try host.ctx.toCStringLen(res);
    defer host.ctx.freeCString(text.ptr);
    try std.testing.expectEqualStrings("ok", text);
}

test "a style link cycle falls back instead of spinning" {
    var gpa = std.heap.DebugAllocator(.{}).init;
    defer std.debug.assert(gpa.deinit() == .ok);

    const host = try Host.create(gpa.allocator());
    defer host.destroy();
    try host.evalModule(
        \\import { style } from "yuke:core";
        \\style.groups.Cycle = { link: "Pong" };
        \\style.groups.Pong = { link: "Cycle" };
        \\style.groups.Selfie = { link: "Selfie" };
        \\style.groups.Dangling = { link: "Missing" };
        \\style.invalidate();
        \\const normal = style.resolve("Normal");
        \\globalThis.result = (
        \\  style.resolve("Cycle").fg === normal.fg &&
        \\  style.resolve("Selfie").fg === normal.fg &&
        \\  style.resolve("Dangling").fg === normal.fg &&
        \\  style.resolve("YukeHeader").fg === "reset" &&
        \\  style.resolve("YukeHeader").dim === true
        \\) ? 1 : 0;
    , "cycle.js");
    try std.testing.expectEqual(@as(i32, 1), try host.evalInt("globalThis.result"));
}

test "an overlay without a hook is consumed, not a fault" {
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

    // The overlay implements `draw` and no other hook.
    try host.evalModule(
        \\import { View, root, text } from "yuke:core";
        \\globalThis.seen = 0;
        \\class Base extends View {
        \\  get name() { return "base"; }
        \\  draw() { text(0, 0, "b", "Normal"); }
        \\  onKey(ev) { globalThis.seen++; return true; }
        \\}
        \\root.setActive(new Base());
        \\root.pushOverlay({ draw() { text(0, 1, "o", "Normal"); } });
        \\globalThis.root = root;
    , "overlay.js");

    const loop = @import("loop.zig");
    try loop.step(host, .{ .key_press = .{ .codepoint = 'a' } });
    try std.testing.expectEqual(@as(usize, 0), host.faultText().len);
    try std.testing.expectEqual(@as(i32, 0), try host.evalInt("globalThis.seen"));

    try host.eval("globalThis.root.popOverlay();", "pop.js");
    try loop.step(host, .{ .key_press = .{ .codepoint = 'a' } });
    try std.testing.expectEqual(@as(usize, 0), host.faultText().len);
    try std.testing.expectEqual(@as(i32, 1), try host.evalInt("globalThis.seen"));
}

test "an unusable view or layer is rejected at the call" {
    var gpa = std.heap.DebugAllocator(.{}).init;
    defer std.debug.assert(gpa.deinit() == .ok);

    const host = try Host.create(gpa.allocator());
    defer host.destroy();
    try host.evalModule(
        \\import { View, root } from "yuke:core";
        \\class Ok extends View { draw() {} }
        \\const reject = (fn, want) => {
        \\  try { fn(); } catch (e) {
        \\    if (e instanceof TypeError && e.message === want) globalThis.threw++;
        \\  }
        \\};
        \\globalThis.threw = 0;
        \\const view = "a view needs a draw method";
        \\const layer = "pushOverlay needs a layer with a draw method";
        \\for (const bad of [{}, { draw: 1 }]) reject(() => root.setActive(bad), view);
        \\root.setActive(new Ok());
        \\reject(() => root.split("row", {}), view);
        \\for (const bad of [null, {}, { draw: true }]) reject(() => root.pushOverlay(bad), layer);
        \\root.setActive(null);
        \\globalThis.cleared = root.active === null ? 1 : 0;
    , "reject.js");
    try std.testing.expectEqual(@as(i32, 6), try host.evalInt("globalThis.threw"));
    try std.testing.expectEqual(@as(i32, 1), try host.evalInt("globalThis.cleared"));
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
}
