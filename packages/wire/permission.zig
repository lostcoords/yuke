//! Permission request, decision, and remembered-rule wire types.

const std = @import("std");
const ids = @import("ids.zig");
const enums = @import("enums.zig");
const tagged = @import("tagged.zig");
const initialize = @import("initialize.zig");

/// These are the parameters for `permission.decide`.
pub const PermissionDecideParams = struct {
    session_id: ids.SessionId,
    message_id: ids.MessageId,
    part_id: ids.PartId,
    option_id: []const u8,
    message: ?[]const u8 = null,
};

/// This type records who answered a permission request and how. Its fields borrow their data.
pub const PermissionDecision = union(enum) {
    user: PermissionDecisionUser,
    rule: PermissionDecisionRule,

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

/// A matched persisted rule decided the request.
pub const PermissionDecisionRule = struct {
    rule_id: ids.RuleId,
    label: []const u8,
    resolved_at_ms: u64,
};

/// The user selected an option for the decision.
pub const PermissionDecisionUser = struct {
    option_id: []const u8,
    kind: enums.PermissionOptionKind,
    label: []const u8,
    resolved_at_ms: u64,
    decided_by: initialize.Client,
};

/// These are the parameters for `permission.forget`.
pub const PermissionForgetParams = struct {
    workspace_id: ids.WorkspaceId,
    rule_id: ids.RuleId,
};

/// The daemon proposes this option for a permission request.
pub const PermissionOption = struct {
    id: []const u8,
    kind: enums.PermissionOptionKind,
    label: []const u8,
    creates: ?[]const []const u8 = null,
};

/// This rule stores an `allow always` answer for matching requests in a workspace.
pub const PermissionRule = struct {
    id: ids.RuleId,
    session_id: ?ids.SessionId = null,
    tool: []const u8,
    label: []const u8,
    action: enums.RuleAction,
    created_at_ms: u64,
    created_by: initialize.Client,
};

/// This payload describes `permission.rules_changed`.
pub const PermissionRulesChangedData = struct {
    workspace_id: ids.WorkspaceId,
    rules: []const PermissionRule,
};

/// This result describes `permission.rules`.
pub const PermissionRulesResult = struct {
    rules: []const PermissionRule,
};

/// This local lifecycle data belongs in tool state. The daemon never broadcasts it.
pub const PermissionState = struct {
    requested_at_ms: u64,
    options: ?[]const PermissionOption = null,
    decision: ?PermissionDecision = null,
};

const testing = std.testing;
const opts: std.json.ParseOptions = .{ .ignore_unknown_fields = true };

test "permission decision union round-trips a user decision" {
    const json =
        \\{"type":"user","option_id":"allow","kind":"allow_once","label":"Allow","resolved_at_ms":123,"decided_by":{"name":"yuke-tui","version":"0.0.0"}}
    ;
    const parsed = try std.json.parseFromSlice(PermissionDecision, testing.allocator, json, opts);
    defer parsed.deinit();
    try testing.expect(parsed.value == .user);
    try testing.expectEqualStrings("allow", parsed.value.user.option_id);

    var buf: std.Io.Writer.Allocating = .init(testing.allocator);
    defer buf.deinit();
    try std.json.Stringify.value(parsed.value, .{ .emit_null_optional_fields = false }, &buf.writer);
    try testing.expectEqualStrings(json, buf.written());
}
