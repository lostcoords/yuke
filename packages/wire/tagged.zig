//! Shared codec for internally-tagged wire unions.

const std = @import("std");

const disc = "type";

/// Decode a tagged wire union from JSON.
pub fn jsonParse(comptime T: type, a: std.mem.Allocator, source: anytype, o: std.json.ParseOptions) !T {
    const v = try std.json.Value.jsonParse(a, source, o);
    return fromValue(T, a, v, o);
}

/// Decode a tagged wire union from a JSON value.
pub fn fromValue(comptime T: type, a: std.mem.Allocator, v: std.json.Value, o: std.json.ParseOptions) !T {
    const obj = switch (v) {
        .object => |obj| obj,
        else => return error.UnexpectedToken,
    };
    const tag = switch (obj.get(disc) orelse return error.MissingField) {
        .string => |s| s,
        else => return error.UnexpectedToken,
    };

    // Arm fields share the flat object with the discriminator.
    var arm_opts = o;
    arm_opts.ignore_unknown_fields = true;

    inline for (@typeInfo(T).@"union".fields) |f| {
        if (std.mem.eql(u8, f.name, tag))
            return @unionInit(T, f.name, try std.json.parseFromValueLeaky(f.type, a, v, arm_opts));
    }

    return error.InvalidEnumTag; // unknown discriminator — strict rejection
}

/// Encode a tagged wire union as JSON.
pub fn stringify(comptime T: type, self: T, jw: *std.json.Stringify) !void {
    try jw.beginObject();
    try jw.objectField(disc);
    switch (self) {
        inline else => |arm, tag| {
            try jw.write(@tagName(tag));
            inline for (@typeInfo(@TypeOf(arm)).@"struct".fields) |af| {
                const fv = @field(arm, af.name);
                var emit = true;
                if (@typeInfo(af.type) == .optional) {
                    if (fv == null and !jw.options.emit_null_optional_fields) emit = false;
                }
                if (emit) {
                    try jw.objectField(af.name);
                    try jw.write(fv);
                }
            }
        },
    }
    try jw.endObject();
}
