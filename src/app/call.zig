//! Call one engine command by name.
//!
//! There is no envelope here: no request id, no response wrapper, and no transport. One process
//! calls a function. `proto.rpc.methods` already names each method's parameter and result type,
//! so this file adds only the binding from a method to its command and the refusal table.

const std = @import("std");
const proto = @import("proto");
const App = @import("app.zig").App;
const commands = @import("../engine/commands.zig");
const app_commands = @import("commands.zig");
const turn = @import("../engine/turn.zig");

/// A command refused the request. This is an operating outcome, not a bug.
pub const Failure = struct {
    code: proto.enums.ErrorCode,
    message: []const u8,
};

/// Decode `params_json`, run the command, and write its result as JSON into `out`.
/// Return null on success. Return a `Failure` when a command refuses. Return an error for a bug.
pub fn call(
    runtime: *App,
    arena: std.mem.Allocator,
    method_name: []const u8,
    params_json: []const u8,
    out: *std.Io.Writer,
) !?Failure {
    const method = std.meta.stringToEnum(proto.enums.MethodName, method_name) orelse
        return Failure{ .code = .unknown_method, .message = "unknown method" };

    // The launch token starts a run after the answer, so `send_input` returns before the turn does.
    var launch: ?turn.Launch = null;
    defer turn.Launch.release(&launch, &runtime.engine);

    inline for (proto.rpc.methods) |spec| {
        if (method == spec.name) {
            if (comptime bound(spec.name)) {
                const params = std.json.parseFromSliceLeaky(spec.params, arena, params_json, .{
                    .ignore_unknown_fields = true,
                }) catch return Failure{ .code = .bad_request, .message = "bad parameters" };

                const result = invoke(spec, runtime, arena, params, &launch) catch |err|
                    return failureFor(err) orelse return err;

                try std.json.Stringify.value(result, .{ .emit_null_optional_fields = false }, out);
                return null;
            }
            return Failure{ .code = .not_implemented, .message = "not implemented" };
        }
    }
    unreachable; // The protocol validates one table entry for every method name.
}

/// Run the one command this method names. A comptime condition drops every other branch.
fn invoke(comptime spec: anytype, runtime: *App, arena: std.mem.Allocator, params: spec.params, launch: *?turn.Launch) !spec.result {
    const n = spec.name;
    const engine = &runtime.engine;
    if (n == .@"agents.set_model") return @import("../engine/agent_config.zig").setModel(engine, arena, params);
    if (n == .@"agents.get") return @import("../engine/agent_config.zig").get(engine, arena);
    if (n == .@"agents.update") return @import("../engine/agent_config.zig").update(engine, arena, params);
    if (n == .@"agents.resolve") return @import("../engine/agent_config.zig").resolve(engine, arena, params);
    if (n == .initialize) return commands.initialize(engine, arena);
    if (n == .@"session.list") return commands.sessionList(engine, arena, params);
    if (n == .@"session.get") return commands.sessionGet(engine, arena, params);
    if (n == .@"session.queue") return commands.sessionQueue(engine, arena, params);
    if (n == .@"session.create") return commands.sessionCreateForRpc(engine, arena, params, launch);
    if (n == .@"session.config") return commands.sessionConfig(engine, arena, params);
    if (n == .@"session.history") return commands.sessionHistory(engine, arena, params);
    if (n == .@"session.send_input") return commands.sessionSendInputForRpc(engine, arena, params, launch);
    if (n == .@"session.cancel_input") return commands.sessionCancelInput(engine, arena, params);
    if (n == .@"session.cancel_run") return commands.sessionCancelRun(engine, arena, params);
    if (n == .@"session.remove") return commands.sessionRemove(engine, arena, params);
    if (n == .@"catalog.list") return app_commands.catalogList(runtime, arena, params);
    if (n == .@"catalog.reload") return app_commands.catalogReload(runtime, arena, params);
    if (n == .@"auth.list") return app_commands.authList(runtime, arena, params);
    if (n == .@"auth.set_api_key") return app_commands.authSetApiKey(runtime, arena, params);
    if (n == .@"auth.remove") return app_commands.authRemove(runtime, arena, params);
    if (n == .@"auth.login") return app_commands.authLogin(runtime, arena, params);
    if (n == .@"auth.cancel_login") return app_commands.authCancelLogin(runtime, arena, params);
    @compileError("`" ++ @tagName(n) ++ "` is bound but has no command");
}

/// The methods this engine serves. A method outside this set answers `not_implemented`.
/// Adding a method to `proto` therefore cannot silently reach a missing command.
fn bound(comptime name: proto.enums.MethodName) bool {
    return switch (name) {
        .@"agents.set_model",
        .@"agents.get",
        .@"agents.update",
        .@"agents.resolve",
        .initialize,
        .@"session.list",
        .@"session.get",
        .@"session.queue",
        .@"session.create",
        .@"session.config",
        .@"session.history",
        .@"session.send_input",
        .@"session.cancel_input",
        .@"session.cancel_run",
        .@"session.remove",
        .@"catalog.list",
        .@"catalog.reload",
        .@"auth.list",
        .@"auth.set_api_key",
        .@"auth.remove",
        .@"auth.login",
        .@"auth.cancel_login",
        => true,
        else => false,
    };
}

