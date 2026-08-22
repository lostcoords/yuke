//! Test aggregate root for the daemon layers. wire and sql self-test as packages.

test {
    _ = @import("domain/domain.zig");
    _ = @import("provider/provider.zig");
    _ = @import("database/database.zig");
}
