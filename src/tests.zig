//! Test aggregate root for all src layers. wire, sql, and websocket self-test as lib modules.
//! A referenced import runs a file's tests; a function call alone does not.

test {
    _ = @import("main.zig");
    _ = @import("cli.zig");
    _ = @import("util.zig");
    _ = @import("engine/run.zig");
    _ = @import("provider/provider.zig");
    _ = @import("database/database.zig");
    _ = @import("paths/paths.zig");
    _ = @import("cloud/cloud.zig");
    _ = @import("catalog/catalog.zig");
    _ = @import("net/http.zig");
    _ = @import("net/poller.zig");
    _ = @import("provider/oauth/oauth.zig");
    _ = @import("provider/oauth/xai.zig");
    _ = @import("provider/oauth/codex.zig");
    _ = @import("provider/retry.zig");
    _ = @import("tools/tool.zig");
    _ = @import("tools/read.zig");
    _ = @import("tools/registry.zig");
    _ = @import("host/host.zig");
    _ = @import("host/local.zig");
    _ = @import("daemon/http.zig");
    _ = @import("daemon/rpc.zig");
    _ = @import("daemon/session_runtime.zig");
    _ = @import("daemon/connection.zig");
    _ = @import("daemon/config.zig");
    _ = @import("daemon/InstanceLock.zig");
    _ = @import("daemon/shutdown.zig");
    _ = @import("daemon/login_runtime.zig");
    _ = @import("daemon/app.zig");
    _ = @import("daemon/turn_context.zig");
}
