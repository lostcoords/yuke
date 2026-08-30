//! Generate TypeScript declarations from the wire type registry.

const std = @import("std");

const wire = @import("wire");
const generator = @import("gen.zig");
const registry = wire.registry;

const TypeEntry = registry.TypeEntry;

fn writeTypeText(
    w: *std.Io.Writer,
    comptime owner: []const u8,
    comptime field: []const u8,
    comptime T: type,
) !void {
    if (comptime generator.aliasFor(owner, field)) |alias| {
        // Presence carries optionality; map the underlying shape.
        const Inner = comptime switch (@typeInfo(T)) {
            .optional => |optional| optional.child,
            else => T,
        };
        switch (@typeInfo(Inner)) {
            .pointer => |pointer| {
                if (pointer.child == u8) try w.writeAll(alias) else try w.print("readonly {s}[]", .{alias});
            },
            else => try w.writeAll(alias),
        }
        return;
    }

    switch (@typeInfo(T)) {
        .optional => |optional| try writeTypeText(w, owner, field, optional.child),
        .pointer => |pointer| {
            if (pointer.child == u8) {
                try w.writeAll("string");
            } else {
                try w.writeAll("readonly ");
                try writeTypeText(w, owner, field, pointer.child);
                try w.writeAll("[]");
            }
        },
        .array => |array| {
            if (array.child == u8) {
                try w.writeAll("string");
            } else {
                try w.writeAll("readonly ");
                try writeTypeText(w, owner, field, array.child);
                try w.writeAll("[]");
            }
        },
        .int, .comptime_int, .float, .comptime_float => try w.writeAll("number"),
        .bool => try w.writeAll("boolean"),
        .@"struct", .@"enum", .@"union" => try w.writeAll(generator.shortName(@typeName(T))),
        else => @compileError("unsupported wire type " ++ @typeName(T)),
    }
}

fn writeField(w: *std.Io.Writer, comptime owner: []const u8, comptime field: anytype) !void {
    try w.print("  readonly {s}", .{field.name});
    if (@typeInfo(field.type) == .optional or field.defaultValue() != null) try w.writeByte('?');
    try w.writeAll(": ");
    try writeTypeText(w, owner, field.name, field.type);
    try w.writeAll(";\n");
}

fn writeStruct(w: *std.Io.Writer, entry: TypeEntry) !void {
    try w.print("export interface {s} {{\n", .{entry.name});
    inline for (@typeInfo(entry.ty).@"struct".fields) |field| try writeField(w, entry.name, field);
    try w.writeAll("}\n\n");
}

fn isEmptyPayload(comptime T: type) bool {
    return switch (@typeInfo(T)) {
        .void => true,
        .@"struct" => |info| info.fields.len == 0,
        else => false,
    };
}

fn writeTaggedUnion(w: *std.Io.Writer, entry: TypeEntry) !void {
    try w.print("export type {s} = ", .{entry.name});
    inline for (@typeInfo(entry.ty).@"union".fields, 0..) |field, index| {
        if (index != 0) try w.writeAll(" | ");
        if (isEmptyPayload(field.type)) {
            try w.print("{{ readonly type: \"{s}\" }}", .{field.name});
        } else {
            try w.print("({{ readonly type: \"{s}\" }} & ", .{field.name});
            try w.writeAll(generator.broadcastType("", entry.name, field.name, field.type));
            try w.writeByte(')');
        }
    }
    try w.writeAll(";\n\n");
}

fn writeEnvelopeUnion(w: *std.Io.Writer, entry: TypeEntry) !void {
    try w.print("export type {s} = ", .{entry.name});
    inline for (@typeInfo(entry.ty).@"union".fields, 0..) |field, index| {
        if (index != 0) try w.writeAll(" | ");
        try w.writeAll(generator.broadcastType("", entry.name, field.name, field.type));
    }
    try w.writeAll(";\n\n");
}

fn isNumericBase(comptime base: []const u8) bool {
    if (base.len < 2) return false;
    if (base[0] != 'u' and base[0] != 'i' and base[0] != 'f') return false;
    for (base[1..]) |char| if (char < '0' or char > '9') return false;
    return true;
}

fn isHexArrayBase(comptime base: []const u8) bool {
    if (!std.mem.startsWith(u8, base, "[") or !std.mem.endsWith(u8, base, "]u8")) return false;
    const length = base[1 .. base.len - 3];
    if (length.len == 0) return false;
    for (length) |char| if (char < '0' or char > '9') return false;
    return true;
}

fn isNamedType(comptime base: []const u8) bool {
    if (base.len == 0) return false;
    for (base) |char| {
        if (!std.ascii.isAlphanumeric(char) and char != '_') return false;
    }
    return true;
}

fn writeAliasBase(w: *std.Io.Writer, comptime base: []const u8) !void {
    if (comptime std.mem.eql(u8, base, "bool")) return w.writeAll("boolean");
    if (comptime isNumericBase(base)) return w.writeAll("number");
    if (comptime (std.mem.eql(u8, base, "string") or
        std.mem.eql(u8, base, "[]const u8") or isHexArrayBase(base)))
    {
        return w.writeAll("string");
    }

    if (comptime !isNamedType(base)) {
        @compileError("unsupported wire alias base " ++ base);
    }
    try w.writeAll(base);
}

fn writeEnums(w: *std.Io.Writer) !void {
    inline for (registry.enum_order) |ordered| {
        try w.print("export type {s} = ", .{ordered.entry.name});
        inline for (@typeInfo(ordered.entry.ty).@"enum".fields, 0..) |field, index| {
            if (index != 0) try w.writeAll(" | ");
            if (ordered.numeric) {
                try w.print("{d}", .{field.value});
            } else {
                try w.print("\"{s}\"", .{field.name});
            }
        }
        try w.writeAll(";\n\n");
    }
}

fn writeAliases(w: *std.Io.Writer) !void {
    inline for (registry.aliases) |entry| {
        try w.print("export type {s} = ", .{entry.name});
        try writeAliasBase(w, entry.base);
        try w.writeAll(";\n\n");
    }
}

pub fn emit(w: *std.Io.Writer) !void {
    try w.writeAll("// GENERATED by tools/wiregen (zig build gen-schema). Do not edit.\n");
    try w.writeAll("declare namespace Wire {\n\n");
    inline for (registry.structs) |entry| try writeStruct(w, entry);
    try writeEnums(w);
    inline for (registry.tagged_unions) |entry| try writeTaggedUnion(w, entry);
    inline for (registry.envelope_unions) |entry| try writeEnvelopeUnion(w, entry);
    try writeAliases(w);
    try w.writeAll("}\n");
}

pub fn main(init: std.process.Init) !void {
    var stdout_buffer: [4096]u8 = undefined;
    var stdout = std.Io.File.stdout().writer(init.io, &stdout_buffer);
    try emit(&stdout.interface);
    try stdout.interface.flush();
}
