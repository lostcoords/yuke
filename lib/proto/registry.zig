//! The protocol type registry for the oracle and generator.

const activity = @import("activity.zig");
const auth = @import("auth.zig");
const catalog = @import("catalog.zig");
const content = @import("content.zig");
const enums = @import("enums.zig");
const initialize = @import("initialize.zig");
const input = @import("input.zig");
const interaction = @import("interaction.zig");
const skill = @import("skill.zig");
const message = @import("message.zig");
const misc = @import("misc.zig");
const rpc = @import("rpc.zig");
const run = @import("run.zig");
const session = @import("session.zig");
const tool = @import("tool.zig");
const view = @import("view.zig");

pub const TypeEntry = struct { name: []const u8, ty: type };
pub const EnumEntry = struct { name: []const u8, ty: type };
pub const AliasEntry = struct { name: []const u8, base: []const u8 };

pub const structs = [_]TypeEntry{
    .{ .name = "Client", .ty = initialize.Client },
    .{ .name = "ContentText", .ty = content.ContentText },
    .{ .name = "ContentImage", .ty = content.ContentImage },
    .{ .name = "ContentAudio", .ty = content.ContentAudio },
    .{ .name = "ContentFile", .ty = content.ContentFile },
    .{ .name = "MediaBlob", .ty = content.MediaBlob },
    .{ .name = "AuthCancelLoginParams", .ty = auth.AuthCancelLoginParams },
    .{ .name = "AuthChangedData", .ty = auth.AuthChangedData },
    .{ .name = "AuthListResult", .ty = auth.AuthListResult },
    .{ .name = "AuthLoginResult", .ty = auth.AuthLoginResult },
    .{ .name = "AuthLoginFinishedData", .ty = auth.AuthLoginFinishedData },
    .{ .name = "AuthLoginOutcomeCanceled", .ty = auth.AuthLoginOutcomeCanceled },
    .{ .name = "AuthLoginOutcomeFailed", .ty = auth.AuthLoginOutcomeFailed },
    .{ .name = "AuthLoginOutcomeSucceeded", .ty = auth.AuthLoginOutcomeSucceeded },
    .{ .name = "AuthLoginParams", .ty = auth.AuthLoginParams },
    .{ .name = "AuthRemoveParams", .ty = auth.AuthRemoveParams },
    .{ .name = "AuthProvider", .ty = auth.AuthProvider },
    .{ .name = "AuthSetApiKeyParams", .ty = auth.AuthSetApiKeyParams },
    .{ .name = "CatalogChangedData", .ty = catalog.CatalogChangedData },
    .{ .name = "CatalogListParams", .ty = catalog.CatalogListParams },
    .{ .name = "CatalogListResultFull", .ty = catalog.CatalogListResultFull },
    .{ .name = "ProviderInfo", .ty = catalog.ProviderInfo },
    .{ .name = "CatalogListResultUnchanged", .ty = catalog.CatalogListResultUnchanged },
    .{ .name = "CatalogRefreshResult", .ty = catalog.CatalogRefreshResult },
    .{ .name = "ModelCost", .ty = catalog.ModelCost },
    .{ .name = "ModelInfo", .ty = catalog.ModelInfo },
    .{ .name = "Request", .ty = rpc.Request },
    .{ .name = "ResponseOk", .ty = rpc.ResponseOk },
    .{ .name = "ResponseError", .ty = rpc.ResponseError },
    .{ .name = "Notification", .ty = rpc.Notification },
    .{ .name = "ActivityStateBuilding", .ty = activity.ActivityStateBuilding },
    .{ .name = "ActivityStateCompacting", .ty = activity.ActivityStateCompacting },
    .{ .name = "ActivityStateIdle", .ty = activity.ActivityStateIdle },
    .{ .name = "ActivityStateReasoning", .ty = activity.ActivityStateReasoning },
    .{ .name = "ActivityStateRetrying", .ty = activity.ActivityStateRetrying },
    .{ .name = "ActivityStateRunning", .ty = activity.ActivityStateRunning },
    .{ .name = "ActivityStateRunningTool", .ty = activity.ActivityStateRunningTool },
    .{ .name = "InputCanceledData", .ty = input.InputCanceledData },
    .{ .name = "InputContent", .ty = input.InputContent },
    .{ .name = "InputQueuedData", .ty = input.InputQueuedData },
    .{ .name = "InteractionRequestedData", .ty = interaction.InteractionRequestedData },
    .{ .name = "InteractionConfirm", .ty = interaction.InteractionConfirm },
    .{ .name = "InteractionSelect", .ty = interaction.InteractionSelect },
    .{ .name = "InteractionInput", .ty = interaction.InteractionInput },
    .{ .name = "InteractionRespondParams", .ty = interaction.InteractionRespondParams },
    .{ .name = "InteractionConfirmed", .ty = interaction.InteractionConfirmed },
    .{ .name = "InteractionValue", .ty = interaction.InteractionValue },
    .{ .name = "InputSkill", .ty = input.InputSkill },
    .{ .name = "SkillInfo", .ty = skill.SkillInfo },
    .{ .name = "SkillRef", .ty = skill.SkillRef },
    .{ .name = "SkillsResult", .ty = skill.SkillsResult },
    .{ .name = "ActiveDraft", .ty = message.ActiveDraft },
    .{ .name = "AssistantMessage", .ty = message.AssistantMessage },
    .{ .name = "CompactionMessage", .ty = message.CompactionMessage },
    .{ .name = "MessageCommittedData", .ty = message.MessageCommittedData },
    .{ .name = "MessageDiscardedData", .ty = message.MessageDiscardedData },
    .{ .name = "MessageError", .ty = message.MessageError },
    .{ .name = "MessagePartAddedData", .ty = message.MessagePartAddedData },
    .{ .name = "MessagePartFinalizedData", .ty = message.MessagePartFinalizedData },
    .{ .name = "MessageStartedData", .ty = message.MessageStartedData },
    .{ .name = "MessageTime", .ty = message.MessageTime },
    .{ .name = "PartDelta", .ty = message.PartDelta },
    .{ .name = "ReasoningFinal", .ty = message.ReasoningFinal },
    .{ .name = "ReasoningPart", .ty = message.ReasoningPart },
    .{ .name = "RedactedReasoningFinal", .ty = message.RedactedReasoningFinal },
    .{ .name = "RedactedReasoningPart", .ty = message.RedactedReasoningPart },
    .{ .name = "TextPart", .ty = message.TextPart },
    .{ .name = "TokenUsage", .ty = message.TokenUsage },
    .{ .name = "ToolPart", .ty = message.ToolPart },
    .{ .name = "TurnProvenance", .ty = message.TurnProvenance },
    .{ .name = "UserMessage", .ty = message.UserMessage },
    .{ .name = "ConfigChangedData", .ty = misc.ConfigChangedData },
    .{ .name = "CreateSession", .ty = misc.CreateSession },
    .{ .name = "CreatedTime", .ty = misc.CreatedTime },
    .{ .name = "EngineInfo", .ty = misc.EngineInfo },
    .{ .name = "Empty", .ty = misc.Empty },
    .{ .name = "ErrorObject", .ty = misc.ErrorObject },
    .{ .name = "InitializeResult", .ty = misc.InitializeResult },
    .{ .name = "Notice", .ty = misc.Notice },
    .{ .name = "QueuedInput", .ty = misc.QueuedInput },
    .{ .name = "Session", .ty = misc.Session },
    .{ .name = "TranscriptTruncatedData", .ty = misc.TranscriptTruncatedData },
    .{ .name = "RunCanceledTiming", .ty = run.RunCanceledTiming },
    .{ .name = "RunConfig", .ty = run.RunConfig },
    .{ .name = "RunDoneData", .ty = run.RunDoneData },
    .{ .name = "RunOutcomeCanceled", .ty = run.RunOutcomeCanceled },
    .{ .name = "RunOutcomeCompacted", .ty = run.RunOutcomeCompacted },
    .{ .name = "RunOutcomeFailed", .ty = run.RunOutcomeFailed },
    .{ .name = "RunOutcomeSkipped", .ty = run.RunOutcomeSkipped },
    .{ .name = "RunOutcomeTurn", .ty = run.RunOutcomeTurn },
    .{ .name = "RunStartedData", .ty = run.RunStartedData },
    .{ .name = "SessionActivity", .ty = session.SessionActivity },
    .{ .name = "SessionActivityChangedData", .ty = session.SessionActivityChangedData },
    .{ .name = "SessionCancelInputParams", .ty = session.SessionCancelInputParams },
    .{ .name = "SessionCancelInputResult", .ty = session.SessionCancelInputResult },
    .{ .name = "SessionCancelRunParams", .ty = session.SessionCancelRunParams },
    .{ .name = "SessionCancelRunResult", .ty = session.SessionCancelRunResult },
    .{ .name = "SessionCompactParams", .ty = session.SessionCompactParams },
    .{ .name = "SessionCompactResult", .ty = session.SessionCompactResult },
    .{ .name = "SessionConfigParams", .ty = session.SessionConfigParams },
    .{ .name = "SessionConfigResult", .ty = session.SessionConfigResult },
    .{ .name = "SessionForkParams", .ty = session.SessionForkParams },
    .{ .name = "SessionHistoryParams", .ty = session.SessionHistoryParams },
    .{ .name = "SessionHistoryResult", .ty = session.SessionHistoryResult },
    .{ .name = "SessionListItem", .ty = session.SessionListItem },
    .{ .name = "SessionListParams", .ty = session.SessionListParams },
    .{ .name = "SessionListResult", .ty = session.SessionListResult },
    .{ .name = "SessionOriginChild", .ty = session.SessionOriginChild },
    .{ .name = "SessionOriginFork", .ty = session.SessionOriginFork },
    .{ .name = "SessionOriginRoot", .ty = session.SessionOriginRoot },
    .{ .name = "SessionPatch", .ty = session.SessionPatch },
    .{ .name = "SessionPatchParams", .ty = session.SessionPatchParams },
    .{ .name = "SessionPopulationAll", .ty = session.SessionPopulationAll },
    .{ .name = "SessionPopulationChildren", .ty = session.SessionPopulationChildren },
    .{ .name = "SessionPopulationTopLevel", .ty = session.SessionPopulationTopLevel },
    .{ .name = "SessionRemoveParams", .ty = session.SessionRemoveParams },
    .{ .name = "SessionRemovedData", .ty = session.SessionRemovedData },
    .{ .name = "SessionResult", .ty = session.SessionResult },
    .{ .name = "SessionRewindParams", .ty = session.SessionRewindParams },
    .{ .name = "SessionSendInputParams", .ty = session.SessionSendInputParams },
    .{ .name = "SessionSendInputResultQueued", .ty = session.SessionSendInputResultQueued },
    .{ .name = "SessionSendInputResultStarted", .ty = session.SessionSendInputResultStarted },
    .{ .name = "SessionSummaryChangedData", .ty = session.SessionSummaryChangedData },
    .{ .name = "ToolStateCanceled", .ty = tool.ToolStateCanceled },
    .{ .name = "ToolStateChangedData", .ty = tool.ToolStateChangedData },
    .{ .name = "ToolStateCompleted", .ty = tool.ToolStateCompleted },
    .{ .name = "ToolStateError", .ty = tool.ToolStateError },
    .{ .name = "ToolStatePending", .ty = tool.ToolStatePending },
    .{ .name = "ToolStateRunning", .ty = tool.ToolStateRunning },
    .{ .name = "DiffFile", .ty = view.DiffFile },
    .{ .name = "DiffHunk", .ty = view.DiffHunk },
    .{ .name = "ViewDiff", .ty = view.ViewDiff },
    .{ .name = "ViewImage", .ty = view.ViewImage },
    .{ .name = "ViewJson", .ty = view.ViewJson },
    .{ .name = "ViewMarkdown", .ty = view.ViewMarkdown },
    .{ .name = "ViewText", .ty = view.ViewText },
};

