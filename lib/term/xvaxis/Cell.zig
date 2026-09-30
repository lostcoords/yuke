const std = @import("std");
const Image = @import("Image.zig");

char: Character = .{},
style: Style = .{},
link: Hyperlink = .{},
image: ?Image.Placement = null,
default: bool = false,
/// Set to true if this cell is the last cell printed in a row before wrap. Vaxis will determine if
/// it should rely on the terminal's autowrap feature which can help with primary screen resizes
wrapped: bool = false,
scale: Scale = .{},

/// Segment is a contiguous run of text that has a constant style
pub const Segment = struct {
    text: []const u8,
    style: Style = .{},
    link: Hyperlink = .{},
};

pub const Character = struct {
    grapheme: []const u8 = " ",
    /// width should only be provided when the application is sure the terminal
    /// will measure the same width. This can be ensure by using the gwidth method
    /// included in libvaxis. If width is 0, libvaxis will measure the glyph at
    /// render time
    width: u8 = 1,
};

pub const CursorShape = enum {
    default,
    block_blink,
    block,
    underline_blink,
    underline,
    beam_blink,
    beam,
};

pub const Hyperlink = struct {
    uri: []const u8 = "",
    /// ie "id=app-1234"
    params: []const u8 = "",
};

pub const Scale = packed struct {
    scale: u3 = 1,
    // The spec allows up to 15, but we limit to 7
    numerator: u4 = 1,
    // The spec allows up to 15, but we limit to 7
    denominator: u4 = 1,
    vertical_alignment: enum(u2) {
        top = 0,
        bottom = 1,
        center = 2,
    } = .top,

    pub fn eql(self: Scale, other: Scale) bool {
        const a_scale: u13 = @bitCast(self);
        const b_scale: u13 = @bitCast(other);
        return a_scale == b_scale;
    }
};

pub const Style = struct {
    pub const Underline = enum {
        off,
        single,
        double,
        curly,
        dotted,
        dashed,
    };

    fg: Color = .default,
    bg: Color = .default,
    ul: Color = .default,
    ul_style: Underline = .off,

    bold: bool = false,
    dim: bool = false,
    italic: bool = false,
    blink: bool = false,
    reverse: bool = false,
    invisible: bool = false,
    strikethrough: bool = false,

    /// Do not fold the flags into a packed struct: that compare makes the render diff four times slower.
    pub fn eql(a: Style, b: Style) bool {
        return a.bold == b.bold and
            a.dim == b.dim and
            a.italic == b.italic and
            a.blink == b.blink and
            a.reverse == b.reverse and
            a.invisible == b.invisible and
            a.strikethrough == b.strikethrough and
            a.ul_style == b.ul_style and
            Color.eql(a.fg, b.fg) and
            Color.eql(a.bg, b.bg) and
            Color.eql(a.ul, b.ul);
    }
};

