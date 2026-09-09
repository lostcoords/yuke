//! Bind protocol methods to commands and map command refusals to wire errors.

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
            if (comptime @hasDecl(bindings, @tagName(spec.name))) {
                const params = std.json.parseFromSliceLeaky(spec.params, arena, params_json, .{
                    .ignore_unknown_fields = true,
                }) catch return Failure{ .code = .bad_request, .message = "bad parameters" };

                var diagnostic: ?[]const u8 = null;
                const result = invoke(spec, runtime, arena, params, &launch, &diagnostic) catch |err| {
                    if (diagnostic) |message| return Failure{ .code = .bad_request, .message = message };
                    return failureFor(err) orelse return err;
                };

                try std.json.Stringify.value(result, .{ .emit_null_optional_fields = false }, out);
                return null;
            }
            return Failure{ .code = .not_implemented, .message = "not implemented" };
        }
    }
    unreachable; // The protocol validates one table entry for every method name.
}

const bindings = struct {
    pub const @"agents.get" = @import("../engine/agent_config.zig").get;
    pub const @"agents.update" = @import("../engine/agent_config.zig").update;
    pub const initialize = commands.initialize;
    pub const @"session.list" = commands.sessionList;
    pub const @"session.get" = commands.sessionGet;
    pub const @"session.queue" = commands.sessionQueue;
    pub const @"session.create" = commands.sessionCreateForRpc;
    pub const @"session.patch" = commands.sessionPatch;
    pub const @"session.config" = commands.sessionConfig;
    pub const @"session.reload_context" = commands.sessionReloadContext;
    pub const @"skill.load" = commands.skillLoad;
    pub const @"session.history" = commands.sessionHistory;
    pub const @"session.send_input" = commands.sessionSendInputForRpc;
    pub const @"session.cancel_input" = commands.sessionCancelInput;
    pub const @"session.cancel_run" = commands.sessionCancelRun;
    pub const @"session.compact" = commands.sessionCompact;
    pub const @"session.remove" = commands.sessionRemove;
    pub const @"catalog.list" = app_commands.catalogList;
    pub const @"catalog.reload" = app_commands.catalogReload;
    pub const @"auth.list" = app_commands.authList;
    pub const @"auth.set_api_key" = app_commands.authSetApiKey;
    pub const @"auth.remove" = app_commands.authRemove;
    pub const @"auth.login" = app_commands.authLogin;
    pub const @"auth.cancel_login" = app_commands.authCancelLogin;
};

comptime {
    for (std.meta.declarations(bindings)) |binding| {
        if (!@hasField(proto.enums.MethodName, binding.name))
            @compileError("command binding has no protocol method: " ++ binding.name);
    }
}

/// The handler signature states its owner and whether it needs response gates.
fn invoke(comptime spec: anytype, runtime: *App, arena: std.mem.Allocator, params: spec.params, launch: *?turn.Launch, diagnostic: *?[]const u8) !spec.result {
    const handler = @field(bindings, @tagName(spec.name));
    const args = @typeInfo(@TypeOf(handler)).@"fn".params;
    const owner = if (args[0].type.? == *App) runtime else &runtime.engine;
    return switch (args.len) {
        2 => handler(owner, arena),
        3 => handler(owner, arena, params),
        4 => handler(owner, arena, params, launch),
        5 => handler(owner, arena, params, launch, diagnostic),
        else => @compileError("unsupported command signature"),
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
        error.NoModel => .{ .code = .bad_request, .message = "a session must name a model" },
        error.EmptyPatch => .{ .code = .invalid_patch, .message = "the patch names no field to change" },
        error.ModelUnknown => .{ .code = .unsupported_model, .message = "the catalog names no model with this selector" },
        error.ModelUnavailable => .{ .code = .auth_required, .message = "the provider of this model needs setup or credential repair" },
        error.ModelRouteUnavailable => .{ .code = .unsupported_model, .message = "the provider of this model needs a valid route in providers.json" },
        error.ModelToolsUnsupported => .{ .code = .unsupported_model, .message = "the model must have known tool support" },
        error.ReasoningUnsupported => .{ .code = .unsupported_reasoning, .message = "the model does not support the selected reasoning level" },
        error.BadChild => .{ .code = .bad_request, .message = "a child needs initial input and a parent in the same workspace" },
        error.ChildReasoningDerived => .{ .code = .bad_request, .message = "a child takes the reasoning level of its parent; it cannot name one" },
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
        error.UnknownSkill => .{ .code = .unknown_skill, .message = "the session catalog has no skill with this name" },
        error.SkillUnreadable => .{ .code = .bad_request, .message = "the engine cannot read the skill file" },
        error.TooManySkills => .{ .code = .bad_request, .message = "a skill root holds more entries than the scan bound" },
        error.BadCursor => .{ .code = .stale_cursor, .message = "stale cursor" },
        error.RootNotAbsolute => .{ .code = .bad_request, .message = "the workspace path must be absolute" },
        error.BadPath => .{ .code = .bad_request, .message = "the engine cannot read the path" },
        error.InvalidInstructions => .{ .code = .bad_request, .message = "an AGENTS.md source is invalid" },
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
