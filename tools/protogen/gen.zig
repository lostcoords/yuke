//! Generate the wire protocol meta-model from the Zig wire declarations.

const std = @import("std");

const proto = @import("proto");
const doc_extractor = @import("docs.zig");
const registry = proto.registry;
const initialize = proto.initialize;
const meta = proto.meta;
const rpc = proto.rpc;

const TypeEntry = registry.TypeEntry;

/// A field with one of these names holds that identifier in every wire type, so the schema names the alias the Zig type erases.
const field_aliases = std.StaticStringMap([]const u8).initComptime(.{
    .{ "provider_id", "ProviderId" },
    .{ "login_id", "LoginId" },
    .{ "revision", "SessionRevision" },
    .{ "session_id", "SessionId" },
    .{ "catalog_rev", "CatalogRev" },
    .{ "seq", "Seq" },
    .{ "run_id", "RunId" },
    .{ "config_rev", "ConfigRev" },
    .{ "first_removed_id", "MessageId" },
    .{ "message_id", "MessageId" },
    .{ "part_id", "PartId" },
    .{ "input_id", "InputId" },
    .{ "since_rev", "CatalogRev" },
    .{ "session_revision", "SessionRevision" },
    .{ "content_hash", "InstructionHash" },
    .{ "canceled_input", "InputId" },
    .{ "canceled_run", "RunId" },
    .{ "cleared_inputs", "InputId" },
    .{ "cleared_compaction", "RunId" },
    .{ "before_message_id", "MessageId" },
    .{ "source_id", "SessionId" },
    .{ "pending_compaction", "RunId" },
    .{ "parent_id", "SessionId" },
    .{ "hash", "BlobHash" },
    .{ "input_ids", "InputId" },
    .{ "first_kept_id", "MessageId" },
    .{ "message.part_delta", "MessagePartDeltaData" },
    .{ "tool.output_delta", "ToolOutputDeltaData" },
    .{ "message_part_delta_data", "MessagePartDeltaData" },
    .{ "tool_output_delta_data", "ToolOutputDeltaData" },
});

/// A field named `id` holds the identifier of its owner.
const id_aliases = std.StaticStringMap([]const u8).initComptime(.{
    .{ "Job", "JobId" },
    .{ "JobStopParams", "JobId" },
    .{ "JobReadParams", "JobId" },
    .{ "ModelInfo", "ModelId" },
    .{ "Request", "RequestId" },
    .{ "ResponseOk", "RequestId" },
    .{ "ResponseError", "RequestId" },
    .{ "Session", "SessionId" },
    .{ "TextPart", "PartId" },
    .{ "ReasoningPart", "PartId" },
    .{ "RedactedReasoningPart", "PartId" },
    .{ "ToolPart", "PartId" },
    .{ "UserMessage", "MessageId" },
    .{ "AssistantMessage", "MessageId" },
    .{ "CompactionMessage", "MessageId" },
});

comptime {
    @setEvalBranchQuota(100000);
    for (field_aliases.values() ++ id_aliases.values()) |alias| {
        for (registry.aliases) |entry| {
            if (std.mem.eql(u8, entry.name, alias)) break;
        } else @compileError("unknown alias: " ++ alias);
    }
    for (id_aliases.keys()) |owner| {
        for (registry.structs) |entry| {
            if (std.mem.eql(u8, entry.name, owner) and @hasField(entry.ty, "id")) break;
        } else @compileError("no id field in: " ++ owner);
    }
}

fn shortName(comptime name: []const u8) []const u8 {
    const index = comptime std.mem.lastIndexOfScalar(u8, name, '.');
    return if (index) |i| name[i + 1 ..] else name;
}

fn aliasFor(comptime owner: []const u8, comptime field: []const u8) ?[]const u8 {
    if (std.mem.eql(u8, field, "id")) return id_aliases.get(owner);
    return field_aliases.get(field);
}

fn writeTypeText(w: *std.Io.Writer, comptime owner: []const u8, comptime field: []const u8, comptime T: type) !void {
    if (comptime aliasFor(owner, field)) |alias| {
        switch (@typeInfo(T)) {
            // Optionality is carried by "presence"; the type is the underlying type.
            .optional => try w.writeAll(alias),
            .pointer => {
                if (T == []const u8) return w.writeAll(alias);
                try w.writeAll("[]");
                try w.writeAll(alias);
            },
            else => try w.writeAll(alias),
        }
        return;
    }
    switch (@typeInfo(T)) {
        // Optionality is carried by "presence"; emit only the underlying type.
        .optional => |optional| try writeTypeText(w, owner, field, optional.child),
        .pointer => |pointer| {
            if (pointer.child == u8) {
                try w.writeAll("string");
            } else {
                try w.writeAll("[]");
                try writeTypeText(w, owner, field, pointer.child);
            }
        },
        .array => |array| {
            try w.print("[{d}]", .{array.len});
            try writeTypeText(w, owner, field, array.child);
        },
        .int, .bool, .float => try w.writeAll(@typeName(T)),
        .@"struct", .@"enum", .@"union" => try w.writeAll(shortName(@typeName(T))),
        else => @compileError("unsupported wire type " ++ @typeName(T)),
    }
}

