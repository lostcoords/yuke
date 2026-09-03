//! User interaction questions and correlated answers.

const std = @import("std");
const ids = @import("ids.zig");
const misc = @import("misc.zig");
const tagged = @import("tagged.zig");

/// This payload asks the connected frontend to put one question to the user.
pub const InteractionRequestedData = struct {
    interaction_id: ids.InteractionId,
    request: InteractionRequest,
};

/// This union carries one frontend-neutral question.
pub const InteractionRequest = union(enum) {
    confirm: InteractionConfirm,
    select: InteractionSelect,
    input: InteractionInput,

    pub fn jsonParse(a: std.mem.Allocator, s: anytype, o: std.json.ParseOptions) !@This() {
        return tagged.jsonParse(@This(), a, s, o);
    }
    pub fn jsonParseFromValue(a: std.mem.Allocator, v: std.json.Value, o: std.json.ParseOptions) !@This() {
        return tagged.fromValue(@This(), a, v, o);
    }
    pub fn jsonStringify(self: @This(), jw: *std.json.Stringify) !void {
        return tagged.stringify(@This(), self, jw);
    }
};

pub const InteractionConfirm = struct {
    title: []const u8,
    message: []const u8,
};

pub const InteractionSelect = struct {
    title: []const u8,
    options: []const []const u8,
};

pub const InteractionInput = struct {
    title: []const u8,
    placeholder: ?[]const u8 = null,
};

/// These parameters answer one pending question.
pub const InteractionRespondParams = struct {
    interaction_id: ids.InteractionId,
    response: InteractionResponse,
};

/// This union answers a question. Its arm matches the question, or the user canceled.
pub const InteractionResponse = union(enum) {
    confirm: InteractionConfirmed,
    select: InteractionValue,
    input: InteractionValue,
    canceled: misc.Empty,

    pub fn jsonParse(a: std.mem.Allocator, s: anytype, o: std.json.ParseOptions) !@This() {
        return tagged.jsonParse(@This(), a, s, o);
    }
    pub fn jsonParseFromValue(a: std.mem.Allocator, v: std.json.Value, o: std.json.ParseOptions) !@This() {
        return tagged.fromValue(@This(), a, v, o);
    }
    pub fn jsonStringify(self: @This(), jw: *std.json.Stringify) !void {
        return tagged.stringify(@This(), self, jw);
    }
};

pub const InteractionConfirmed = struct {
    value: bool,
};

pub const InteractionValue = struct {
    value: []const u8,
};

const testing = std.testing;

test "a question and its answer use tagged wire shapes" {
    const request_json =
        \\{"interaction_id":7,"request":{"type":"select","title":"pick","options":["a","b"]}}
    ;
    const request = try std.json.parseFromSlice(InteractionRequestedData, testing.allocator, request_json, .{});
    defer request.deinit();
    try testing.expect(request.value.request == .select);
    try testing.expectEqualStrings("b", request.value.request.select.options[1]);

    const response_json =
        \\{"interaction_id":7,"response":{"type":"select","value":"b"}}
    ;
    const response = try std.json.parseFromSlice(InteractionRespondParams, testing.allocator, response_json, .{});
    defer response.deinit();
    try testing.expect(response.value.response == .select);
    try testing.expectEqualStrings("b", response.value.response.select.value);
}

test "an answer rejects an unknown arm" {
    try testing.expectError(error.InvalidEnumTag, std.json.parseFromSlice(InteractionRespondParams, testing.allocator,
        \\{"interaction_id":7,"response":{"type":"maybe"}}
    , .{}));
}
