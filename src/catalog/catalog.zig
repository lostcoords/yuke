//! The open provider catalog. It is anonymous and cacheable, and it holds no credential.

pub const feed = @import("feed.zig");
pub const store = @import("store.zig");
pub const fetch = @import("fetch.zig");

test {
    _ = feed;
    _ = store;
    _ = fetch;
}
