//! The yuke-cloud control-plane client. It owns device-code enrollment and the durable identity.

pub const bundle = @import("bundle.zig");
pub const endpoint = @import("endpoint.zig");
pub const catalog = @import("catalog.zig");
pub const http = @import("http.zig");
pub const identity = @import("identity.zig");
pub const login = @import("login.zig");
pub const poller = @import("poller.zig");
pub const protocol = @import("protocol.zig");
pub const sync = @import("sync.zig");

test {
    _ = bundle;
    _ = endpoint;
    _ = catalog;
    _ = http;
    _ = identity;
    _ = login;
    _ = poller;
    _ = protocol;
    _ = sync;
}
