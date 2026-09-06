//! Emit TypeScript declarations from the generated protocol schema.

const std = @import("std");

const Field = struct { name: []const u8, type: []const u8, presence: enum { required, optional, defaulted }, doc: ?[]const u8 = null };
const Structure = struct { name: []const u8, fields: []const Field, doc: ?[]const u8 = null };
const Arm = struct { type: []const u8, tag: ?[]const u8 = null, doc: ?[]const u8 = null };
const Union = struct { name: []const u8, discriminator: []const u8, arms: []const Arm, doc: ?[]const u8 = null };
const EnumValue = struct { name: []const u8, wire: []const u8, doc: ?[]const u8 = null };
const Enumeration = struct { name: []const u8, numeric: bool, values: []const EnumValue, doc: ?[]const u8 = null };
const Alias = struct { name: []const u8, base: []const u8, doc: ?[]const u8 = null };
const Method = struct { name: []const u8, params: []const u8, result: []const u8, paramsOptional: bool, doc: ?[]const u8 = null };
const Broadcast = struct { name: []const u8, params: []const u8, doc: ?[]const u8 = null };
const Schema = struct {
    structures: []const Structure,
    unions: []const Union,
    enumerations: []const Enumeration,
    aliases: []const Alias,
    methods: []const Method,
    broadcasts: []const Broadcast,

    fn hasType(self: Schema, name: []const u8) bool {
        inline for (.{ self.structures, self.unions, self.enumerations, self.aliases }) |entries| {
            for (entries) |entry| if (std.mem.eql(u8, entry.name, name)) return true;
        }
        return false;
    }

    fn isEmpty(self: Schema, name: []const u8) bool {
        for (self.structures) |entry| if (std.mem.eql(u8, entry.name, name)) return entry.fields.len == 0;
        return false;
    }
};

fn digits(text: []const u8) bool {
    if (text.len == 0) return false;
    for (text) |c| if (!std.ascii.isDigit(c)) return false;
    return true;
}

fn writeType(w: *std.Io.Writer, schema: Schema, name: []const u8) (std.Io.Writer.Error || error{ InvalidType, UnknownType })!void {
    if (std.mem.eql(u8, name, "string")) return w.writeAll("string");
    if (std.mem.eql(u8, name, "bool")) return w.writeAll("boolean");
    if (name.len > 1 and std.mem.findScalar(u8, "uif", name[0]) != null and digits(name[1..])) return w.writeAll("number");
    if (std.mem.startsWith(u8, name, "[")) {
        const end = std.mem.findScalar(u8, name, ']') orelse return error.InvalidType;
        if (end != 1 and !digits(name[1..end])) return error.InvalidType;
        const child = name[end + 1 ..];
        if (end != 1 and std.mem.eql(u8, child, "u8")) return w.writeAll("string");
        try w.writeAll("ReadonlyArray<");
        try writeType(w, schema, child);
        return w.writeByte('>');
    }
    if (!schema.hasType(name)) return error.UnknownType;
    try w.writeAll(name);
}

fn quoted(w: *std.Io.Writer, text: []const u8) !void {
    try std.json.Stringify.value(text, .{}, w);
}

fn writeDoc(w: *std.Io.Writer, indent: []const u8, doc: ?[]const u8) !void {
    const text = doc orelse return;
    try w.print("{s}/** ", .{indent});
    for (text, 0..) |c, i| {
        if (c == '/' and i > 0 and text[i - 1] == '*') try w.writeByte('\\');
        try w.writeByte(if (c == '\n' or c == '\r') ' ' else c);
    }
    try w.writeAll(" */\n");
}

fn writeStruct(w: *std.Io.Writer, schema: Schema, entry: Structure) !void {
    try writeDoc(w, "", entry.doc);
    if (std.mem.eql(u8, entry.name, "Notification")) {
        return w.writeAll("export type Notification = {\n  [M in keyof Broadcasts]: { readonly method: M; readonly params: Broadcasts[M] }\n}[keyof Broadcasts];\n\n");
    }
    if (entry.fields.len == 0) return w.print("export type {s} = Record<string, never>;\n\n", .{entry.name});
    try w.print("export interface {s} {{\n", .{entry.name});
    for (entry.fields) |field| {
        try writeDoc(w, "  ", field.doc);
        try w.print("  readonly {s}{s}: ", .{ field.name, if (field.presence == .required) "" else "?" });
        try writeType(w, schema, field.type);
        try w.writeAll(";\n");
    }
    try w.writeAll("}\n\n");
}

fn writeUnion(w: *std.Io.Writer, schema: Schema, entry: Union) !void {
    if (entry.arms.len == 0) return error.EmptyUnion;
    try writeDoc(w, "", entry.doc);
    try w.print("export type {s} =\n", .{entry.name});
    for (entry.arms) |arm| {
        try writeDoc(w, "  ", arm.doc);
        try w.writeAll("  | ");
        if (entry.discriminator.len != 0) {
            const tag = arm.tag orelse return error.MissingTag;
            try w.print("{{ readonly {s}: ", .{entry.discriminator});
            try quoted(w, tag);
            try w.writeAll(" }");
            if (!schema.isEmpty(arm.type)) {
                try w.writeAll(" & ");
                try writeType(w, schema, arm.type);
            }
        } else try writeType(w, schema, arm.type);
        try w.writeByte('\n');
    }
    try w.writeAll(";\n\n");
}

