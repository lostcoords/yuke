//! The process supplies the port that runs tools; the engine never names a tool: it sends `decls` to the provider and calls `run` with the name the provider chose, so a built-in tool and a future extension tool use the same path.

const std = @import("std");
const proto = @import("proto");
const ir = @import("ai").ir;

pub const Site = proto.input.ToolSite;

pub const Selection = struct {
    can_spawn: bool = false,
    /// The session catalog lists at least one skill, so the skill tool has something to load.
    has_skills: bool = false,
};

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
    /// Answer what the provider may call. The result belongs to `arena`.
    getDecls: *const fn (ctx: *anyopaque, arena: std.mem.Allocator, selection: Selection) error{OutOfMemory}![]const ir.Tool = noDecls,
    /// Answer whether a provider tool call is allowed for this selection.
    isAllowed: *const fn (ctx: *anyopaque, name: []const u8, selection: Selection) bool = allow,
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
fn noDecls(_: *anyopaque, _: std.mem.Allocator, _: Selection) error{OutOfMemory}![]const ir.Tool {
    return &.{};
}

fn allow(_: *anyopaque, _: []const u8, _: Selection) bool {
    return true;
}

/// A name the process does not serve answers the model, so a turn continues.
fn unknownTool(_: *anyopaque, out: std.mem.Allocator, name: []const u8, _: []const u8, _: Context) Outcome {
    return .{
        .output = std.fmt.allocPrint(out, "The tool \"{s}\" is unknown.", .{name}) catch "The requested tool is unknown.",
        .is_error = true,
    };
}
