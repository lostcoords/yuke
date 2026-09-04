//! Test aggregate root for all src layers. proto, sql, and term self-test as lib modules.
//! A referenced import runs a file's tests; a function call alone does not.

test {
    _ = @import("main.zig");
    _ = @import("cli.zig");
    _ = @import("util.zig");
    _ = @import("utf8.zig");
    _ = @import("engine/run.zig");
    _ = @import("engine/commands.zig");
    _ = @import("engine/Engine.zig");
    _ = @import("app/commands.zig");
    _ = @import("app/call.zig");
    _ = @import("engine/sink.zig");
    _ = @import("app/rpc.zig");
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
    _ = @import("provider/retry.zig");
    _ = @import("js/host/operations.zig");
    _ = @import("js/host/local.zig");
    _ = @import("app/app.zig");
    _ = @import("engine/context.zig");
}
