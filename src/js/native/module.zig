//! One shape for every native module: a comptime table of functions, installed once at host creation.

const std = @import("std");
const quickjs = @import("quickjs");
const proto = @import("proto");
const Host = @import("../host.zig").Host;
const cancellation = @import("cancellation.zig");
const support = @import("../tests/support.zig");

const Context = quickjs.Context;
const Value = quickjs.Value;

/// One exported function: its name, its declared arity, and the Zig callback.
pub const Fn = struct { name: [:0]const u8, arity: c_int, call: fn (Context, Value, []const Value) Value };

/// A module whose exports are bare functions: `import { a, b } from "yuke:x"`.
pub fn installFunctions(host: *Host, comptime name: [:0]const u8, comptime fns: []const Fn) void {
    std.debug.assert(host.phase == .open);
    const Init = struct {
        fn init(ctx: Context, m: Context.Module) c_int {
            if (!Host.fromContext(ctx).acceptsIo()) {
                _ = ctx.throwTypeError("the host is closed");
                return -1;
            }
            inline for (fns) |f| ctx.setModuleExport(m, f.name, ctx.newFunction(f.name, f.arity, f.call)) catch return -1;
            return 0;
        }
    };
    const m = host.ctx.newModule(name, Init.init).?;
    inline for (fns) |f| host.ctx.addModuleExport(m, f.name) catch unreachable;
}

/// A module with one object export that holds the functions; `extra` adds the constants and any host root.
pub fn installObject(
    host: *Host,
    comptime name: [:0]const u8,
    comptime as: [:0]const u8,
    comptime fns: []const Fn,
    comptime extra: ?fn (*Host, Context, Value) void,
) void {
    std.debug.assert(host.phase == .open);
    const Init = struct {
        fn init(ctx: Context, m: Context.Module) c_int {
            const h = Host.fromContext(ctx);
            if (!h.acceptsIo()) {
                _ = ctx.throwTypeError("the host is closed");
                return -1;
            }
            const obj = ctx.newObject();
            inline for (fns) |f| set(ctx, obj, f.name, ctx.newFunction(f.name, f.arity, f.call));
            if (extra) |add| add(h, ctx, obj);
            // A full QuickJS heap at boot ends the module evaluation, which the host reports as a fault.
            if (ctx.hasException()) {
                ctx.freeValue(obj);
                return -1;
            }
            // `setModuleExport` takes `obj` on both paths, so nothing here frees it.
            ctx.setModuleExport(m, as, obj) catch return -1;
            return 0;
        }
    };
    const m = host.ctx.newModule(name, Init.init).?;
    host.ctx.addModuleExport(m, as) catch unreachable;
}

/// Throw the exception QuickJS left pending, and answer the sentinel a native function returns.
pub fn throwPending(ctx: Context) Value {
    return ctx.throw(ctx.getException());
}

/// Answer the built `value`, or free it and throw when a full QuickJS heap left an exception during the build.
pub fn finish(ctx: Context, value: Value) Value {
    if (!ctx.hasException()) return value;
    ctx.freeValue(value);
    return throwPending(ctx);
}

/// Borrow one string argument. Another type answers null, because a conversion would run script code.
pub fn string(ctx: Context, value: Value) ?[:0]const u8 {
    if (!ctx.isString(value)) return null;
    return ctx.toCStringLen(value) catch null;
}

/// Copy one string argument for a task that outlives the call. Another type answers null.
pub fn owned(ctx: Context, gpa: std.mem.Allocator, value: Value) ?[]u8 {
    const raw = string(ctx, value) orelse return null;
    defer ctx.freeCString(raw.ptr);
    return gpa.dupe(u8, raw) catch unreachable;
}

/// Read one whole number in `[min, max]`. A fraction, a NaN, or another type answers null.
pub fn integer(ctx: Context, value: Value, min: u64, max: u64) ?u64 {
    std.debug.assert(min <= max);
    if (!ctx.isNumber(value)) return null;
    const n = ctx.toFloat64(value) catch return null;
    if (!std.math.isFinite(n) or @floor(n) != n) return null;
    if (n < 0 or n >= 0x1p64) return null;
    const result: u64 = @intFromFloat(n);
    return if (result < min or result > max) null else result;
}