pub const Color = union(enum) {
    default,
    index: u8,
    rgb: [3]u8,

    pub const Kind = union(enum) {
        fg,
        bg,
        cursor,
        index: u8,
    };

    /// Returned when querying a color from the terminal
    pub const Report = struct {
        kind: Kind,
        value: [3]u8,
    };

    pub const Scheme = enum {
        dark,
        light,
    };

    pub fn eql(a: Color, b: Color) bool {
        switch (a) {
            .default => return b == .default,
            .index => |a_idx| {
                switch (b) {
                    .index => |b_idx| return a_idx == b_idx,
                    else => return false,
                }
            },
            .rgb => |a_rgb| {
                switch (b) {
                    .rgb => |b_rgb| return a_rgb[0] == b_rgb[0] and
                        a_rgb[1] == b_rgb[1] and
                        a_rgb[2] == b_rgb[2],
                    else => return false,
                }
            },
        }
    }

    pub fn rgbFromUint(val: u24) Color {
        const r_bits = val & 0b11111111_00000000_00000000;
        const g_bits = val & 0b00000000_11111111_00000000;
        const b_bits = val & 0b00000000_00000000_11111111;
        const rgb = [_]u8{
            @truncate(r_bits >> 16),
            @truncate(g_bits >> 8),
            @truncate(b_bits),
        };
        return .{ .rgb = rgb };
    }

    /// Parse a terminal color reply, `rgb:rrrr/gggg/bbbb` or `rgba:rrrr/gggg/bbbb/aaaa`, into an rgb Color. Each channel keeps its high byte. The alpha channel is checked and dropped.
    pub fn rgbFromSpec(spec: []const u8) error{InvalidColorSpec}!Color {
        const colon = std.mem.indexOfScalar(u8, spec, ':') orelse return error.InvalidColorSpec;
        const prefix = spec[0..colon];
        const channels: usize = if (std.mem.eql(u8, prefix, "rgb")) 3 else if (std.mem.eql(u8, prefix, "rgba")) 4 else return error.InvalidColorSpec;
        var iter = std.mem.splitScalar(u8, spec[colon + 1 ..], '/');
        var rgb: [3]u8 = undefined;
        for (0..channels) |i| {
            const digits = iter.next() orelse return error.InvalidColorSpec;
            if (digits.len != 4) return error.InvalidColorSpec;
            // Each of the 4 characters must be a hex digit; `parseUnsigned` would accept `_`.
            var high: u8 = 0;
            for (digits, 0..) |c, j| {
                const digit = std.fmt.charToDigit(c, 16) catch return error.InvalidColorSpec;
                if (j < 2) high = high * 16 + digit;
            }
            if (i < rgb.len) rgb[i] = high;
        }
        if (iter.next() != null) return error.InvalidColorSpec;
        return .{ .rgb = rgb };
    }

    test "rgbFromSpec keeps the high byte of each channel" {
        try std.testing.expectEqual([3]u8{ 0x12, 0xff, 0x00 }, (try rgbFromSpec("rgb:1234/ffff/0000")).rgb);
        try std.testing.expectEqual([3]u8{ 0x1e, 0x1e, 0x2e }, (try rgbFromSpec("rgba:1e1e/1e1e/2e2e/c000")).rgb);
        try std.testing.expectError(error.InvalidColorSpec, rgbFromSpec("rgb:1e/1e/2e"));
        try std.testing.expectError(error.InvalidColorSpec, rgbFromSpec("rgb:1e1e/1e1e"));
        try std.testing.expectError(error.InvalidColorSpec, rgbFromSpec("rgb:1e1e/1e1e/2e2e/c000"));
        try std.testing.expectError(error.InvalidColorSpec, rgbFromSpec("rgb:1_2f/0000/0000"));
    }
};

test {
    std.testing.refAllDecls(@This());
}

test "Style.eql detects a change in every style field" {
    const base: Style = .{};
    try std.testing.expect(Style.eql(base, .{}));

    // Each changed field must break equality.
    try std.testing.expect(!Style.eql(base, .{ .bold = true }));
    try std.testing.expect(!Style.eql(base, .{ .dim = true }));
    try std.testing.expect(!Style.eql(base, .{ .italic = true }));
    try std.testing.expect(!Style.eql(base, .{ .blink = true }));
    try std.testing.expect(!Style.eql(base, .{ .reverse = true }));
    try std.testing.expect(!Style.eql(base, .{ .invisible = true }));
    try std.testing.expect(!Style.eql(base, .{ .strikethrough = true }));
    try std.testing.expect(!Style.eql(base, .{ .ul_style = .single }));
    try std.testing.expect(!Style.eql(base, .{ .fg = .{ .index = 1 } }));
    try std.testing.expect(!Style.eql(base, .{ .bg = .{ .index = 1 } }));
    try std.testing.expect(!Style.eql(base, .{ .ul = .{ .index = 1 } }));

    // Each color field compares the variant and the value, not only the presence of a color.
    inline for (.{ "fg", "bg", "ul" }) |field| {
        var index_a: Style = .{};
        var index_b: Style = .{};
        var rgb_a: Style = .{};
        var rgb_b: Style = .{};
        @field(index_a, field) = .{ .index = 1 };
        @field(index_b, field) = .{ .index = 2 };
        @field(rgb_a, field) = .{ .rgb = .{ 1, 2, 3 } };
        @field(rgb_b, field) = .{ .rgb = .{ 1, 2, 4 } };
        try std.testing.expect(!Style.eql(index_a, index_b));
        try std.testing.expect(!Style.eql(rgb_a, rgb_b));
        try std.testing.expect(!Style.eql(index_a, rgb_a));
        try std.testing.expect(Style.eql(rgb_a, rgb_a));
    }
}
