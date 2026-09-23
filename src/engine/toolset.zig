//! The process supplies the port that runs tools. The engine sends `decls` to the provider and calls `run` with the name the provider chose, so a built-in and an extension tool share one path.

const std = @import("std");
const proto = @import("proto");
const ir = @import("ai").ir;
const work = @import("../session/work.zig");

pub const Site = proto.input.ToolSite;

pub const Context = struct {
    workspace_root: []const u8,
    site: Site,
    work: *work,
    /// Valid only until `ToolSet.run` returns; a tool must not keep it.
    output: Output,
};

/// The live output of one running tool. The engine publishes each chunk as a `tool.output_delta`.
pub const Output = struct {
    ctx: *anyopaque,
    write: *const fn (ctx: *anyopaque, bytes: []const u8) void,

    /// A sink that drops every chunk, for a caller that shows no live output.
    pub const discard: Output = .{ .ctx = &discard_target, .write = discardWrite };
    var discard_target: u8 = 0;

    fn discardWrite(_: *anyopaque, _: []const u8) void {}
};

/// One tool run, mapped for a tool part. `is_error` selects the completed or the error state.
pub const Outcome = struct {
    output: []const u8,
    view: ?[]const proto.view.View = null,
    /// The images beside the output. Tool output is peer input, so the engine admits each blob before it commits the result.
    media: []const proto.content.MediaBlob = &.{},
    /// The definitions a search loaded. The engine admits each one against the run loadout.
    tools_added: []const proto.tool.ToolDefinition = &.{},
    is_error: bool,
};

pub const ToolSet = struct {
    ctx: *anyopaque = undefined,
    /// Answer every declaration the process serves, in table order. The result belongs to `arena`.
    decls: *const fn (ctx: *anyopaque, arena: std.mem.Allocator) error{OutOfMemory}![]const ir.Tool = noDecls,
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
fn noDecls(_: *anyopaque, _: std.mem.Allocator) error{OutOfMemory}![]const ir.Tool {
    return &.{};
}

/// A name the process does not serve answers the model, so a turn continues.
fn unknownTool(_: *anyopaque, out: std.mem.Allocator, name: []const u8, _: []const u8, _: Context) Outcome {
    return .{
        .output = std.fmt.allocPrint(out, "The tool \"{s}\" is unknown.", .{name}) catch "The requested tool is unknown.",
        .is_error = true,
    };
}
