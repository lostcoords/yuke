//! The yuke-cloud control-plane client. It owns device-code enrollment and the durable identity.

pub const bundle = @import("bundle.zig");
pub const endpoint = @import("endpoint.zig");
pub const identity = @import("identity.zig");
pub const login = @import("login.zig");
pub const protocol = @import("protocol.zig");
pub const fetch = @import("fetch.zig");

test {
    _ = bundle;
    _ = endpoint;
    _ = identity;
    _ = login;
    _ = protocol;
    _ = fetch;
}
