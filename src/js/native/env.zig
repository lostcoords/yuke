//! Read the effective environment that the host borrows from the process.

const std = @import("std");
const quickjs = @import("quickjs");
const Host = @import("../host.zig").Host;
const module = @import("module.zig");

pub fn install(host: *Host) void {
    module.installObject(host, "yuke:env", "env", &.{
        .{ .name = "get", .arity = 1, .call = jsGet },
    }, null);
}

fn jsGet(ctx: quickjs.Context, _: quickjs.Value, args: []const quickjs.Value) quickjs.Value {
    if (args.len == 0 or !ctx.isString(args[0])) return ctx.throwTypeError("the environment name must be a string");
    const name = ctx.toCStringLen(args[0]) catch return module.throwPending(ctx);
    defer ctx.freeCString(name.ptr);
    if (name.len == 0 or std.mem.indexOfAny(u8, name, "\x00=") != null)
        return ctx.throwTypeError("the environment name must not be empty or contain NUL or =");
    const host = Host.fromContext(ctx);
    const value = host.execution.env.get(name) orelse return quickjs.UNDEFINED;
    return ctx.newString(value);
}
