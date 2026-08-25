//! The daemon and client share one session projection fold.
//! This module keeps the state logic in one place.

pub const draft = @import("draft.zig");
pub const queue = @import("queue.zig");
pub const session = @import("session.zig");

test {
    @import("std").testing.refAllDecls(@This());
}