pub const tagged_unions = [_]TypeEntry{
    .{ .name = "ContentPart", .ty = content.ContentPart },
    .{ .name = "MediaSource", .ty = content.MediaSource },
    .{ .name = "AuthLoginOutcome", .ty = auth.AuthLoginOutcome },
    .{ .name = "CatalogListResult", .ty = catalog.CatalogListResult },
    .{ .name = "ActivityState", .ty = activity.ActivityState },
    .{ .name = "Input", .ty = input.Input },
    .{ .name = "InteractionRequest", .ty = interaction.InteractionRequest },
    .{ .name = "InteractionResponse", .ty = interaction.InteractionResponse },
    .{ .name = "AssistantPart", .ty = message.AssistantPart },
    .{ .name = "Message", .ty = message.Message },
    .{ .name = "PartFinal", .ty = message.PartFinal },
    .{ .name = "RunOutcome", .ty = run.RunOutcome },
    .{ .name = "SessionOrigin", .ty = session.SessionOrigin },
    .{ .name = "SessionPopulation", .ty = session.SessionPopulation },
    .{ .name = "SessionSendInputResult", .ty = session.SessionSendInputResult },
    .{ .name = "ToolState", .ty = tool.ToolState },
    .{ .name = "View", .ty = view.View },
};

pub const envelope_unions = [_]TypeEntry{
    .{ .name = "RequestParams", .ty = rpc.RequestParams },
    .{ .name = "ResponseResult", .ty = rpc.ResponseResult },
    .{ .name = "BroadcastData", .ty = rpc.BroadcastData },
    .{ .name = "Response", .ty = rpc.Response },
};

