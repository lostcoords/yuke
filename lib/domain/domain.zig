//! The daemon and client share one session projection fold.
//! This module keeps the state logic in one place.

pub const draft = @import("draft.zig");
pub const queue = @import("queue.zig");
pub const committed = @import("committed.zig");
pub const session = @import("session.zig");
pub const conformance = @import("conformance.zig");

test {
    @import("std").testing.refAllDecls(@This());
}
