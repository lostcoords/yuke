//! The port the engine calls to run a tool. The process supplies the implementation.
//!
//! The engine never names a tool. It sends `decls` to the provider and calls `run` for whichever
//! name the provider chose. A built-in tool and a future extension tool both arrive through here.

const std = @import("std");
const proto = @import("proto");
const ir = @import("../provider/request/ir.zig");

/// One tool run, mapped for a tool part. `is_error` selects the completed or the error state.
pub const Outcome = struct {
    output: []const u8,
    view: ?[]const proto.view.View = null,
    is_error: bool,
};

pub const ToolSet = struct {
    ctx: *anyopaque = undefined,
    /// Answer what the provider may call. The slice is valid until the caller returns.
    decls: *const fn (ctx: *anyopaque) []const ir.Tool = noDecls,
    /// Run one tool by the name the provider chose.
    run: *const fn (
        ctx: *anyopaque,
        out: std.mem.Allocator,
        name: []const u8,
        arguments: []const u8,
        workspace_root: []const u8,
    ) Outcome = unknownTool,
};

/// A process without extensions advertises no tool.
fn noDecls(_: *anyopaque) []const ir.Tool {
    return &.{};
}

/// A name the process does not serve answers the model, so a turn continues.
fn unknownTool(_: *anyopaque, out: std.mem.Allocator, name: []const u8, _: []const u8, _: []const u8) Outcome {
    return .{
        .output = std.fmt.allocPrint(out, "The tool \"{s}\" is unknown.", .{name}) catch "The requested tool is unknown.",
        .is_error = true,
    };
}
