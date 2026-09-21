//! Validate native hosted search records and preserve their provider payload for replay.

const std = @import("std");
const json = @import("stream/json.zig");
const limits = @import("types.zig").limits;
const max_results = 10_000;

pub const Protocol = enum { anthropic, openai_responses };

pub const Record = struct {
    protocol: Protocol,
    data: []const u8,

    pub fn clone(self: Record, arena: std.mem.Allocator) !Record {
        std.debug.assert(self.data.len != 0 and self.data.len <= limits.max_string_bytes);
        return .{ .protocol = self.protocol, .data = try arena.dupe(u8, self.data) };
    }

    pub fn validate(self: Record, arena: std.mem.Allocator) !void {
        if (self.data.len == 0 or self.data.len > limits.max_string_bytes) return error.InvalidRequest;
        const value = json.parse(self.data, arena) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            error.Protocol => return error.InvalidRequest,
        };
        validateValue(self.protocol, value) catch return error.InvalidRequest;
    }
};

pub fn anthropicName(name: []const u8) bool {
    return std.mem.eql(u8, name, "tool_search_tool_regex") or std.mem.eql(u8, name, "tool_search_tool_bm25");
}

/// Unknown fields survive replay; the supported record kinds and required fields stay closed.
pub fn validateValue(protocol: Protocol, value: std.json.Value) error{Protocol}!void {
    if (value != .object) return error.Protocol;
    const kind = json.fieldStr(value, "type") orelse return error.Protocol;
    switch (protocol) {
        .anthropic => {
            if (std.mem.eql(u8, kind, "server_tool_use")) {
                _ = try nonempty(value, "id");
                if (!anthropicName(try nonempty(value, "name"))) return error.Protocol;
                const input = json.fieldGet(value, "input") orelse return error.Protocol;
                if (input != .object) return error.Protocol;
            } else if (std.mem.eql(u8, kind, "tool_search_tool_result")) {
                _ = try nonempty(value, "tool_use_id");
                const content = json.fieldGet(value, "content") orelse return error.Protocol;
                const content_type = json.fieldStr(content, "type") orelse return error.Protocol;
                if (std.mem.eql(u8, content_type, "tool_search_tool_search_result")) {
                    const refs = try array(content, "tool_references");
                    if (refs.len > max_results) return error.Protocol;
                    for (refs) |ref| {
                        if (!std.mem.eql(u8, json.fieldStr(ref, "type") orelse return error.Protocol, "tool_reference")) return error.Protocol;
                        _ = try nonempty(ref, "tool_name");
                    }
                } else if (std.mem.eql(u8, content_type, "tool_search_tool_result_error")) {
                    const Code = enum { invalid_tool_input, unavailable, too_many_requests, execution_time_exceeded };
                    _ = std.meta.stringToEnum(Code, try nonempty(content, "error_code")) orelse return error.Protocol;
                    if (json.fieldGet(content, "error_message")) |message| if (message != .string) return error.Protocol;
                } else return error.Protocol;
            } else return error.Protocol;
        },
        .openai_responses => {
            if (!std.mem.eql(u8, json.fieldStr(value, "execution") orelse return error.Protocol, "server")) return error.Protocol;
            _ = try nonempty(value, "id");
            const call_id = json.fieldGet(value, "call_id") orelse return error.Protocol;
            if (call_id != .null and call_id != .string) return error.Protocol;
            const status = json.fieldStr(value, "status") orelse return error.Protocol;
            if (!std.mem.eql(u8, status, "completed") and !std.mem.eql(u8, status, "incomplete")) return error.Protocol;
            if (std.mem.eql(u8, kind, "tool_search_call")) {
                const args = json.fieldGet(value, "arguments") orelse return error.Protocol;
                if (args != .object) return error.Protocol;
            } else if (std.mem.eql(u8, kind, "tool_search_output")) {
                var count: usize = 0;
                try definitions(try array(value, "tools"), false, &count);
            } else return error.Protocol;
        },
    }
}

