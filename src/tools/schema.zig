//! Build a tool's JSON Schema from its argument struct at compile time. The struct defines the
//! schema. The parser uses the same struct.

const std = @import("std");

/// A JSON string argument. `std.json` also decodes a byte array into `[]const u8`, but the schema
/// declares a string. This type accepts the string form only, so the schema and the parser agree.
pub const Str = struct {
    bytes: []const u8,

    pub fn jsonParse(a: std.mem.Allocator, source: anytype, options: std.json.ParseOptions) !Str {
        if (try source.peekNextTokenType() != .string) return error.UnexpectedToken;
        return .{ .bytes = try std.json.innerParse([]const u8, a, source, options) };
    }
    pub fn jsonParseFromValue(a: std.mem.Allocator, v: std.json.Value, options: std.json.ParseOptions) !Str {
        if (v != .string) return error.UnexpectedToken;
        return .{ .bytes = try std.json.innerParseFromValue([]const u8, a, v, options) };
    }
};

/// One field annotation. `minimum` and `maximum` apply to an integer field only.
pub const Field = struct {
    description: []const u8,
    minimum: ?i64 = null,
    maximum: ?i64 = null,
};

/// Return the annotation struct for `Args`: one `Field` per argument. A missing or extra annotation
/// is a compile error, so the schema and the argument struct stay one source.
pub fn Docs(comptime Args: type) type {
    return @Struct(.auto, null, std.meta.fieldNames(Args), &@splat(Field), &@splat(.{}));
}

/// Return the JSON Schema for `Args`. The schema rejects an unknown key. `std.json` uses the same
/// rule. A field is required only when it has no default and is not optional.
pub fn of(comptime Args: type, comptime docs: Docs(Args)) []const u8 {
    return comptime blk: {
        var props: []const u8 = "";
        var required: []const u8 = "";
        for (@typeInfo(Args).@"struct".fields) |f| {
            if (props.len != 0) props = props ++ ",";
            props = props ++ quote(f.name) ++ ":" ++ property(f.type, @field(docs, f.name));
            // `std.json` fills a default, so such a field is optional to the caller as well.
            if (@typeInfo(f.type) == .optional or f.default_value_ptr != null) continue;
            if (required.len != 0) required = required ++ ",";
            required = required ++ quote(f.name);
        }
        break :blk "{\"type\":\"object\",\"properties\":{" ++ props ++
            "},\"required\":[" ++ required ++ "],\"additionalProperties\":false}";
    };
}

/// Return the schema of one field. An optional field uses the inner type. Its declared type also
/// accepts null, because `std.json` decodes an explicit null into the optional.
fn property(comptime T: type, comptime doc: Field) []const u8 {
    const optional = @typeInfo(T) == .optional;
    const Inner = if (optional) @typeInfo(T).optional.child else T;
    const base: []const u8 = switch (@typeInfo(Inner)) {
        .bool => "boolean",
        .int => "integer",
        .@"struct" => blk: {
            if (Inner != Str) @compileError("a tool argument struct must be schema.Str");
            break :blk "string";
        },
        else => @compileError("unsupported tool argument type: " ++ @typeName(Inner) ++ "; a string uses schema.Str"),
    };
    const extra = if (@typeInfo(Inner) == .int)
        bound("minimum", doc.minimum) ++ bound("maximum", doc.maximum)
    else
        "";
    const kind = if (optional) "[" ++ quote(base) ++ ",\"null\"]" else quote(base);
    return "{\"type\":" ++ kind ++ extra ++ ",\"description\":" ++ quote(doc.description) ++ "}";
}

/// Return `,"name":value` for a set bound, or an empty string.
fn bound(comptime name: []const u8, comptime value: ?i64) []const u8 {
    const v = value orelse return "";
    return ",\"" ++ name ++ "\":" ++ std.fmt.comptimePrint("{d}", .{v});
}

/// Quote a string for JSON. It escapes a quote and a backslash. The function rejects a control
/// character and invalid UTF-8 in compile-time text.
fn quote(comptime s: []const u8) []const u8 {
    return comptime blk: {
        if (!std.unicode.utf8ValidateSlice(s)) @compileError("a schema string must hold valid UTF-8");
        var out: []const u8 = "\"";
        for (s) |c| {
            if (c < 0x20) @compileError("a schema string must not hold a control character");
            out = out ++ switch (c) {
                '"' => "\\\"",
                '\\' => "\\\\",
                else => &[_]u8{c},
            };
        }
        break :blk out ++ "\"";
    };
}

const testing = std.testing;

test "of builds a closed schema" {
    const Args = struct { path: Str, start: ?usize = null, keep: ?bool = null };
    const built = of(Args, .{
        .path = .{ .description = "The file path." },
        .start = .{ .description = "The first line.", .minimum = 1 },
        .keep = .{ .description = "Keep the file." },
    });
    try testing.expectEqualStrings(
        \\{"type":"object","properties":{"path":{"type":"string","description":"The file path."},"start":{"type":["integer","null"],"minimum":1,"description":"The first line."},"keep":{"type":["boolean","null"],"description":"Keep the file."}},"required":["path"],"additionalProperties":false}
    , built);
}

test "of omits a field with a Zig default from required" {
    // `std.json` fills the default, so the caller may omit the key.
    const Args = struct { path: Str, replace_all: bool = false };
    const built = of(Args, .{
        .path = .{ .description = "The file path." },
        .replace_all = .{ .description = "Replace every match." },
    });
    try testing.expect(std.mem.indexOf(u8, built, "\"required\":[\"path\"]") != null);
    try testing.expect(std.mem.indexOf(u8, built, "\"replace_all\":{\"type\":\"boolean\"") != null);
}

test "of escapes a quote in a description" {
    const Args = struct { path: Str };
    const built = of(Args, .{ .path = .{ .description = "Pass \"x\" here." } });
    try testing.expect(std.mem.indexOf(u8, built, "Pass \\\"x\\\" here.") != null);
}

test "the generated schema parses as JSON" {
    const Args = struct { path: Str, end: ?u32 = null };
    const built = of(Args, .{ .path = .{ .description = "p" }, .end = .{ .description = "e", .maximum = 9 } });
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const v = try std.json.parseFromSliceLeaky(std.json.Value, arena.allocator(), built, .{});
    try testing.expectEqual(false, v.object.get("additionalProperties").?.bool);
    const end = v.object.get("properties").?.object.get("end").?.object;
    try testing.expectEqual(@as(i64, 9), end.get("maximum").?.integer);
    try testing.expectEqualStrings("null", end.get("type").?.array.items[1].string);
}

test "Str accepts a JSON string and rejects the byte-array form" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const Args = struct { path: Str };
    const ok = try std.json.parseFromSliceLeaky(Args, a, "{\"path\":\"hi\"}", .{});
    try testing.expectEqualStrings("hi", ok.path.bytes);
    // `std.json` decodes [104,105] into []const u8; the schema declares a string, so Str refuses it.
    try testing.expectError(error.UnexpectedToken, std.json.parseFromSliceLeaky(Args, a, "{\"path\":[104,105]}", .{}));
}
