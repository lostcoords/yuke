//! Test root for the QuickJS host. It sits at `src/` so the host can import `session/`.

test {
    _ = @import("js/agents_test.zig");
    _ = @import("js/host.zig");
    _ = @import("js/extensions.zig");
    _ = @import("app/rpc.zig");
    _ = @import("app/rpc_js_test.zig");
    _ = @import("app/print_cli.zig");
}