fn typeText(a: std.mem.Allocator, comptime owner: []const u8, comptime field: []const u8, comptime T: type) ![]const u8 {
    var text: std.Io.Writer.Allocating = .init(a);
    try writeTypeText(&text.writer, owner, field, T);
    return text.written();
}

fn fieldDoc(a: std.mem.Allocator, docs: *const std.StringHashMap([]const u8), owner: []const u8, field: []const u8) !?[]const u8 {
    const key = try std.fmt.allocPrint(a, "{s}.{s}", .{ owner, field });
    return docs.get(key);
}

fn writeStruct(a: std.mem.Allocator, jw: *std.json.Stringify, docs: *const std.StringHashMap([]const u8), entry: TypeEntry) !void {
    try jw.beginObject();
    try writeNameDoc(jw, docs, entry.name);
    try jw.objectField("fields");
    try jw.beginArray();
    inline for (@typeInfo(entry.ty).@"struct".fields) |field| {
        try jw.beginObject();
        try jw.objectField("name");
        try jw.write(field.name);
        if (try fieldDoc(a, docs, entry.name, field.name)) |doc| {
            try jw.objectField("doc");
            try jw.write(doc);
        }
        try jw.objectField("type");
        try jw.write(try typeText(a, entry.name, field.name, field.type));
        try jw.objectField("presence");
        try jw.write(if (@typeInfo(field.type) == .optional) "optional" else if (field.defaultValue() != null) "defaulted" else "required");
        try jw.endObject();
    }
    try jw.endArray();
    try jw.endObject();
}

fn writeUnion(a: std.mem.Allocator, jw: *std.json.Stringify, docs: *const std.StringHashMap([]const u8), entry: TypeEntry, envelope: bool) !void {
    try jw.beginObject();
    try writeNameDoc(jw, docs, entry.name);
    try jw.objectField("discriminator");
    try jw.write(if (envelope) "" else "type");
    try jw.objectField("arms");
    try jw.beginArray();
    inline for (@typeInfo(entry.ty).@"union".fields) |field| {
        try jw.beginObject();
        if (!envelope) {
            try jw.objectField("tag");
            try jw.write(field.name);
        }
        if (try fieldDoc(a, docs, entry.name, field.name)) |doc| {
            try jw.objectField("doc");
            try jw.write(doc);
        }
        try jw.objectField("type");
        try jw.write(broadcastType("", entry.name, field.name, field.type));
        try jw.endObject();
    }
    try jw.endArray();
    try jw.endObject();
}

fn writeEnum(a: std.mem.Allocator, jw: *std.json.Stringify, docs: *const std.StringHashMap([]const u8), entry: TypeEntry, numeric: bool) !void {
    try jw.beginObject();
    try writeNameDoc(jw, docs, entry.name);
    try jw.objectField("numeric");
    try jw.write(numeric);
    try jw.objectField("values");
    try jw.beginArray();
    inline for (@typeInfo(entry.ty).@"enum".fields) |field| {
        try jw.beginObject();
        try jw.objectField("name");
        try jw.write(field.name);
        try jw.objectField("wire");
        if (numeric) try jw.write(try std.fmt.allocPrint(a, "{d}", .{field.value})) else try jw.write(field.name);
        if (try fieldDoc(a, docs, entry.name, field.name)) |doc| {
            try jw.objectField("doc");
            try jw.write(doc);
        }
        try jw.endObject();
    }
    try jw.endArray();
    try jw.endObject();
}

fn writeNameDoc(jw: *std.json.Stringify, docs: *const std.StringHashMap([]const u8), name: []const u8) !void {
    try jw.objectField("name");
    try jw.write(name);
    if (docs.get(name)) |doc| {
        try jw.objectField("doc");
        try jw.write(doc);
    }
}

fn writeNamespace(jw: *std.json.Stringify, comptime T: type) !void {
    try jw.beginObject();
    inline for (@typeInfo(T).@"struct".decls) |decl| {
        try jw.objectField(decl.name);
        try jw.write(@field(T, decl.name));
    }
    try jw.endObject();
}