/// Map a refusal to its wire code. An error absent from this table is a bug and propagates.
fn failureFor(err: anyerror) ?Failure {
    return switch (err) {
        error.AgentConfigDirectoryMissing => .{ .code = .setup_required, .message = "no profile config directory is available for agents.json" },
        error.BadAgentConfig => .{ .code = .bad_request, .message = "agents.json is invalid; repair the file before setup" },
        error.AgentConfigConflict => .{ .code = .config_conflict, .message = "agents.json changed; resolve the slot or read the current revision before retry" },
        error.AgentConfigReadFailed => .{ .code = .runtime_failed, .message = "cannot read agents.json" },
        error.AgentConfigSaveFailed => .{ .code = .runtime_failed, .message = "cannot save agents.json; the previous live config remains active" },
        error.AgentSetupRequired => .{ .code = .setup_required, .message = "the requested subagent model slot needs setup" },
        error.AgentUnknownModel => .{ .code = .unsupported_model, .message = "the subagent slot names an unknown model selector" },
        error.AgentProviderUnavailable => .{ .code = .auth_required, .message = "the subagent provider needs setup or credential repair" },
        error.AgentRouteUnavailable => .{ .code = .unsupported_model, .message = "the subagent provider needs a valid route in providers.json" },
        error.AgentToolsUnsupported => .{ .code = .unsupported_model, .message = "the subagent model must have known tool support" },
        error.AgentReasoningUnsupported => .{ .code = .unsupported_reasoning, .message = "the subagent model does not support the selected reasoning level" },
        error.BadChild => .{ .code = .bad_request, .message = "a child needs initial input, a model, and a parent in the same workspace" },
        error.AgentDepthLimit => .{ .code = .bad_request, .message = "the parent has reached the agent depth limit" },
        error.BadChildName => .{ .code = .bad_request, .message = "the child name is invalid" },
        error.DuplicateChildName => .{ .code = .bad_request, .message = "the parent already has a child with this name" },
        error.BadToolSite => .{ .code = .bad_request, .message = "the parent tool site is not active" },
        error.UnknownSession => .{ .code = .unknown_session, .message = "unknown session" },
        error.ProtectedInput => .{ .code = .bad_request, .message = "engine reports and notices cannot be canceled" },
        error.UnknownInput => .{ .code = .unknown_input, .message = "unknown queued input" },
        error.UnknownConfigRev => .{ .code = .unknown_config_rev, .message = "unknown config revision" },
        error.UnknownProvider => .{ .code = .unknown_provider, .message = "unknown provider" },
        error.RunMismatch => .{ .code = .run_mismatch, .message = "the active run does not match" },
        error.RuntimeFailed => .{ .code = .runtime_failed, .message = "the session runtime failed" },
        error.ReportCapacityFull => .{ .code = .queue_full, .message = "the child result budget is full; let child runs finish and let the parent consume reports before retry" },
        error.QueueFull => .{ .code = .queue_full, .message = "the input queue is full" },
        error.SessionOwned => .{ .code = .session_busy, .message = "another engine owns this session tree" },
        error.EngineClosing => .{ .code = .runtime_failed, .message = "the engine is closed" },
        error.SessionBusy => .{ .code = .session_busy, .message = "the session is open or has an active run" },
        error.SessionHasChildren => .{ .code = .session_has_children, .message = "the session has children" },
        error.SkillUnsupported => .{ .code = .unknown_skill, .message = "skills are not supported" },
        error.BadCursor => .{ .code = .stale_cursor, .message = "stale cursor" },
        error.RootNotAbsolute => .{ .code = .bad_request, .message = "the workspace path must be absolute" },
        error.BadPath => .{ .code = .bad_request, .message = "the engine cannot read the path" },
        error.InvalidPromptPlaceholder => .{ .code = .bad_request, .message = "the prompt contains an unknown or incomplete placeholder" },
        error.PromptTooLarge => .{ .code = .bad_request, .message = "the resolved prompt exceeds the protocol string limit" },
        error.BadRequest => .{ .code = .bad_request, .message = "a limit is out of range" },
        error.BadApiKey => .{ .code = .bad_request, .message = "the api key is empty" },
        error.BadProviderId => .{ .code = .bad_request, .message = "the provider id is not a selector part" },
        error.NoLoginFlow => .{ .code = .bad_request, .message = "the provider offers no login flow" },
        error.LoginInProgress => .{ .code = .bad_request, .message = "a login for this provider already runs" },
        error.NoConfigDirectory => .{ .code = .internal, .message = "no config directory holds providers.json" },
        error.BadProvidersFile => .{ .code = .internal, .message = "providers.json did not load" },
        error.Unavailable => .{ .code = .internal, .message = "the engine stops" },
        else => null,
    };
}

test "a name outside the protocol refuses with the unknown method code" {
    var sink: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer sink.deinit();

    // `call` resolves the method name before it reads the runtime, so this path needs no state.
    var runtime: App = undefined;
    const failure = (try call(&runtime, std.testing.allocator, "nope.nope", "{}", &sink.writer)).?;

    try std.testing.expectEqual(proto.enums.ErrorCode.unknown_method, failure.code);
    try std.testing.expectEqualStrings("unknown method", failure.message);
    try std.testing.expectEqual(@as(usize, 0), sink.written().len);
}

test "tree contention uses the existing session busy error" {
    const refusal = failureFor(error.SessionOwned).?;
    try std.testing.expectEqual(proto.enums.ErrorCode.session_busy, refusal.code);
    try std.testing.expectEqualStrings("another engine owns this session tree", refusal.message);
}
