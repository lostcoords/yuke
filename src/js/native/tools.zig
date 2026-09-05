//! The native `yuke:tools` module: `defineTool` registers one tool the model can call.
//!
//! A refused registration THROWS. `index.js` is user input, never internal state, so this
//! validates and reports; it never asserts. A throw at boot paints the fault and names the file.

const std = @import("std");
const quickjs = @import("quickjs");
const Host = @import("../host.zig").Host;
const module = @import("module.zig");
const table = @import("../tools.zig");

const Context = quickjs.Context;
const Value = quickjs.Value;

/// Register `yuke:tools` and its functions.
pub fn install(host: *Host) void {
    module.installFunctions(host, "yuke:tools", &.{
        .{ .name = "defineTool", .arity = 2, .call = jsDefineTool },
        .{ .name = "removeTool", .arity = 1, .call = jsRemoveTool },
    });
}

/// `defineTool(name, {description, parameters, execute})`.
///
/// `parameters` is a JSON Schema object, so a tool can state an enum, an array, or a nested
/// object. The provider reads that schema, so a shape it refuses must fail here, at boot, and
/// not inside a turn.
fn jsDefineTool(ctx: Context, _: Value, args: []const Value) Value {
    const host = Host.fromContext(ctx);
    if (args.len < 2) return ctx.throwTypeError("defineTool needs a name and a definition");
    if (!ctx.isString(args[0])) return ctx.throwTypeError("the tool name must be a string");
    if (!ctx.isObject(args[1])) return ctx.throwTypeError("the tool definition must be an object");

    const name = ctx.toCStringLen(args[0]) catch return module.throwPending(ctx);
    defer ctx.freeCString(name.ptr);
    const description = ctx.getPropertyStr(args[1], "description");
    defer ctx.freeValue(description);
    if (!ctx.isString(description)) return ctx.throwTypeError("the tool needs a description string");
    const description_text = ctx.toCStringLen(description) catch return module.throwPending(ctx);
    defer ctx.freeCString(description_text.ptr);
    if (description_text.len == 0) return ctx.throwTypeError("the tool description must not be empty");

    const parameters = ctx.getPropertyStr(args[1], "parameters");
    defer ctx.freeValue(parameters);
    if (schemaFault(ctx, parameters)) |message| return ctx.throwTypeError(message);

    const execute = ctx.getPropertyStr(args[1], "execute");
    // The table takes this reference on success, so only a failure frees it here.
    if (!ctx.isFunction(execute)) {
        ctx.freeValue(execute);
        return ctx.throwTypeError("the tool needs an execute function");
    }

    const schema = ctx.jsonStringify(parameters, quickjs.UNDEFINED, quickjs.UNDEFINED);
    defer ctx.freeValue(schema);
    if (!ctx.isString(schema)) {
        ctx.freeValue(execute);
        if (ctx.isException(schema)) return module.throwPending(ctx);
        return ctx.throwTypeError("the tool parameters must convert to JSON");
    }
    const schema_text = ctx.toCStringLen(schema) catch {
        ctx.freeValue(execute);
        return module.throwPending(ctx);
    };
    defer ctx.freeCString(schema_text.ptr);

    host.tools.register(name, description_text, schema_text, execute) catch |err| {
        ctx.freeValue(execute);
        return ctx.throwTypeError(registerMessage(err));
    };
    return quickjs.UNDEFINED;
}

/// `removeTool(name)` withdraws one tool. It answers true when a tool held that name.
fn jsRemoveTool(ctx: Context, _: Value, args: []const Value) Value {
    const host = Host.fromContext(ctx);
    if (args.len < 1 or !ctx.isString(args[0])) return ctx.throwTypeError("removeTool needs a name string");
    const name = ctx.toCStringLen(args[0]) catch return module.throwPending(ctx);
    defer ctx.freeCString(name.ptr);
    return ctx.newBool(host.tools.remove(ctx, name));
}

/// Report why the schema is refused, or null when it is usable.
/// The provider needs an object schema with a `properties` object; anything else returns a 400.
fn schemaFault(ctx: Context, parameters: Value) ?[*:0]const u8 {
    if (!ctx.isObject(parameters) or ctx.isArray(parameters))
        return "the tool parameters must be a JSON Schema object";

    const kind = ctx.getPropertyStr(parameters, "type");
    defer ctx.freeValue(kind);
    if (!ctx.isString(kind)) return "the tool parameters need \"type\": \"object\"";
    const kind_text = ctx.toCStringLen(kind) catch return "the tool parameters need \"type\": \"object\"";
    defer ctx.freeCString(kind_text.ptr);
    if (!std.mem.eql(u8, kind_text, "object")) return "the tool parameters need \"type\": \"object\"";

    const properties = ctx.getPropertyStr(parameters, "properties");
    defer ctx.freeValue(properties);
    if (!ctx.isObject(properties) or ctx.isArray(properties))
        return "the tool parameters need a \"properties\" object";
    return null;
}

/// Map one refusal to the sentence the script reads. The set is closed.
fn registerMessage(err: table.RegisterError) [*:0]const u8 {
    return switch (err) {
        error.DuplicateName => "another tool already has this name",
        error.InvalidName => "the tool name must be 1 to 64 characters of a-z, A-Z, 0-9, _ or -",
    };
}
