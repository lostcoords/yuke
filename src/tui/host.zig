const std = @import("std");
const builtin = @import("builtin");
const quickjs = @import("quickjs");
const zio = @import("zio");
const term_pkg = @import("term");
const loader_mod = @import("loader.zig");
const term_module = @import("modules/term.zig");

pub const loader = loader_mod;
pub const term = term_module;

/// Limit the client heap. Scripts fail when they exceed this limit.
pub const memory_limit: usize = 64 * 1024 * 1024;
/// Limit the QuickJS stack below the zio coroutine stack.
pub const stack_limit: usize = 1 * 1024 * 1024;
/// Limit jobs per drain so Promise chains do not starve the owner.
pub const job_budget: u32 = 1024;
/// Set the default time slice for one evaluation or callback.
pub const default_slice_ns: u64 = 50 * std.time.ns_per_ms;

pub const Error = error{
    OutOfMemory,
    JavaScriptFault,
    InvalidConfigRoot,
};

pub const default_baked = [_]loader_mod.BakedModule{
    .{ .name = "yuke:core", .source = @embedFile("js/core.js") },
};

pub const Options = struct {
    config_root: []const u8 = &.{},
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
    slice_ns: u64,
    deadline_ns: u64,
    budget: u32,
    fault_pending: bool,
    paint: Paint,

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
        var ld = loader_mod.Loader.init(gpa, io, opts.config_root, baked, opts.max_file_bytes) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            error.NotAbsolute => return error.InvalidConfigRoot,
        };
        errdefer ld.deinit();

        self.* = .{
            .gpa = gpa,
            .runtime = runtime,
            .ctx = ctx,
            .loader = ld,
            .phase = .open,
            .slice_ns = default_slice_ns,
            .deadline_ns = std.math.maxInt(u64),
            .budget = job_budget,
            .fault_pending = false,
            .paint = .{ .glyphs = .init(gpa) },
        };
        errdefer self.paint.glyphs.deinit();
        runtime.setRuntimeOpaque(self);
        ctx.setContextOpaque(self);
        runtime.setInterruptHandler(self);
        runtime.setModuleLoader(&self.loader);
        try term_module.install(self);
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
        if (self.paint.render) |render| {
            const writer = self.paint.writer orelse return;
            render.resize(writer, winsize) catch {
                if (render.window().width != winsize.cols or render.window().height != winsize.rows)
                    return;
                render.vx.screen.width_method = .unicode;
                self.paint.width = winsize.cols;
                self.paint.height = winsize.rows;
                self.paint.in_frame = false;
                self.paint.dirty = true;
                self.syncSizeProps();
                return;
            };
            render.vx.screen.width_method = .unicode;
        }
        self.paint.width = winsize.cols;
        self.paint.height = winsize.rows;
        self.paint.dirty = false;
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
    pub fn eval(self: *Host, source: []const u8, filename: [:0]const u8) Error!void {
        std.debug.assert(self.phase == .open);
        self.fault_pending = false;
        self.enterSlice();
        const value = self.ctx.eval(source, filename, .{}) catch {
            self.noteFault();
            return error.JavaScriptFault;
        };
        self.ctx.freeValue(value);
        try self.drainJobs();
    }

    /// Evaluate a module on the owner, then drain jobs.
    pub fn evalModule(self: *Host, source: []const u8, filename: [:0]const u8) Error!void {
        std.debug.assert(self.phase == .open);
        self.fault_pending = false;
        self.enterSlice();
        const value = self.ctx.eval(source, filename, .{ .type = .module }) catch {
            self.noteFault();
            return error.JavaScriptFault;
        };
        self.ctx.freeValue(value);
        try self.drainJobs();
    }

    /// Evaluate source and return its result as `i32`. Tests use this helper.
    pub fn evalInt(self: *Host, source: []const u8) Error!i32 {
        std.debug.assert(self.phase == .open);
        self.fault_pending = false;
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
        return nowNs() >= self.deadline_ns;
    }

    pub fn enterSlice(self: *Host) void {
        self.deadline_ns = nowNs() +| self.slice_ns;
    }

    pub fn noteFault(self: *Host) void {
        self.fault_pending = true;
        if (!self.ctx.hasException()) return;
        const exc = self.ctx.getException();
        self.ctx.freeValue(exc);
    }

    fn finishDrain(self: *Host) void {
        var n: u32 = 0;
        while (self.runtime.isJobPending() and n < job_budget) : (n += 1) {
            _ = self.runtime.executePendingJob() catch break;
        }
        self.phase = .drained;
    }
};

