const std = @import("std");
const Host = @import("host.zig").Host;
const term_pkg = @import("term");

pub const Paint = struct {
    const Self = @This();
    env_map: std.process.Environ.Map,
    render: term_pkg.Render,
    sink: std.Io.Writer.Allocating,
    out: std.Io.Writer.Allocating,

    pub fn setup(self: *Self, gpa: std.mem.Allocator, rows: u16, cols: u16) !void {
        self.env_map = try std.testing.environ.createMap(gpa);
        errdefer self.env_map.deinit();
        self.sink = .init(gpa);
        errdefer self.sink.deinit();
        self.out = .init(gpa);
        errdefer self.out.deinit();
        self.render = try term_pkg.Render.init(std.testing.io, gpa, &self.env_map, .{});
        errdefer self.render.deinit(&self.sink.writer);
        try self.render.resize(&self.sink.writer, .{ .rows = rows, .cols = cols, .x_pixel = 0, .y_pixel = 0 });
    }

    pub fn deinit(self: *Self) void {
        self.render.deinit(&self.sink.writer);
        self.out.deinit();
        self.sink.deinit();
        self.env_map.deinit();
    }

    pub fn bind(self: *Self, host: *Host) void {
        host.paint.bindRender(host.ctx, &self.render, &self.out.writer);
    }
};