fn definitions(tools: []const std.json.Value, nested: bool, count: *usize) error{Protocol}!void {
    std.debug.assert(count.* <= max_results);
    if (tools.len > max_results - count.*) return error.Protocol;
    count.* += tools.len;
    for (tools) |tool| {
        _ = try nonempty(tool, "name");
        const kind = json.fieldStr(tool, "type") orelse return error.Protocol;
        if (std.mem.eql(u8, kind, "namespace") and !nested) {
            _ = json.fieldStr(tool, "description") orelse return error.Protocol;
            try definitions(try array(tool, "tools"), true, count);
        } else if (std.mem.eql(u8, kind, "function")) {
            if (json.fieldGet(tool, "parameters")) |parameters| {
                if (parameters != .object and parameters != .null) return error.Protocol;
            } else if (!nested) return error.Protocol;
            if (json.fieldGet(tool, "description")) |description| if (description != .string and description != .null) return error.Protocol;
            if (json.fieldGet(tool, "strict")) |strict| if (strict != .bool and strict != .null) return error.Protocol;
            if (json.fieldGet(tool, "defer_loading")) |deferred| if (deferred != .bool) return error.Protocol;
        } else return error.Protocol;
    }
}

fn array(value: std.json.Value, key: []const u8) error{Protocol}![]const std.json.Value {
    const field = json.fieldGet(value, key) orelse return error.Protocol;
    return if (field == .array) field.array.items else error.Protocol;
}

fn nonempty(value: std.json.Value, key: []const u8) error{Protocol}![]const u8 {
    const text = json.fieldStr(value, key) orelse return error.Protocol;
    if (text.len == 0 or text.len > limits.max_string_bytes) return error.Protocol;
    return text;
}

pub fn encode(gpa: std.mem.Allocator, protocol: Protocol, value: std.json.Value) ![]u8 {
    try validateValue(protocol, value);
    const data = try std.json.Stringify.valueAlloc(gpa, value, .{});
    errdefer gpa.free(data);
    if (data.len > limits.max_string_bytes) return error.Protocol;
    return data;
}

test "hosted search records retain extension fields and reject client calls" {
    const t = std.testing;
    var arena: std.heap.ArenaAllocator = .init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const anthropic =
        \\{"type":"tool_search_tool_result","tool_use_id":"s","content":{"type":"tool_search_tool_search_result","tool_references":[{"type":"tool_reference","tool_name":"mcp_echo"}]},"extension":true}
    ;
    try (Record{ .protocol = .anthropic, .data = anthropic }).validate(a);
    const response =
        \\{"type":"tool_search_output","id":"ts_1","execution":"server","call_id":null,"status":"completed","tools":[{"type":"function","name":"mcp_echo","parameters":{"type":"object"},"defer_loading":true}]}
    ;
    try (Record{ .protocol = .openai_responses, .data = response }).validate(a);
    inline for (.{
        "{}",
        "[]",
        "{\"type\":\"server_tool_use\",\"id\":\"s\",\"name\":\"web_search\",\"input\":{}}",
        "{\"type\":\"tool_search_tool_result\",\"tool_use_id\":\"s\",\"content\":[]}",
    }) |bad| try t.expectError(error.InvalidRequest, (Record{ .protocol = .anthropic, .data = bad }).validate(a));
    const client =
        \\{"type":"tool_search_call","id":"ts_1","execution":"client","call_id":"c","status":"completed","arguments":{}}
    ;
    try t.expectError(error.InvalidRequest, (Record{ .protocol = .openai_responses, .data = client }).validate(a));
}

test "native search accepts documented errors and nullable function metadata" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    try (Record{ .protocol = .anthropic, .data =
        \\{"type":"tool_search_tool_result","tool_use_id":"srv_1","content":{"type":"tool_search_tool_result_error","error_code":"unavailable","error_message":"retry"}}
    }).validate(a);
    try (Record{ .protocol = .openai_responses, .data =
        \\{"id":"ts_1","type":"tool_search_output","execution":"server","call_id":null,"status":"completed","tools":[{"type":"function","name":"empty","parameters":null,"strict":null,"description":null},{"type":"namespace","name":"space","description":"Tools.","tools":[{"type":"function","name":"empty"}]}]}
    }).validate(a);
    try std.testing.expectError(error.InvalidRequest, (Record{ .protocol = .anthropic, .data =
        \\{"type":"tool_search_tool_result","tool_use_id":"srv_1","content":{"type":"tool_search_tool_result_error","error_code":"unknown"}}
    }).validate(a));
    try std.testing.expectError(error.InvalidRequest, (Record{ .protocol = .openai_responses, .data =
        \\{"id":"ts_1","type":"tool_search_output","execution":"server","call_id":null,"status":"completed","tools":[{"type":"function","name":"bad","parameters":{},"defer_loading":"true"}]}
    }).validate(a));
}
