//! Parameters for the sessions whose updates a connection receives.

const std = @import("std");
const ids = @import("ids.zig");

/// This field lists the sessions whose live updates this connection requests.
pub const SubscriptionSetParams = struct {
    sessions: []const ids.SessionId,
};

const testing = std.testing;
