//! Test root for the process and its JavaScript host.

test {
    _ = @import("allocations.zig");
    _ = @import("js/bench.zig");
    _ = @import("js/layout_test.zig");
    _ = @import("js/widget_test.zig");
    _ = @import("js/presentation_test.zig");
    _ = @import("js/md_preview_test.zig");
    _ = @import("js/stream_test.zig");
    _ = @import("js/preview_test.zig");
    _ = @import("js/agents_test.zig");
    _ = @import("js/host.zig");
    _ = @import("js/extensions.zig");
    _ = @import("app/rpc.zig");
    _ = @import("app/rpc_js_test.zig");
    _ = @import("app/print_cli.zig");
    _ = @import("main.zig");
    _ = @import("cli.zig");
    _ = @import("util.zig");
    _ = @import("utf8.zig");
    _ = @import("engine/run.zig");
    _ = @import("engine/turn.zig");
    _ = @import("engine/commands.zig");
    _ = @import("engine/Engine.zig");
    _ = @import("app/commands.zig");
    _ = @import("app/auth_cli.zig");
    _ = @import("app/call.zig");
    _ = @import("engine/sink.zig");
    _ = @import("session/session.zig");
    _ = @import("session/draft.zig");
    _ = @import("session/transcript.zig");
    _ = @import("diff/diff.zig");
    _ = @import("provider/provider.zig");
    _ = @import("store/store.zig");
    _ = @import("paths.zig");
    _ = @import("net/http.zig");
    _ = @import("provider/oauth/oauth.zig");
    _ = @import("provider/oauth/credential_lock.zig");
    _ = @import("provider/oauth/xai.zig");
    _ = @import("provider/oauth/codex.zig");
    _ = @import("js/host/operations.zig");
    _ = @import("js/host/local.zig");
    _ = @import("app/app.zig");
    _ = @import("engine/context.zig");
}
