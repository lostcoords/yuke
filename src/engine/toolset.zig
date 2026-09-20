//! The process supplies the port that runs tools; the engine never names a tool: it sends `decls` to the provider and calls `run` with the name the provider chose, so a built-in tool and a future extension tool use the same path.

const std = @import("std");
const proto = @import("proto");
const ir = @import("ai").ir;

pub const Site = proto.input.ToolSite;

pub const Context = struct {
    workspace_root: []const u8,
    site: Site,
    work: *@import("../session/work.zig"),
};

/// One tool run, mapped for a tool part. `is_error` selects the completed or the error state.
pub const Outcome = struct {
    output: []const u8,
    view: ?[]const proto.view.View = null,
    /// The images beside the output. Tool output is peer input, so the engine admits each blob before it commits the result.
    media: []const proto.content.MediaBlob = &.{},
    is_error: bool,
};

pub const ToolSet = struct {
    ctx: *anyopaque = undefined,
    /// Answer every tool name the process serves. The result belongs to `arena`.
    names: *const fn (ctx: *anyopaque, arena: std.mem.Allocator) error{OutOfMemory}![]const []const u8 = noNames,
    /// Answer the declarations of `allowed`, in table order. The result belongs to `arena`.
    getDecls: *const fn (ctx: *anyopaque, arena: std.mem.Allocator, allowed: []const []const u8) error{OutOfMemory}![]const ir.Tool = noDecls,
    /// Run one tool by the name the provider chose.
    run: *const fn (
        ctx: *anyopaque,
        out: std.mem.Allocator,
        name: []const u8,
        arguments: []const u8,
        context: Context,
    ) Outcome = unknownTool,
};

/// A process without extensions advertises no tool.
fn noNames(_: *anyopaque, _: std.mem.Allocator) error{OutOfMemory}![]const []const u8 {
    return &.{};
}

fn noDecls(_: *anyopaque, _: std.mem.Allocator, _: []const []const u8) error{OutOfMemory}![]const ir.Tool {
    return &.{};
}

/// A name the process does not serve answers the model, so a turn continues.
fn unknownTool(_: *anyopaque, out: std.mem.Allocator, name: []const u8, _: []const u8, _: Context) Outcome {
    return .{
        .output = std.fmt.allocPrint(out, "The tool \"{s}\" is unknown.", .{name}) catch "The requested tool is unknown.",
        .is_error = true,
    };
}