pub const string_enums = [_]EnumEntry{
    .{ .name = "AuthCredentialKind", .ty = enums.AuthCredentialKind },
    .{ .name = "BroadcastName", .ty = enums.BroadcastName },
    .{ .name = "RunErrorCode", .ty = enums.RunErrorCode },
    .{ .name = "MethodName", .ty = enums.MethodName },
    .{ .name = "NoticeLevel", .ty = enums.NoticeLevel },
    .{ .name = "RunKind", .ty = enums.RunKind },
    .{ .name = "CompactSkipReason", .ty = enums.CompactSkipReason },
    .{ .name = "StopReason", .ty = enums.StopReason },
    .{ .name = "CompactStatus", .ty = enums.CompactStatus },
    .{ .name = "SessionView", .ty = enums.SessionView },
    .{ .name = "CompactionReason", .ty = enums.CompactionReason },
    .{ .name = "ProviderProtocol", .ty = enums.ProviderProtocol },
    .{ .name = "ProviderSource", .ty = enums.ProviderSource },
    .{ .name = "ProviderState", .ty = enums.ProviderState },
    .{ .name = "SkillScope", .ty = enums.SkillScope },
};

pub const numeric_enums = [_]EnumEntry{
    .{ .name = "ErrorCode", .ty = enums.ErrorCode },
};

