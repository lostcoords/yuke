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
    /// A set with no tool. Every name is unknown, so a run answers the model instead of failing.
    pub const none: ToolSet = .{ .ctx = undefined, .vtable = &none_vtable, .decls = &.{} };

    ctx: *anyopaque,
    vtable: *const VTable,
    /// What the provider is told it may call. It stays fixed while the engine holds this set.
    decls: []const ir.Tool,

    pub const VTable = struct {
        run: *const fn (
            ctx: *anyopaque,
            out: std.mem.Allocator,
            name: []const u8,
            arguments: []const u8,
            workspace_root: []const u8,
        ) Outcome,
    };

    /// Return true when this is the empty set used before extensions boot.
    pub fn isNone(self: ToolSet) bool {
        return self.vtable == &none_vtable;
    }

    /// Run `name`. The result belongs to `out` and the path root belongs to the session.
    pub fn run(
        self: ToolSet,
        out: std.mem.Allocator,
        name: []const u8,
        arguments: []const u8,
        workspace_root: []const u8,
    ) Outcome {
        std.debug.assert(name.len != 0); // the reducer never opens a tool part without a name
        return self.vtable.run(self.ctx, out, name, arguments, workspace_root);
    }
};

const none_vtable: ToolSet.VTable = .{ .run = struct {
    fn run(_: *anyopaque, out: std.mem.Allocator, name: []const u8, _: []const u8, _: []const u8) Outcome {
        return .{
            .output = std.fmt.allocPrint(out, "The tool \"{s}\" is unknown.", .{name}) catch "The requested tool is unknown.",
            .is_error = true,
        };
    }
}.run };
