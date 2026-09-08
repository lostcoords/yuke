const std = @import("std");
const assert = std.debug.assert;

const Cell = @import("Cell.zig");
const Shape = @import("Mouse.zig").Shape;
const Winsize = @import("main.zig").Winsize;
const Method = @import("gwidth.zig").Method;
const gwidth = @import("gwidth.zig");

const Screen = @This();
pub const Cursor = struct { row: u16 = 0, col: u16 = 0 };

width: u16 = 0,
height: u16 = 0,

width_pix: u16 = 0,
height_pix: u16 = 0,

buf: []Cell = &.{},

cursor: Cursor = .{},
cursor_vis: bool = false,
cursor_secondary: []Cursor = &.{},

width_method: Method = .wcwidth,
max_cell_width: u16 = 1,

mouse_shape: Shape = .default,
cursor_shape: Cell.CursorShape = .default,

pub fn init(alloc: std.mem.Allocator, winsize: Winsize) std.mem.Allocator.Error!Screen {
    const w = winsize.cols;
    const h = winsize.rows;
    const self = Screen{
        .buf = try alloc.alloc(Cell, @as(usize, @intCast(w)) * h),
        .width = w,
        .height = h,
        .width_pix = winsize.x_pixel,
        .height_pix = winsize.y_pixel,
    };
    const base_cell: Cell = .{};
    @memset(self.buf, base_cell);
    return self;
}

pub fn deinit(self: *Screen, alloc: std.mem.Allocator) void {
    alloc.free(self.buf);
}

/// writes a cell to a location. 0 indexed
pub fn writeCell(self: *Screen, col: u16, row: u16, cell: Cell) void {
    if (col >= self.width or
        row >= self.height)
        return;
    const i = (@as(usize, @intCast(row)) * self.width) + col;
    assert(i < self.buf.len);

    const width = self.cellWidth(cell);
    const span = @min(width, self.width - col);
    self.clearOverlaps(col, row, @intCast(span));
    @memset(self.buf[i..][0..span], .{ .style = cell.style });
    if (width > span) return;

    var normalized = cell;
    if (width <= std.math.maxInt(u8)) normalized.char.width = @intCast(width);
    self.registerCellWidth(width);
    self.buf[i] = normalized;
}

pub fn registerCellWidth(self: *Screen, width: u16) void {
    assert(width > 0);
    self.max_cell_width = @max(self.max_cell_width, width);
}

// Remove a whole glyph if the write covers any of its cells.
pub fn clearOverlaps(self: *Screen, col: u16, row: u16, count: u16) void {
    assert(row < self.height);
    assert(col <= self.width and count <= self.width - col);
    if (count == 0 or self.max_cell_width == 1) return;
    const row_start = @as(usize, row) * self.width;
    const end = @as(usize, col) + count;
    var candidate = @as(usize, col) -| (self.max_cell_width - 1);
    while (candidate < end) : (candidate += 1) {
        const cell = self.buf[row_start + candidate];
        const width = self.cellWidth(cell);
        if (width <= 1) continue;
        const glyph_end = @min(candidate + width, self.width);
        if (col < glyph_end) @memset(self.buf[row_start + candidate .. row_start + glyph_end], .{ .style = cell.style });
    }
}

fn cellWidth(self: *const Screen, cell: Cell) u16 {
    if (cell.char.width != 0) return cell.char.width;
    return @max(gwidth.gwidth(cell.char.grapheme, self.width_method), 1);
}

pub fn readCell(self: *const Screen, col: u16, row: u16) ?Cell {
    if (col >= self.width or
        row >= self.height)
        return null;
    const i = (@as(usize, @intCast(row)) * self.width) + col;
    assert(i < self.buf.len);
    return self.buf[i];
}

pub fn clear(self: *Screen) void {
    @memset(self.buf, .{});
    self.max_cell_width = 1;
}

test "Screen: auto-width continuation gets normalized" {
    var screen = try Screen.init(std.testing.allocator, .{ .rows = 1, .cols = 4, .x_pixel = 0, .y_pixel = 0 });
    defer screen.deinit(std.testing.allocator);

    screen.writeCell(1, 0, .{ .char = .{ .grapheme = "界", .width = 0 } });
    screen.writeCell(2, 0, .{ .char = .{ .grapheme = "│", .width = 1 } });
    try std.testing.expectEqualStrings(" ", (screen.readCell(1, 0) orelse unreachable).char.grapheme);
    try std.testing.expectEqualStrings("│", (screen.readCell(2, 0) orelse unreachable).char.grapheme);
}

test "Screen: wide overlap stays within the row" {
    var screen = try Screen.init(std.testing.allocator, .{ .rows = 2, .cols = 5, .x_pixel = 0, .y_pixel = 0 });
    defer screen.deinit(std.testing.allocator);

    screen.writeCell(0, 0, .{ .char = .{ .grapheme = "A", .width = 3 } });
    screen.writeCell(2, 0, .{ .char = .{ .grapheme = "B", .width = 2 } });
    screen.writeCell(1, 1, .{ .char = .{ .grapheme = "C", .width = 1 } });
    try std.testing.expectEqualStrings(" ", (screen.readCell(0, 0) orelse unreachable).char.grapheme);
    try std.testing.expectEqualStrings("B", (screen.readCell(2, 0) orelse unreachable).char.grapheme);
    try std.testing.expectEqualStrings("C", (screen.readCell(1, 1) orelse unreachable).char.grapheme);
}

test "Screen: a clipped wide cell and its adjacent row are safe" {
    var screen = try Screen.init(std.testing.allocator, .{ .rows = 2, .cols = 4, .x_pixel = 0, .y_pixel = 0 });
    defer screen.deinit(std.testing.allocator);

    screen.writeCell(3, 0, .{ .char = .{ .grapheme = "界", .width = 2 } });
    screen.writeCell(0, 1, .{ .char = .{ .grapheme = "D", .width = 1 } });
    try std.testing.expectEqualStrings(" ", (screen.readCell(3, 0) orelse unreachable).char.grapheme);
    try std.testing.expectEqualStrings("D", (screen.readCell(0, 1) orelse unreachable).char.grapheme);
}

test {
    std.testing.refAllDecls(@This());
}
