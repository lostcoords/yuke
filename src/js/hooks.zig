//! The owner holds the dispatcher and publishes its point set to the cooperative turn tasks.

const std = @import("std");
const quickjs = @import("quickjs");
const proto = @import("proto");

const Context = quickjs.Context;
const Value = quickjs.Value;

pub const Point = proto.hook.Point;
pub const PointSet = std.EnumSet(Point);

pub const Hooks = struct {
    /// The points that hold at least one handler. Only the owner writes it, after `yuke:internal/ext` adds or drops a handler.
    points: PointSet = .initEmpty(),
    /// The chain folder, held as a GC root until the table dies. A null folder answers no point.
    dispatch: ?Value = null,

    pub fn deinit(self: *Hooks, ctx: Context) void {
        if (self.dispatch) |folder| ctx.freeValue(folder);
        self.* = undefined;
    }

    /// Report whether a handler waits on `point`. A turn task calls this before it submits.
    pub fn holds(self: *const Hooks, point: Point) bool {
        return self.dispatch != null and self.points.contains(point);
    }

    /// Install the folder and drop the one it replaces. The table takes the reference.
    pub fn install(self: *Hooks, ctx: Context, folder: Value) void {
        if (self.dispatch) |old| ctx.freeValue(old);
        self.dispatch = folder;
    }
};

const testing = std.testing;

test "a point holds nothing until a folder is installed" {
    var hooks: Hooks = .{};
    var points: PointSet = .initEmpty();
    points.insert(.@"tool.before");
    hooks.points = points;
    // The set alone cannot answer a call, so a table without a folder still holds nothing.
    try testing.expect(!hooks.holds(.@"tool.before"));
}
