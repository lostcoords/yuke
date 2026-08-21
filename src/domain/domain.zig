//! Shared session-projection domain: the one fold both the daemon and the client run, so the
//! streaming-state logic that Odin duplicated across daemon and client lives here exactly once.

pub const draft = @import("draft.zig");
pub const queue = @import("queue.zig");

test {
    @import("std").testing.refAllDecls(@This());
}
