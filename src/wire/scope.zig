//! Scope filters for `session.list`.

const std = @import("std");
const tagged = @import("tagged.zig");
const ids = @import("ids.zig");

/// Workspace scope searched by `session.list`.
pub const SessionScope = union(enum) {
    all: SessionScopeAll,
    workspace: SessionScopeWorkspace,

    /// Decode a tagged wire union from JSON.
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

/// All workspaces (no payload).
pub const SessionScopeAll = struct {};

/// One workspace.
pub const SessionScopeWorkspace = struct {
    workspace_id: ids.WorkspaceId,
};

const testing = std.testing;
const opts: std.json.ParseOptions = .{ .ignore_unknown_fields = true };

test "decode payload-free arm" {
    const parsed = try std.json.parseFromSlice(SessionScope, testing.allocator,
        \\{"type":"all"}
    , opts);
    defer parsed.deinit();
    try testing.expect(parsed.value == .all);
}

test "decode arm with a fixed-hex id" {
    const parsed = try std.json.parseFromSlice(SessionScope, testing.allocator,
        \\{"type":"workspace","workspace_id":"0123456789abcdef"}
    , opts);
    defer parsed.deinit();
    try testing.expect(parsed.value == .workspace);
    try testing.expectEqualStrings("0123456789abcdef", &parsed.value.workspace.workspace_id);
}

test "wrong-length id rejected by std.json" {
    try testing.expectError(error.LengthMismatch, std.json.parseFromSlice(SessionScope, testing.allocator,
        \\{"type":"workspace","workspace_id":"tooshort"}
    , opts));
}

test "unknown discriminator rejected" {
    try testing.expectError(error.InvalidEnumTag, std.json.parseFromSlice(SessionScope, testing.allocator,
        \\{"type":"galaxy"}
    , opts));
}

test "missing discriminator rejected" {
    try testing.expectError(error.MissingField, std.json.parseFromSlice(SessionScope, testing.allocator,
        \\{"workspace_id":"0123456789abcdef"}
    , opts));
}

test "round-trip re-encodes to flat internally-tagged JSON" {
    const s: SessionScope = .{ .workspace = .{ .workspace_id = "0123456789abcdef".* } };

    var buf: std.Io.Writer.Allocating = .init(testing.allocator);
    defer buf.deinit();
    try std.json.Stringify.value(s, .{}, &buf.writer);
    try testing.expectEqualStrings(
        \\{"type":"workspace","workspace_id":"0123456789abcdef"}
    , buf.written());
}

test "payload-free arm round-trips to just the discriminator" {
    const s: SessionScope = .all;

    var buf: std.Io.Writer.Allocating = .init(testing.allocator);
    defer buf.deinit();
    try std.json.Stringify.value(s, .{}, &buf.writer);
    try testing.expectEqualStrings(
        \\{"type":"all"}
    , buf.written());
}