/// Every enum in emission order: the string enums, with the one numeric enum after the second.
/// The list derives from the two tables above, so adding or removing an enum needs no edit here.
pub const enum_order = blk: {
    const Ordered = struct { entry: EnumEntry, numeric: bool };
    var out: [string_enums.len + numeric_enums.len]Ordered = undefined;
    var i: usize = 0;
    for (string_enums, 0..) |entry, n| {
        out[i] = .{ .entry = entry, .numeric = false };
        i += 1;
        if (n == 1) {
            out[i] = .{ .entry = numeric_enums[0], .numeric = true };
            i += 1;
        }
    }
    const frozen = out;
    break :blk frozen;
};

pub const aliases = [_]AliasEntry{
    .{ .name = "ProviderId", .base = "string" },
    .{ .name = "MessagePartDeltaData", .base = "PartDelta" },
    .{ .name = "ToolOutputDeltaData", .base = "PartDelta" },
    .{ .name = "CatalogRev", .base = "[64]u8" },
    .{ .name = "ModelId", .base = "string" },
    .{ .name = "SessionId", .base = "[16]u8" },
    .{ .name = "LoginId", .base = "[32]u8" },
    .{ .name = "RequestId", .base = "string" },
    .{ .name = "MessageId", .base = "u64" },
    .{ .name = "RunId", .base = "u64" },
    .{ .name = "InputId", .base = "u64" },
    .{ .name = "PartId", .base = "u64" },
    .{ .name = "Seq", .base = "u64" },
    .{ .name = "SessionRevision", .base = "u64" },
    .{ .name = "ConfigRev", .base = "u64" },
    .{ .name = "InteractionId", .base = "u64" },
};
