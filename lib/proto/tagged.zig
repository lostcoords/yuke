//! The shared codec for internally tagged wire unions.

const std = @import("std");
const activity = @import("activity.zig");
const hook = @import("hook.zig");
const input = @import("input.zig");
const interaction = @import("interaction.zig");
const message = @import("message.zig");
const run = @import("run.zig");
const session = @import("session.zig");
const tool = @import("tool.zig");

const disc = "type";

/// Provide the JSON codec methods that a tagged union exposes to `std.json`.
pub fn Codec(comptime T: type) type {
    return struct {
        pub fn jsonParse(a: std.mem.Allocator, source: anytype, o: std.json.ParseOptions) !T {
            return parse(T, a, source, o);
        }

        pub fn jsonParseFromValue(a: std.mem.Allocator, v: std.json.Value, o: std.json.ParseOptions) !T {
            return fromValue(T, a, v, o);
        }

        pub fn jsonStringify(self: T, jw: *std.json.Stringify) !void {
            return stringify(T, self, jw);
        }
    };
}

/// Decode a tagged wire union from JSON.
fn parse(comptime T: type, a: std.mem.Allocator, source: anytype, o: std.json.ParseOptions) !T {
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

    // The arm fields share the flat object with the discriminator.
    var arm_opts = o;
    arm_opts.ignore_unknown_fields = true;

    inline for (@typeInfo(T).@"union".fields) |f| {
        if (std.mem.eql(u8, f.name, tag))
            return @unionInit(T, f.name, try std.json.parseFromValueLeaky(f.type, a, v, arm_opts));
    }

    return error.InvalidEnumTag; // Reject an unknown discriminator.
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

test "tagged unions round-trip one representative value each" {
    const cases = .{
        .{ .union_type = activity.ActivityState, .json = "{\"type\":\"running_tool\",\"run_id\":7,\"message_id\":8,\"part_id\":9,\"tool_name\":\"search\",\"started_at_ms\":100}" },
        .{ .union_type = activity.ActivityState, .json = "{\"type\":\"waiting\",\"run_id\":7,\"started_at_ms\":100}" },
        .{ .union_type = message.AssistantPart, .json = "{\"type\":\"text\",\"id\":7,\"text\":\"hello\"}" },
        .{ .union_type = message.PartFinal, .json = "{\"type\":\"reasoning\",\"signature\":\"sig\"}" },
        .{ .union_type = message.PartFinal, .json = "{\"type\":\"redacted_reasoning\",\"data\":\"opaque\"}" },
        .{ .union_type = input.Input, .json = "{\"type\":\"content\",\"content\":[{\"type\":\"text\",\"text\":\"hello\"}]}" },
        .{ .union_type = run.RunOutcome, .json = "{\"type\":\"failed\",\"code\":\"timeout\",\"message\":\"provider timed out\"}" },
        .{ .union_type = tool.ToolState, .json = "{\"type\":\"running\",\"started_at_ms\":100,\"output\":\"partial\"}" },
        .{ .union_type = hook.Decision, .json = "{\"type\":\"block\",\"reason\":\"denied\"}" },
        .{ .union_type = hook.Decision, .json = "{\"type\":\"proceed\"}" },
        .{ .union_type = hook.Decision, .json = "{\"type\":\"replace\",\"value\":{\"name\":\"bash\",\"arguments\":\"{}\"}}" },
        .{ .union_type = interaction.InteractionRequestedData, .json = "{\"interaction_id\":7,\"request\":{\"type\":\"select\",\"title\":\"pick\",\"options\":[\"a\",\"b\"]}}" },
        .{ .union_type = interaction.InteractionRespondParams, .json = "{\"interaction_id\":7,\"response\":{\"type\":\"select\",\"value\":\"b\"}}" },
        .{ .union_type = interaction.InteractionRequest, .json = "{\"type\":\"select\",\"title\":\"pick\",\"options\":[\"a\",\"b\"]}" },
        .{ .union_type = interaction.InteractionResponse, .json = "{\"type\":\"select\",\"value\":\"b\"}" },
        .{ .union_type = session.SessionPopulation, .json = "{\"type\":\"children\",\"parent_id\":\"abababababababababababababababab\"}" },
    };

    inline for (cases) |case| {
        const parsed = try std.json.parseFromSlice(case.union_type, std.testing.allocator, case.json, .{ .ignore_unknown_fields = true });
        defer parsed.deinit();
        var buf: std.Io.Writer.Allocating = .init(std.testing.allocator);
        defer buf.deinit();
        try std.json.Stringify.value(parsed.value, .{ .emit_null_optional_fields = false }, &buf.writer);
        try std.testing.expectEqualStrings(case.json, buf.written());
    }
}
