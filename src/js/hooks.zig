//! The hook points a plugin holds, and the one JavaScript function that folds a chain.
//!
//! A chain folds in JavaScript, not here. `yuke:ext` installs one dispatcher that walks its own
//! handler list and answers a single Promise, so the owner polls a hook exactly like a tool call.
//!
//! `points` is the only part a turn task reads. The task never enters QuickJS, so the owner keeps
//! this set true after every registration and the task reads it to skip a call no handler wants.

const std = @import("std");
const quickjs = @import("quickjs");
const proto = @import("proto");

const Context = quickjs.Context;
const Value = quickjs.Value;

pub const Point = proto.hook.Point;
pub const PointSet = std.EnumSet(Point);

pub const Hooks = struct {
    /// The points that hold at least one handler. Only the owner writes it.
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

    /// Record which points hold a handler. `yuke:ext` calls this after every add and drop.
    pub fn setPoints(self: *Hooks, points: PointSet) void {
        self.points = points;
    }
};

const testing = std.testing;

test "an empty table holds no point" {
    var hooks: Hooks = .{};
    for (std.meta.tags(Point)) |point| try testing.expect(!hooks.holds(point));
}

test "a point holds nothing until a folder is installed" {
    var hooks: Hooks = .{};
    var points: PointSet = .initEmpty();
    points.insert(.@"tool.before");
    hooks.setPoints(points);
    // The set alone cannot answer a call, so a table without a folder still holds nothing.
    try testing.expect(!hooks.holds(.@"tool.before"));
}