fn nowNs() u64 {
    return zio.time.Timestamp.now(.awake).toNanoseconds();
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
    try std.testing.expect(host.fault_pending);
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

test "an infinite loop hits the interrupt deadline" {
    var gpa = std.heap.DebugAllocator(.{}).init;
    defer std.debug.assert(gpa.deinit() == .ok);

    const host = try Host.create(gpa.allocator());
    defer host.destroy();
    host.slice_ns = 0;
    try std.testing.expectError(error.JavaScriptFault, host.eval("while (true) {}", "spin.js"));
    try std.testing.expect(host.fault_pending);
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
    host.slice_ns = 0;
    try std.testing.expectError(error.JavaScriptFault, host.close());
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
    try std.testing.expect(!host.fault_pending);
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
    try std.testing.expect(host.fault_pending);
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
        \\  before === "white" &&
        \\  stale === "white" &&
        \\  style.resolve("Normal").fg === "red" &&
        \\  style.resolve("YukeHeader").fg === "dark_gray" &&
        \\  style.resolve("YukeBrand").bold === true
        \\) ? 1 : 0;
    , "core.js");
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

test "import a file inside the config root" {
    var gpa = std.heap.DebugAllocator(.{}).init;
    defer std.debug.assert(gpa.deinit() == .ok);

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "util.js", .data = "export const n = 9;\n" });
    var root_buf: [std.fs.max_path_bytes]u8 = undefined;
    const root_len = try tmp.dir.realPath(std.testing.io, &root_buf);
    const root = root_buf[0..root_len];

    const host = try Host.createWith(gpa.allocator(), std.testing.io, .{ .config_root = root });
    defer host.destroy();

    var entry_buf: [std.fs.max_path_bytes]u8 = undefined;
    const entry = try std.fmt.bufPrintZ(&entry_buf, "{s}/app.js", .{root});
    try host.evalModule("import { n } from './util.js'; globalThis.result = n;", entry);
    try std.testing.expectEqual(@as(i32, 9), try host.evalInt("globalThis.result"));
}

test "a sibling directory file does not load" {
    var gpa = std.heap.DebugAllocator(.{}).init;
    defer std.debug.assert(gpa.deinit() == .ok);

    var inside = std.testing.tmpDir(.{});
    defer inside.cleanup();
    var outside = std.testing.tmpDir(.{});
    defer outside.cleanup();
    try outside.dir.writeFile(std.testing.io, .{ .sub_path = "secret.js", .data = "export const n = 1;\n" });

    var root_buf: [std.fs.max_path_bytes]u8 = undefined;
    const root_len = try inside.dir.realPath(std.testing.io, &root_buf);
    const root = root_buf[0..root_len];
    var secret_buf: [std.fs.max_path_bytes]u8 = undefined;
    const secret_len = try outside.dir.realPathFile(std.testing.io, "secret.js", &secret_buf);
    const secret = secret_buf[0..secret_len];

    const host = try Host.createWith(gpa.allocator(), std.testing.io, .{ .config_root = root });
    defer host.destroy();
    var src_buf: [std.fs.max_path_bytes + 64]u8 = undefined;
    const src = try std.fmt.bufPrint(&src_buf, "import {{ n }} from '{s}';", .{secret});
    try std.testing.expectError(error.JavaScriptFault, host.evalModule(src, "entry.js"));
}

test "an oversize config file does not load" {
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

    const host = try Host.createWith(gpa.allocator(), std.testing.io, .{
        .config_root = root,
        .max_file_bytes = 8,
    });
    defer host.destroy();
    var entry_buf: [std.fs.max_path_bytes]u8 = undefined;
    const entry = try std.fmt.bufPrintZ(&entry_buf, "{s}/app.js", .{root});
    try std.testing.expectError(
        error.JavaScriptFault,
        host.evalModule("import { n } from './big.js';", entry),
    );
}

test {
    _ = @import("loop.zig");
    _ = @import("app.zig");
}
