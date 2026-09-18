//! Convert complete UTF-8 values without implicit replacement.

const std = @import("std");
const quickjs = @import("quickjs");
const Host = @import("../host.zig").Host;
const module = @import("module.zig");

pub fn install(host: *Host) void {
    module.installObject(host, "yuke:utf8", "utf8", &.{
        .{ .name = "encode", .arity = 1, .call = jsEncode },
        .{ .name = "decode", .arity = 1, .call = jsDecode },
    }, null);
}

fn jsEncode(ctx: quickjs.Context, _: quickjs.Value, args: []const quickjs.Value) quickjs.Value {
    if (args.len == 0 or !ctx.isString(args[0])) return ctx.throwTypeError("the text must be a string");
    const bytes = ctx.toCStringLen(args[0]) catch return module.throwPending(ctx);
    defer ctx.freeCString(bytes.ptr);
    // QuickJS preserves lone UTF-16 surrogates, which UTF-8 must reject.
    if (!std.unicode.utf8ValidateSlice(bytes)) return ctx.throwTypeError("the text contains a lone surrogate");
    return ctx.newUint8ArrayCopy(bytes);
}

fn jsDecode(ctx: quickjs.Context, _: quickjs.Value, args: []const quickjs.Value) quickjs.Value {
    if (args.len == 0) return ctx.throwTypeError("the bytes must be a Uint8Array");
    const kind = ctx.getTypedArrayType(args[0]) catch return ctx.throwTypeError("the bytes must be a Uint8Array");
    if (kind != .Uint8Array) return ctx.throwTypeError("the bytes must be a Uint8Array");
    const bytes = ctx.getUint8Array(args[0]) catch return module.throwPending(ctx);
    if (!std.unicode.utf8ValidateSlice(bytes)) return ctx.throwTypeError("the bytes must contain complete UTF-8");
    return ctx.newString(bytes);
}