/// Read one lowercase session ID, or answer null for another value.
pub fn sessionId(ctx: Context, value: Value) ?proto.ids.SessionId {
    const text = string(ctx, value) orelse return null;
    defer ctx.freeCString(text.ptr);
    if (!proto.ids.SessionId.validText(text)) return null;
    var raw: [proto.ids.SessionId.byte_len]u8 = undefined;
    _ = std.fmt.hexToBytes(&raw, text) catch unreachable;
    return .bytes(raw);
}

/// Read one optional whole-number property in `[1, max]`, or answer `default`.
pub fn optionalInteger(ctx: Context, options: Value, name: [:0]const u8, default: ?u32, max: u32) error{InvalidOption}!?u32 {
    if (!ctx.isObject(options)) return default;
    const value = ctx.getPropertyStr(options, name);
    defer ctx.freeValue(value);
    if (ctx.isUndefined(value) or ctx.isNull(value)) return default;
    return @intCast(integer(ctx, value, 1, max) orelse return error.InvalidOption);
}

/// Copy one optional string option. An absent option answers null, and a wrong type is an error.
pub fn optionalString(ctx: Context, gpa: std.mem.Allocator, options: Value, name: [:0]const u8) error{InvalidOption}!?[]u8 {
    if (!ctx.isObject(options)) return null;
    const value = ctx.getPropertyStr(options, name);
    defer ctx.freeValue(value);
    if (ctx.isUndefined(value) or ctx.isNull(value)) return null;
    return owned(ctx, gpa, value) orelse error.InvalidOption;
}

/// Read one optional boolean option. An absent option is false, and a wrong type is an error.
pub fn optionalBool(ctx: Context, options: Value, name: [:0]const u8) error{InvalidOption}!bool {
    if (!ctx.isObject(options)) return false;
    const value = ctx.getPropertyStr(options, name);
    defer ctx.freeValue(value);
    if (ctx.isUndefined(value) or ctx.isNull(value)) return false;
    if (!ctx.isBool(value)) return error.InvalidOption;
    return ctx.toBool(value) catch error.InvalidOption;
}

/// Copy a workspace root argument, or `default` when it is absent. A relative root answers null, because a spawn asserts an absolute directory.
pub fn rootArg(ctx: Context, gpa: std.mem.Allocator, value: Value, default: []const u8) ?[]u8 {
    if (ctx.isUndefined(value) or ctx.isNull(value)) return gpa.dupe(u8, default) catch unreachable;
    const root = owned(ctx, gpa, value) orelse return null;
    if (std.Io.Dir.path.isAbsolute(root)) return root;
    gpa.free(root);
    return null;
}

/// Set one property, or drop the value once the QuickJS heap is full; the builder reads the exception at its end.
pub fn set(ctx: Context, obj: Value, name: [:0]const u8, value: Value) void {
    if (ctx.hasException()) return ctx.freeValue(value);
    ctx.setPropertyStr(obj, name, value) catch {};
}

/// Parse the JSON a writer holds. JS_ParseJSON finds the end of the text at a NUL byte, so this appends one.
pub fn parseWritten(ctx: Context, text: *std.Io.Writer.Allocating, filename: [:0]const u8) Value {
    text.writer.writeByte(0) catch unreachable;
    const json = text.written();
    return ctx.parseJSON(json[0 .. json.len - 1 :0], filename);
}

/// Build a JavaScript value from Zig data: a struct becomes an object with camelCase keys, a byte slice becomes a string, another slice becomes an array, and a tagged union becomes its payload.
pub fn toJs(ctx: Context, value: anytype) Value {
    const T = @TypeOf(value);
    switch (@typeInfo(T)) {
        .bool => return ctx.newBool(value),
        // A value past the i64 range becomes a double, as a JSON number would.
        .int => return if (std.math.cast(i64, value)) |small| ctx.newInt64(small) else ctx.newNumber(@floatFromInt(value)),
        .optional => return if (value) |inner| toJs(ctx, inner) else quickjs.NULL,
        .pointer => |pointer| {
            comptime std.debug.assert(pointer.size == .slice);
            if (pointer.child == u8) return ctx.newString(value);
            const array = ctx.newArray();
            if (ctx.isException(array)) return array;
            for (value, 0..) |item, i| setIndex(ctx, array, i, toJs(ctx, item));
            return finish(ctx, array);
        },
        .@"struct" => |info| {
            const object = ctx.newObject();
            if (ctx.isException(object)) return object;
            inline for (info.fields) |field| set(ctx, object, comptime camelCase(field.name), toJs(ctx, @field(value, field.name)));
            return finish(ctx, object);
        },
        .@"union" => switch (value) {
            inline else => |payload| return toJs(ctx, payload),
        },
        else => @compileError("toJs cannot convert " ++ @typeName(T)),
    }
}

