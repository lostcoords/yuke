//! The native bridge for frontend-neutral questions.

const std = @import("std");
const quickjs = @import("quickjs");
const proto = @import("proto");
const Host = @import("../host.zig").Host;
const interactions = @import("../interactions.zig");
const pending = @import("../pending.zig");

const Context = quickjs.Context;
const Value = quickjs.Value;
const Module = Context.Module;

const Binding = struct { name: [*:0]const u8, length: c_int, function: fn (Context, Value, []const Value) Value };

const bindings = [_]Binding{
    .{ .name = "request", .length = 2, .function = jsRequest },
    .{ .name = "notify", .length = 3, .function = jsNotify },
    .{ .name = "cancel", .length = 1, .function = jsCancel },
};

pub fn install(host: *Host) void {
    std.debug.assert(host.phase == .open);
    const module = host.ctx.newModule("yuke:interaction-native", init).?;
    host.ctx.addModuleExport(module, "native") catch unreachable;
}

fn init(ctx: Context, module: Module) c_int {
    std.debug.assert(Host.fromContext(ctx).phase == .open);
    const native = ctx.newObject();
    if (ctx.isException(native)) return -1;
    build(ctx, native) catch {
        ctx.freeValue(native);
        return -1;
    };
    ctx.setModuleExport(module, "native", native) catch return -1;
    return 0;
}

/// Bind the calls and publish the limits, so the JavaScript checks match the host checks.
fn build(ctx: Context, native: Value) !void {
    inline for (bindings) |binding| {
        try ctx.setPropertyStr(native, binding.name, ctx.newFunction(binding.name, binding.length, binding.function));
    }
    try ctx.setPropertyStr(native, "maxTextBytes", ctx.newInt64(interactions.max_text_bytes));
    try ctx.setPropertyStr(native, "maxOptions", ctx.newInt64(interactions.max_options));
}

fn jsRequest(ctx: Context, _: Value, args: []const Value) Value {
    const host = Host.fromContext(ctx);
    const id = interactionId(ctx, args) orelse return pending.rejected(ctx, "interaction.request needs a safe positive integer id");
    const json = jsonArg(ctx, args) orelse return pending.rejected(ctx, "interaction.request needs a JSON string");
    defer ctx.freeCString(json.ptr);
    return host.interactions.start(&host.ops, ctx, host.owner_wake, id, json) catch |err| switch (err) {
        error.Exception => ctx.throw(ctx.getException()),
        else => pending.rejected(ctx, errorMessage(err)),
    };
}

/// Broadcast one message to every attached frontend. Nothing answers it.
fn jsNotify(ctx: Context, _: Value, args: []const Value) Value {
    const engine = Host.fromContext(ctx).engine;
    const runtime = engine.runtime orelse return ctx.throwPlainError("the engine is not ready");
    if (args.len < 3) return ctx.throwTypeError("interaction.notify needs a source, a message and a level");
    const source = ctx.toCStringLen(args[0]) catch return ctx.throwTypeError("the notice source must be a string");
    defer ctx.freeCString(source.ptr);
    const message = ctx.toCStringLen(args[1]) catch return ctx.throwTypeError("the notice message must be a string");
    defer ctx.freeCString(message.ptr);
    const level_text = ctx.toCStringLen(args[2]) catch return ctx.throwTypeError("the notice level must be a string");
    defer ctx.freeCString(level_text.ptr);
    const level = std.meta.stringToEnum(proto.enums.NoticeLevel, level_text) orelse
        return ctx.throwTypeError("the notice level is unknown");
    runtime.engine.sinks.emit(.{ .method = .notice, .params = .{ .notice = .{
        .level = level,
        .source = source,
        .message = message,
    } } });
    return quickjs.UNDEFINED;
}

fn jsCancel(ctx: Context, _: Value, args: []const Value) Value {
    const id = interactionId(ctx, args) orelse return ctx.newBool(false);
    return ctx.newBool(Host.fromContext(ctx).interactions.cancel(id));
}

fn interactionId(ctx: Context, args: []const Value) ?u64 {
    if (args.len == 0) return null;
    const raw = ctx.toFloat64(args[0]) catch return null;
    if (!std.math.isFinite(raw) or raw < 1 or raw > interactions.max_safe_id or @floor(raw) != raw) return null;
    return @intFromFloat(raw);
}

fn jsonArg(ctx: Context, args: []const Value) ?[:0]const u8 {
    if (args.len < 2 or !ctx.isString(args[1])) return null;
    return ctx.toCStringLen(args[1]) catch null;
}

fn errorMessage(err: interactions.Error) [:0]const u8 {
    return switch (err) {
        error.Unavailable => "the interaction host is closing",
        error.Duplicate => "the interaction id is already pending",
        error.Full => "too many interactions are pending",
        error.InvalidRequest => "the interaction request is invalid",
        error.Unknown => "the interaction is not pending",
        error.ResponseMismatch => "the interaction response has the wrong type",
        error.InvalidSelection => "the interaction selected an unknown option",
        error.Exception => unreachable, // the caller throws it
    };
}
