//! Test aggregate root for all src layers. wire, sql, and websocket self-test as packages.
//! A referenced import runs a file's tests; a function call alone does not.

test {
    _ = @import("id.zig");
    _ = @import("domain/domain.zig");
    _ = @import("provider/provider.zig");
    _ = @import("database/database.zig");
    _ = @import("paths/paths.zig");
    _ = @import("daemon/http.zig");
    _ = @import("daemon/rpc.zig");
}