/// Turn a Zig field name into the JavaScript key: `timed_out` becomes `timedOut`.
fn camelCase(comptime name: []const u8) [:0]const u8 {
    comptime {
        var out: [name.len:0]u8 = undefined;
        var len: usize = 0;
        var upper = false;
        for (name) |char| {
            if (char == '_') {
                upper = true;
                continue;
            }
            out[len] = if (upper) std.ascii.toUpper(char) else char;
            len += 1;
            upper = false;
        }
        out[len] = 0;
        const key: [len:0]u8 = out[0..len :0].*;
        return &key;
    }
}

/// Set one indexed property, or drop the value once the QuickJS heap is full.
pub inline fn setIndex(ctx: Context, obj: Value, index: usize, value: Value) void {
    if (ctx.hasException()) return ctx.freeValue(value);
    ctx.setPropertyUint32(obj, @intCast(index), value) catch {};
}

/// The bounds of one I/O option set. A zero `max_bytes` means the operation has no chunk size.
pub const IoLimits = struct { default_timeout_ms: u32, max_timeout_ms: u32, min_bytes: u32 = 0, default_bytes: u32 = 0, max_bytes: u32 = 0 };
pub const IoOptions = struct { signal: Value, deadline: std.Io.Clock.Timestamp, max_bytes: u32 };

/// Read `{ timeoutMs, maxBytes, signal }` under `limits`. The caller frees `signal`. A wrong member is an error.
pub fn ioOptions(host: *Host, value: Value, limits: IoLimits) error{InvalidOption}!IoOptions {
    const ctx = host.ctx;
    if (!ctx.isUndefined(value) and (!ctx.isObject(value) or ctx.isArray(value))) return error.InvalidOption;
    const timeout_ms = (try optionalInteger(ctx, value, "timeoutMs", limits.default_timeout_ms, limits.max_timeout_ms)).?;
    const max_bytes = if (limits.max_bytes == 0) 0 else (try optionalInteger(ctx, value, "maxBytes", limits.default_bytes, limits.max_bytes)).?;
    if (max_bytes < limits.min_bytes) return error.InvalidOption;
    const signal = if (ctx.isObject(value)) ctx.getPropertyStr(value, "signal") else quickjs.UNDEFINED;
    if (ctx.isException(signal)) return error.InvalidOption;
    errdefer ctx.freeValue(signal);
    if (!ctx.isUndefined(signal) and cancellation.get(ctx, signal) == null) return error.InvalidOption;
    return .{ .signal = signal, .deadline = .fromNow(host.io, .{ .clock = .awake, .raw = .fromMilliseconds(timeout_ms) }), .max_bytes = max_bytes };
}

/// The live records of one primitive. `T` has `id`, `done()`, `close()`, and `deinit(gpa)` for what it holds beside its memory.
pub fn Table(comptime T: type) type {
    return struct {
        live: std.ArrayList(*T) = .empty,
        last_id: u32 = 0,
        /// One reaped record waits here, so a serial caller allocates none.
        spare: ?*T = null,

        const Self = @This();

        pub fn find(self: *Self, id: u32) ?*T {
            for (self.live.items) |record| if (record.id == id) return record;
            return null;
        }

        /// Return the record named by the first JavaScript argument, or return null.
        pub fn findArg(self: *Self, ctx: Context, args: []const Value) ?*T {
            if (args.len == 0) return null;
            const id = integer(ctx, args[0], 1, std.math.maxInt(u32)) orelse return null;
            return self.find(@intCast(id));
        }

        /// True at the record limit. The reap runs first, so a done record never counts.
        pub fn full(self: *Self, gpa: std.mem.Allocator, limit: usize) bool {
            self.reap(gpa);
            return self.live.items.len >= limit or self.last_id == std.math.maxInt(u32);
        }

        /// Table one record with a fresh id.
        pub fn add(self: *Self, gpa: std.mem.Allocator, init: T) *T {
            std.debug.assert(self.last_id < std.math.maxInt(u32));
            const record = self.spare orelse gpa.create(T) catch unreachable;
            self.spare = null;
            record.* = init;
            self.last_id += 1;
            record.id = self.last_id;
            self.live.append(gpa, record) catch unreachable;
            return record;
        }

        /// Drop every done record. The first one becomes the spare.
        pub fn reap(self: *Self, gpa: std.mem.Allocator) void {
            var i: usize = 0;
            while (i < self.live.items.len) {
                const record = self.live.items[i];
                if (!record.done()) {
                    i += 1;
                    continue;
                }
                _ = self.live.swapRemove(i);
                record.deinit(gpa);
                if (self.spare == null) self.spare = record else gpa.destroy(record);
            }
        }

        pub fn closeAll(self: *Self) void {
            for (self.live.items) |record| record.close();
        }

        /// Every task has returned, so each record is done and this frees them all.
        pub fn deinit(self: *Self, gpa: std.mem.Allocator) void {
            self.reap(gpa);
            std.debug.assert(self.live.items.len == 0);
            if (self.spare) |record| gpa.destroy(record);
            self.live.deinit(gpa);
            self.* = .{};
        }
    };
}