fn writeEnum(w: *std.Io.Writer, entry: Enumeration) !void {
    if (entry.values.len == 0) return error.EmptyEnum;
    try writeDoc(w, "", entry.doc);
    try w.print("export type {s} =\n", .{entry.name});
    for (entry.values) |value| {
        try writeDoc(w, "  ", value.doc);
        if (entry.numeric) try writeDoc(w, "  ", value.name);
        try w.writeAll("  | ");
        if (entry.numeric) {
            _ = try std.fmt.parseInt(i64, value.wire, 10);
            try w.writeAll(value.wire);
        } else try quoted(w, value.wire);
        try w.writeByte('\n');
    }
    try w.writeAll(";\n\n");
}

fn writeMaps(w: *std.Io.Writer, schema: Schema) !void {
    try w.writeAll("export interface Methods {\n");
    for (schema.methods) |method| {
        try writeDoc(w, "  ", method.doc);
        try w.writeAll("  ");
        try quoted(w, method.name);
        try w.writeAll(": { paramsType: [");
        try writeType(w, schema, method.params);
        if (method.paramsOptional) try w.writeByte('?');
        try w.writeAll("]; returnType: ");
        try writeType(w, schema, method.result);
        try w.writeAll(" };\n");
    }
    try w.writeAll("}\n\nexport interface Broadcasts {\n");
    for (schema.broadcasts) |broadcast| {
        try writeDoc(w, "  ", broadcast.doc);
        try w.writeAll("  ");
        try quoted(w, broadcast.name);
        try w.writeAll(": ");
        try writeType(w, schema, broadcast.params);
        try w.writeAll(";\n");
    }
    try w.writeAll("}\n\n");
}

fn emit(w: *std.Io.Writer, schema: Schema) !void {
    try w.writeAll("// GENERATED by tools/protogen (zig build gen-schema). Do not edit.\n");
    try w.writeAll("declare namespace Wire {\n\n");
    for (schema.structures) |entry| try writeStruct(w, schema, entry);
    for (schema.enumerations) |entry| try writeEnum(w, entry);
    for (schema.unions) |entry| try writeUnion(w, schema, entry);
    for (schema.aliases) |entry| {
        try writeDoc(w, "", entry.doc);
        try w.print("export type {s} = ", .{entry.name});
        try writeType(w, schema, entry.base);
        try w.writeAll(";\n\n");
    }
    try writeMaps(w, schema);
    try w.writeAll("}\n");
}

pub fn main(init: std.process.Init) !void {
    const a = init.arena.allocator();
    const args = try init.minimal.args.toSlice(a);
    if (args.len != 2) return error.ExpectedSchemaPath;
    const text = try std.Io.Dir.cwd().readFileAlloc(init.io, args[1], a, .unlimited);
    const schema = try std.json.parseFromSliceLeaky(Schema, a, text, .{ .ignore_unknown_fields = true });
    var stdout_buffer: [4096]u8 = undefined;
    var stdout = std.Io.File.stdout().writer(init.io, &stdout_buffer);
    try emit(&stdout.interface, schema);
    try stdout.interface.flush();
}

const testing = std.testing;
const test_schema: Schema = .{ .structures = &.{.{ .name = "Empty", .fields = &.{} }}, .unions = &.{}, .enumerations = &.{}, .aliases = &.{.{ .name = "InputId", .base = "u64" }}, .methods = &.{}, .broadcasts = &.{} };

test "type text preserves aliases and nested arrays and rejects unknown names" {
    var out: std.Io.Writer.Allocating = .init(testing.allocator);
    defer out.deinit();
    try writeType(&out.writer, test_schema, "[][]InputId");
    try testing.expectEqualStrings("ReadonlyArray<ReadonlyArray<InputId>>", out.written());
    try testing.expectError(error.UnknownType, writeType(&out.writer, test_schema, "Missing"));
    try testing.expectError(error.InvalidType, writeType(&out.writer, test_schema, "[x]u8"));
    out.clearRetainingCapacity();
    try writeType(&out.writer, test_schema, "[64]u8");
    try testing.expectEqualStrings("string", out.written());
}

test "documentation cannot terminate its comment or add a line" {
    var out: std.Io.Writer.Allocating = .init(testing.allocator);
    defer out.deinit();
    try writeDoc(&out.writer, "  ", "text */\nnext");
    try testing.expectEqualStrings("  /** text *\\/ next */\n", out.written());
}

test "empty tagged payloads keep their discriminator" {
    var out: std.Io.Writer.Allocating = .init(testing.allocator);
    defer out.deinit();
    try writeUnion(&out.writer, test_schema, .{ .name = "Outcome", .discriminator = "type", .arms = &.{.{ .tag = "canceled", .type = "Empty" }} });
    try testing.expectEqualStrings("export type Outcome =\n  | { readonly type: \"canceled\" }\n;\n\n", out.written());
}
