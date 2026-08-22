//! Wire identifiers and revisions.

const std = @import("std");

/// Fixed-width session identifier.
pub const SessionId = [16]u8;
/// Fixed-width workspace identifier.
pub const WorkspaceId = [16]u8;
/// Fixed-width cron job identifier.
pub const JobId = [16]u8;
/// Fixed-width permission rule identifier.
pub const RuleId = [16]u8;
/// Fixed-width login identifier.
pub const LoginId = [32]u8;
/// Fixed-width catalog revision identifier.
pub const CatalogRev = [64]u8;

// Numeric ids remain within the 2^53 limit where they cross to JavaScript.
/// Numeric message identifier.
pub const MessageId = u64;
/// Numeric run identifier.
pub const RunId = u64;
/// Numeric input identifier.
pub const InputId = u64;
/// Numeric message-part identifier.
pub const PartId = u64;
/// Numeric event sequence.
pub const Seq = u64;
/// Numeric session revision.
pub const SessionRevision = u64;
/// Numeric cron revision.
pub const CronRevision = u64;
/// Numeric run-configuration revision.
pub const ConfigRev = u64;

// Opaque string identifiers are plain slices.
/// Opaque provider identifier.
pub const ProviderId = []const u8;
/// Opaque model identifier.
pub const ModelId = []const u8;
/// Opaque request identifier.
pub const RequestId = []const u8;

/// True when every byte is a lowercase hex digit. The path-safety check for the `[N]u8` ids.
pub fn isLowerHex(bytes: []const u8) bool {
    for (bytes) |c| switch (c) {
        '0'...'9', 'a'...'f' => {},
        else => return false,
    };
    return true;
}

test isLowerHex {
    try std.testing.expect(isLowerHex("0123456789abcdef"));
    try std.testing.expect(!isLowerHex("0123456789ABCDEF")); // uppercase rejected
    try std.testing.expect(!isLowerHex("../etc/passwd_xx")); // path chars rejected
}