test "toJs builds objects with camelCase keys, null for an absent optional, and the payload of a union" {
    const host = support.createHost();
    defer support.destroyHost(host);
    const ctx = host.ctx;
    const Answer = union(enum) {
        text: struct { text: []const u8, next_line: ?u32, long_lines: u32, size: u64, huge: u64, complete: bool },
        image: struct { image_path: []const u8 },
    };
    const cases = [_]struct { value: Answer, json: []const u8 }{
        .{ .value = .{ .text = .{ .text = "a\x00b", .next_line = null, .long_lines = 3, .size = 1 << 40, .huge = 1 << 63, .complete = true } }, .json = "{\"text\":\"a\\u0000b\",\"nextLine\":null,\"longLines\":3,\"size\":1099511627776,\"huge\":9223372036854776000,\"complete\":true}" },
        .{ .value = .{ .image = .{ .image_path = "/tmp/a.png" } }, .json = "{\"imagePath\":\"/tmp/a.png\"}" },
    };
    for (cases) |case| {
        const value = toJs(ctx, case.value);
        defer ctx.freeValue(value);
        const json = ctx.jsonStringify(value, quickjs.UNDEFINED, quickjs.UNDEFINED);
        defer ctx.freeValue(json);
        const text = string(ctx, json).?;
        defer ctx.freeCString(text.ptr);
        try std.testing.expectEqualStrings(case.json, text);
    }
}

test "integer checks exact bounds before and after the float conversion" {
    const host = support.createHost();
    defer support.destroyHost(host);
    const cases = [_]struct { n: f64, min: u64 = 0, max: u64 = std.math.maxInt(u64), want: ?u64 = null }{
        .{ .n = 0, .want = 0 },
        .{ .n = 42, .min = 42, .max = 42, .want = 42 },
        .{ .n = -1 },
        .{ .n = 1.5 },
        .{ .n = std.math.nan(f64) },
        .{ .n = std.math.inf(f64) },
        .{ .n = 0x1p64 },
        .{ .n = 0x1p64 - 2048, .want = 0xfffffffffffff800 },
        .{ .n = 9007199254740992, .min = 9007199254740993 },
        .{ .n = 9007199254740996, .max = 9007199254740995 },
    };
    for (cases) |case| {
        const value = host.ctx.newFloat64(case.n);
        defer host.ctx.freeValue(value);
        try std.testing.expectEqual(case.want, integer(host.ctx, value, case.min, case.max));
    }
    const text = host.ctx.newString("42");
    defer host.ctx.freeValue(text);
    try std.testing.expectEqual(null, integer(host.ctx, text, 0, 100));
}

test "session ids accept only lowercase hexadecimal text" {
    const host = support.createHost();
    defer support.destroyHost(host);
    const lower = host.ctx.newString("00" ** 16);
    defer host.ctx.freeValue(lower);
    try std.testing.expect(sessionId(host.ctx, lower) != null);
    const upper = host.ctx.newString("AA" ++ ("00" ** 15));
    defer host.ctx.freeValue(upper);
    try std.testing.expectEqual(null, sessionId(host.ctx, upper));
}