fn writeMethods(jw: *std.json.Stringify, docs: *const std.StringHashMap([]const u8)) !void {
    try jw.beginArray();
    inline for (rpc.methods) |spec| {
        try jw.beginObject();
        try jw.objectField("name");
        try jw.write(@tagName(spec.name));
        if (docs.get("MethodName." ++ @tagName(spec.name))) |doc| {
            try jw.objectField("doc");
            try jw.write(doc);
        }
        try jw.objectField("params");
        try jw.write(shortName(@typeName(spec.params)));
        try jw.objectField("result");
        try jw.write(shortName(@typeName(spec.result)));
        try jw.objectField("direction");
        try jw.write("clientToServer");
        try jw.objectField("paramsOptional");
        try jw.write(spec.params_optional);
        try jw.endObject();
    }
    try jw.endArray();
}

fn broadcastType(
    comptime name: []const u8,
    comptime union_name: []const u8,
    comptime field_name: []const u8,
    comptime T: type,
) []const u8 {
    if (aliasFor("Broadcast", name)) |alias| return alias;
    if (aliasFor(union_name, field_name)) |alias| return alias;
    return shortName(@typeName(T));
}

fn writeBroadcasts(jw: *std.json.Stringify, docs: *const std.StringHashMap([]const u8)) !void {
    try jw.beginArray();
    inline for (rpc.broadcasts) |spec| {
        try jw.beginObject();
        try jw.objectField("name");
        try jw.write(@tagName(spec.name));
        if (docs.get("BroadcastName." ++ @tagName(spec.name))) |doc| {
            try jw.objectField("doc");
            try jw.write(doc);
        }
        try jw.objectField("params");
        try jw.write(broadcastType(@tagName(spec.name), "", "", spec.data));
        try jw.objectField("direction");
        try jw.write("serverToClient");
        try jw.endObject();
    }
    try jw.endArray();
}

fn emit(a: std.mem.Allocator, io: std.Io, w: *std.Io.Writer) !void {
    var docs = try doc_extractor.load(a, io);
    defer docs.deinit();
    var jw: std.json.Stringify = .{ .writer = w, .options = .{ .whitespace = .indent_2 } };
    try jw.beginObject();
    try jw.objectField("protocolVersion");
    try jw.write(initialize.protocol_version);
    try jw.objectField("limits");
    try writeNamespace(&jw, meta.limits);
    try jw.objectField("constants");
    try writeNamespace(&jw, meta.constants);
    try jw.objectField("methods");
    try writeMethods(&jw, &docs);
    try jw.objectField("broadcasts");
    try writeBroadcasts(&jw, &docs);
    try jw.objectField("structures");
    try jw.beginArray();
    inline for (registry.structs) |entry| try writeStruct(a, &jw, &docs, entry);
    try jw.endArray();
    try jw.objectField("unions");
    try jw.beginArray();
    inline for (registry.tagged_unions) |entry| try writeUnion(a, &jw, &docs, entry, false);
    inline for (registry.envelope_unions) |entry| try writeUnion(a, &jw, &docs, entry, true);
    try jw.endArray();
    try jw.objectField("enumerations");
    try jw.beginArray();
    inline for (registry.string_enums) |entry| try writeEnum(a, &jw, &docs, entry, false);
    inline for (registry.numeric_enums) |entry| try writeEnum(a, &jw, &docs, entry, true);
    try jw.endArray();
    try jw.objectField("aliases");
    try jw.beginArray();
    inline for (registry.aliases) |entry| {
        try jw.beginObject();
        try jw.objectField("name");
        try jw.write(entry.name);
        try jw.objectField("base");
        try jw.write(entry.base);
        if (docs.get(entry.name)) |doc| {
            try jw.objectField("doc");
            try jw.write(doc);
        }
        try jw.endObject();
    }
    try jw.endArray();
    try jw.endObject();
}

pub fn main(init: std.process.Init) !void {
    var stdout_buffer: [4096]u8 = undefined;
    var stdout = std.Io.File.stdout().writer(init.io, &stdout_buffer);
    try emit(init.arena.allocator(), init.io, &stdout.interface);
    try stdout.interface.flush();
}

test "field and broadcast aliases survive type erasure" {
    const testing = std.testing;
    var out: std.Io.Writer.Allocating = .init(testing.allocator);
    defer out.deinit();
    try writeTypeText(&out.writer, "SessionCancelRunParams", "run_id", ?proto.ids.RunId);
    try testing.expectEqualStrings("RunId", out.written());
    out.clearRetainingCapacity();
    try writeTypeText(&out.writer, "SessionCancelRunResult", "cleared_inputs", []const proto.ids.InputId);
    try testing.expectEqualStrings("[]InputId", out.written());
    try testing.expectEqualStrings("MessagePartDeltaData", broadcastType("message.part_delta", "", "", proto.message.PartDelta));
    try testing.expectEqualStrings("ToolOutputDeltaData", broadcastType("tool.output_delta", "", "", proto.message.PartDelta));
}

test {
    _ = doc_extractor;
}
