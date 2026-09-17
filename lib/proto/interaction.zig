//! User interaction questions and correlated answers.

const std = @import("std");
const ids = @import("ids.zig");
const misc = @import("misc.zig");
const tagged = @import("tagged.zig");

/// This payload asks the connected frontend to put one question to the user.
pub const InteractionRequestedData = struct {
    interaction_id: ids.InteractionId,
    request: InteractionRequest,
    session_id: ?ids.SessionId = null,
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
    secret: ?bool = null,
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

test "an answer rejects an unknown arm" {
    try testing.expectError(error.InvalidEnumTag, std.json.parseFromSlice(InteractionRespondParams, testing.allocator,
        \\{"interaction_id":7,"response":{"type":"maybe"}}
    , .{}));
}
