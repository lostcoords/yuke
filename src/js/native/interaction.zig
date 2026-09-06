//! The native bridge for frontend-neutral questions.

const std = @import("std");
const quickjs = @import("quickjs");
const proto = @import("proto");
const Host = @import("../host.zig").Host;
const module = @import("module.zig");
const interactions = @import("../interactions.zig");
const pending = @import("../pending.zig");

const Context = quickjs.Context;
const Value = quickjs.Value;

/// Register `yuke:interaction-native` and its one `native` object, which also states the host limits.
pub fn install(host: *Host) void {
    module.installObject(host, "yuke:interaction-native", "native", &.{
        .{ .name = "watchCancellation", .arity = 2, .call = jsWatchCancellation },
        .{ .name = "sessionId", .arity = 1, .call = jsSessionId },
        .{ .name = "request", .arity = 2, .call = jsRequest },
        .{ .name = "notify", .arity = 3, .call = jsNotify },
        .{ .name = "cancel", .arity = 1, .call = jsCancel },
    }, addLimits);
}

/// Publish the limits, so the JavaScript checks match the host checks.
fn addLimits(_: *Host, ctx: Context, native: Value) void {
    module.set(ctx, native, "maxTextBytes", ctx.newInt64(interactions.max_text_bytes));
    module.set(ctx, native, "maxOptions", ctx.newInt64(interactions.max_options));
}

fn jsWatchCancellation(ctx: Context, _: Value, args: []const Value) Value {
    const host = Host.fromContext(ctx);
    if (args.len < 2 or !host.calls.acceptsSignal(ctx, args[1])) return pending.rejected(ctx, "the cancellation signal has no live call");
    const id = module.integer(ctx, args[0], 1, interactions.max_safe_id) orelse return pending.rejected(ctx, "the cancellation watch needs a safe positive id");
    return host.interactions.watchCancellation(&host.ops, ctx, id, args[1]) catch |err| return switch (err) {
        error.Exception => module.throwPending(ctx),
        else => pending.rejected(ctx, errorMessage(err)),
    };
}

fn jsSessionId(ctx: Context, _: Value, args: []const Value) Value {
    if (args.len != 1) return quickjs.NULL;
    const call = Host.fromContext(ctx).calls.callForSignal(ctx, args[0]) orelse return quickjs.NULL;
    const site = call.site orelse return quickjs.NULL;
    const id = std.fmt.bytesToHex(site.session_id.raw, .lower);
    return ctx.newString(&id);
}

fn jsRequest(ctx: Context, _: Value, args: []const Value) Value {
    const host = Host.fromContext(ctx);
    if (args.len < 2) return pending.rejected(ctx, "interaction.request needs an id and a JSON string");
    const id = module.integer(ctx, args[0], 1, interactions.max_safe_id) orelse return pending.rejected(ctx, "interaction.request needs a safe positive integer id");
    const json = module.string(ctx, args[1]) orelse return pending.rejected(ctx, "interaction.request needs a JSON string");
    defer ctx.freeCString(json.ptr);
    const owner = if (args.len > 2 and !ctx.isUndefined(args[2])) host.calls.callForSignal(ctx, args[2]) orelse return pending.rejected(ctx, "the interaction signal has no live call") else null;
    const promise = host.interactions.start(&host.ops, ctx, id, json) catch |err| return switch (err) {
        error.Exception => module.throwPending(ctx),
        else => pending.rejected(ctx, errorMessage(err)),
    };
    if (owner) |call| host.interactions.attribute(ctx, id, if (call.site) |site| site.session_id else null, args[2]);
    return promise;
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
    const id = if (args.len == 0) null else module.integer(ctx, args[0], 1, interactions.max_safe_id);
    return ctx.newBool(Host.fromContext(ctx).interactions.cancel(id orelse return ctx.newBool(false)));
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
