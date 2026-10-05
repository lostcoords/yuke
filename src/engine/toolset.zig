//! The process supplies the port that runs tools. A built-in and an extension tool share one path.
//! The engine sends `decls` to the provider. It calls `run` with the registration that the run loadout holds for the chosen name.

const std = @import("std");
const proto = @import("proto");
const utf8 = @import("../utf8.zig");
const ir = @import("ai").ir;
const work = @import("../session/work.zig");

pub const Site = proto.input.ToolSite;

/// The id of one tool registration. The process never reuses an id, so a call never runs a newer registration of the same name.
pub const Id = u32;

/// One served tool: the declaration the provider reads and the registration that runs it.
/// Each registration keeps one id for its life, and no other registration takes that id.
pub const Served = struct { decl: ir.Tool, id: Id };

pub const Context = struct {
    /// The registration that the run loadout holds for the called name.
    tool: Id,
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

/// The result of one tool run. `is_error` selects the completed state or the error state. Its JSON form is the JS `ToolOutcome`.
pub const Outcome = struct {
    output: []const u8,
    /// The file changes the UI shows. The model never reads them.
    diff: []const proto.tool.DiffFile = &.{},
    /// The images beside the output. Tool output is peer input, so the engine admits each blob before it commits the result.
    media: []const proto.content.MediaBlob = &.{},
    /// The definitions a search loaded. The engine admits each one against the run loadout.
    tools_added: []const proto.tool.ToolDefinition = &.{},
    is_error: bool = false,
};

pub const ToolSet = struct {
    ctx: *anyopaque = undefined,
    /// Answer every tool the process serves, in table order. The result belongs to `arena`.
    decls: *const fn (ctx: *anyopaque, arena: std.mem.Allocator) error{OutOfMemory}![]const Served = noDecls,
    /// Run the registration `context.tool`. `name` is the name the provider chose.
    run: *const fn (
        ctx: *anyopaque,
        out: std.mem.Allocator,
        name: []const u8,
        arguments: []const u8,
        context: Context,
    ) Outcome = unknownTool,
    /// Save the whole text of a result that the engine cuts. Return its absolute path, allocated with `out`, or null when the save fails.
    spill: *const fn (ctx: *anyopaque, out: std.mem.Allocator, text: []const u8) ?[]const u8 = noSpill,
};

/// A process without extensions advertises no tool.
fn noDecls(_: *anyopaque, _: std.mem.Allocator) error{OutOfMemory}![]const Served {
    return &.{};
}

/// A process without extensions has no spill directory.
fn noSpill(_: *anyopaque, _: std.mem.Allocator, _: []const u8) ?[]const u8 {
    return null;
}

/// A name the process does not serve answers the model, so a turn continues.
fn unknownTool(_: *anyopaque, out: std.mem.Allocator, name: []const u8, _: []const u8, _: Context) Outcome {
    return .{
        .output = std.fmt.allocPrint(out, "The tool \"{s}\" is unknown.", .{name}) catch "The requested tool is unknown.",
        .is_error = true,
    };
}

/// The marker at a cut whose whole text sits in a file. Its arguments are the dropped byte count and the file path.
pub const saved_marker = "[yuke cut {d} bytes here. Full output: {s}. Read it with start and end, or run grep with exec.]";
/// The marker at a cut whose whole text has no file. Its argument is the dropped byte count.
pub const unsaved_marker = "[yuke cut {d} bytes here. yuke kept no copy of the full output.]";

/// Answer `text` cut to the cap, or null when it fits: the head and the tail stay, and `set` saves the whole text. The result belongs to `arena`.
pub fn cut(set: ToolSet, arena: std.mem.Allocator, text: []const u8) error{OutOfMemory}!?[]const u8 {
    const cap: usize = proto.meta.limits.max_tool_result_bytes;
    if (text.len <= cap) return null;
    const kept = middleCut(text, cap / 2);
    const head = text[0..kept.head_end];
    const tail = text[kept.tail_start..];
    const dropped = kept.tail_start - kept.head_end;
    // The marker takes its own line, so a head without a final line break gets one.
    const gap = if (std.mem.endsWith(u8, head, "\n")) "" else "\n";
    if (set.spill(set.ctx, arena, text)) |path|
        return try std.fmt.allocPrint(arena, "{s}{s}" ++ saved_marker ++ "\n{s}", .{ head, gap, dropped, path, tail });
    return try std.fmt.allocPrint(arena, "{s}{s}" ++ unsaved_marker ++ "\n{s}", .{ head, gap, dropped, tail });
}

/// Return the ranges that a middle cut keeps: at most `half` bytes from each end, on line boundaries when possible and always on character boundaries.
fn middleCut(text: []const u8, half: usize) struct { head_end: usize, tail_start: usize } {
    std.debug.assert(text.len > 2 * half); // the caller passes only a text that exceeds the cap
    const floor = utf8.floor(text, half);
    // A head with no line break keeps its character boundary, so one long line still shows its start.
    const head_end = if (std.mem.lastIndexOfScalar(u8, text[0..floor], '\n')) |nl| nl + 1 else floor;
    const from = text.len - half;
    const aligned = from + utf8.head(text[from..]);
    const tail_start = if (std.mem.indexOfScalar(u8, text[aligned..], '\n')) |nl| aligned + nl + 1 else aligned;
    return .{ .head_end = head_end, .tail_start = tail_start };
}
