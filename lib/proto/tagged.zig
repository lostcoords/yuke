//! The shared codec for internally tagged wire unions.

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
    const activity = @import("activity.zig");
    const hook = @import("hook.zig");
    const input = @import("input.zig");
    const interaction = @import("interaction.zig");
    const message = @import("message.zig");
    const run = @import("run.zig");
    const session = @import("session.zig");
    const tool = @import("tool.zig");
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

test "tagged unions preserve their tags and fields" {
    const activity = @import("activity.zig");
    const hook = @import("hook.zig");
    const input = @import("input.zig");
    const interaction = @import("interaction.zig");
    const message = @import("message.zig");
    const run = @import("run.zig");
    const session = @import("session.zig");
    const tool = @import("tool.zig");

    const running_tool = try std.json.parseFromSlice(activity.ActivityState, std.testing.allocator, "{\"type\":\"running_tool\",\"run_id\":7,\"message_id\":8,\"part_id\":9,\"tool_name\":\"search\",\"started_at_ms\":100}", .{});
    defer running_tool.deinit();
    try std.testing.expect(running_tool.value == .running_tool);
    try std.testing.expectEqualStrings("search", running_tool.value.running_tool.tool_name);

    const waiting = try std.json.parseFromSlice(activity.ActivityState, std.testing.allocator, "{\"type\":\"waiting\",\"run_id\":7,\"started_at_ms\":100}", .{});
    defer waiting.deinit();
    try std.testing.expect(waiting.value == .waiting);
    try std.testing.expectEqual(@as(u64, 100), waiting.value.waiting.started_at_ms);

    const assistant = try std.json.parseFromSlice(message.AssistantPart, std.testing.allocator, "{\"type\":\"text\",\"id\":7,\"text\":\"hello\"}", .{});
    defer assistant.deinit();
    try std.testing.expect(assistant.value == .text);
    try std.testing.expectEqual(@as(u64, 7), assistant.value.text.id);
    try std.testing.expectEqualStrings("hello", assistant.value.text.text);

    const reasoning = try std.json.parseFromSlice(message.PartFinal, std.testing.allocator, "{\"type\":\"reasoning\",\"signature\":\"sig\"}", .{});
    defer reasoning.deinit();
    try std.testing.expect(reasoning.value == .reasoning);
    try std.testing.expectEqualStrings("sig", reasoning.value.reasoning.signature);

    const redacted = try std.json.parseFromSlice(message.PartFinal, std.testing.allocator, "{\"type\":\"redacted_reasoning\",\"data\":\"opaque\"}", .{});
    defer redacted.deinit();
    try std.testing.expect(redacted.value == .redacted_reasoning);
    try std.testing.expectEqualStrings("opaque", redacted.value.redacted_reasoning.data);

    const content = try std.json.parseFromSlice(input.Input, std.testing.allocator, "{\"type\":\"content\",\"content\":[{\"type\":\"text\",\"text\":\"hello\"}]}", .{});
    defer content.deinit();
    try std.testing.expect(content.value == .content);
    try std.testing.expect(content.value.content.content[0] == .text);
    try std.testing.expectEqualStrings("hello", content.value.content.content[0].text.text);

    const failed = try std.json.parseFromSlice(run.RunOutcome, std.testing.allocator, "{\"type\":\"failed\",\"code\":\"timeout\",\"message\":\"provider timed out\"}", .{});
    defer failed.deinit();
    try std.testing.expect(failed.value == .failed);
    try std.testing.expectEqual(@import("enums.zig").RunErrorCode.timeout, failed.value.failed.code);

    const running = try std.json.parseFromSlice(tool.ToolState, std.testing.allocator, "{\"type\":\"running\",\"started_at_ms\":100,\"output\":\"partial\"}", .{});
    defer running.deinit();
    try std.testing.expect(running.value == .running);
    try std.testing.expectEqualStrings("partial", running.value.running.output.?);

    const blocked = try std.json.parseFromSlice(hook.Decision, std.testing.allocator, "{\"type\":\"block\",\"reason\":\"denied\"}", .{});
    defer blocked.deinit();
    try std.testing.expect(blocked.value == .block);
    try std.testing.expectEqualStrings("denied", blocked.value.block.reason);

    const proceed = try std.json.parseFromSlice(hook.Decision, std.testing.allocator, "{\"type\":\"proceed\"}", .{});
    defer proceed.deinit();
    try std.testing.expect(proceed.value == .proceed);

    const replace = try std.json.parseFromSlice(hook.Decision, std.testing.allocator, "{\"type\":\"replace\",\"value\":{\"name\":\"bash\",\"arguments\":\"{}\"}}", .{});
    defer replace.deinit();
    try std.testing.expect(replace.value == .replace);
    try std.testing.expectEqualStrings("bash", replace.value.replace.value.object.get("name").?.string);

    const request = try std.json.parseFromSlice(interaction.InteractionRequestedData, std.testing.allocator, "{\"interaction_id\":7,\"request\":{\"type\":\"select\",\"title\":\"pick\",\"options\":[\"a\",\"b\"]}}", .{});
    defer request.deinit();
    try std.testing.expectEqual(@as(u64, 7), request.value.interaction_id);
    try std.testing.expect(request.value.request == .select);
    try std.testing.expectEqualStrings("b", request.value.request.select.options[1]);

    const response = try std.json.parseFromSlice(interaction.InteractionRespondParams, std.testing.allocator, "{\"interaction_id\":7,\"response\":{\"type\":\"select\",\"value\":\"b\"}}", .{});
    defer response.deinit();
    try std.testing.expectEqual(@as(u64, 7), response.value.interaction_id);
    try std.testing.expect(response.value.response == .select);
    try std.testing.expectEqualStrings("b", response.value.response.select.value);

    const population = try std.json.parseFromSlice(session.SessionPopulation, std.testing.allocator, "{\"type\":\"children\",\"parent_id\":\"abababababababababababababababab\"}", .{});
    defer population.deinit();
    try std.testing.expect(population.value == .children);
    try std.testing.expectEqual([_]u8{0xab} ** 16, population.value.children.parent_id.raw);
}
