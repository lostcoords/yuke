// Generated from the protocol types by the bindings test of `yuke-protocol`. Do not edit.
// The types of the protocol that plugins use, as the clients of the protocol see them.

/**
 * The facts of one answer of the model.
 */
export type Answer = { 
/**
 * The model and host of the target that answered.
 */
origin: Origin, 
/**
 * The input, output, reasoning, cache read, and cache write token counts of the answer.
 */
usage: Usage, 
/**
 * The reason that the answer stopped, such as `length` or `content_filter`.
 */
finishReason: FinishReason, };

/**
 * Bytes in the caller's store, named by the digest of their content. Equal digests name equal bytes. Thus the request
 * of a resumed context reads no blob that the encoder kept.
 */
export type Blob = { 
/**
 * The digest of the content, such as its SHA-256. JSON holds it as 64 lowercase hex characters.
 */
digest: string, 
/**
 * The byte count of the content. [`BlobStore`] answers are checked against it.
 */
len: number, };

/**
 * One block of the context. Its kind fixes its role ([`Block::role`]), so it holds only content of that role.
 * The serializer groups the blocks into the messages of each protocol.
 */
export type Block = { "user_text": string } | { "media": Media } | { "tool_result": ToolResult } | { "assistant_text": string } | { "reasoning": Reasoning } | { "tool_call": ToolCall };

/**
 * The kind of a streamed block. A refusal is the text of a model that declined the request. The library keeps the
 * refusal apart from the answer text.
 */
export type BlockKind = "text" | "refusal" | "reasoning" | "tool_call";

/**
 * A block position within one session. A tool execution uses the position of its call, not its result.
 */
export type BlockPosition = { 
/**
 * The event that contains the block.
 */
eventNumber: EventNumber, 
/**
 * The zero-based index within the commit's blocks, not within the current context.
 */
blockIndex: number, };

/**
 * The hints of one tool call of a commit, and the folder where it ran.
 */
export type CallDisplay = { 
/**
 * The index of the call in the blocks of the commit.
 */
blockIndex: number, 
/**
 * The hints of the tool that the call names, after the deferred-tool bridge.
 */
hints: ToolHints, 
/**
 * The folder where the call ran. A relative path of the call starts there.
 */
folder: string | null, };

/**
 * The change of the context since the last commit, and the facts of the turn. Replay each commit in order on a copy
 * of the context: apply `replaced`, then append `blocks`. The copy then equals the context. The driver lends its
 * blocks, and a store that reads a commit back owns them.
 */
export type Commit = { 
/**
 * The replacement of the context. A commit with a replacement holds no blocks.
 */
replaced: Replaced | null, 
/**
 * The blocks after the saved blocks, in context order.
 */
blocks: Array<Block>, 
/**
 * The facts of the answer in `blocks`. A commit without an answer has `None`.
 */
answer: Answer | null, 
/**
 * How the turn ended. A commit in the middle of a turn has `None`.
 */
end: TurnEnd | null, 
/**
 * What a frontend shows for the tool calls and results in `blocks`. The model never sees it.
 */
display?: CommitDisplay, };

/**
 * What a frontend shows for the tool calls and results of a commit. The model never sees it.
 */
export type CommitDisplay = { 
/**
 * The hints of each tool call that the driver handled, in block order.
 */
calls: Array<CallDisplay>, 
/**
 * The display of each tool result that has one, in block order.
 */
results: Array<ResultDisplay>, };

/**
 * An input that a commit consumed. The commit starts with the model blocks of its consumed inputs, in input order.
 * This input has the next `blockCount` blocks.
 */
export type ConsumedInput = { 
/**
 * The id that `Store::accept_input` of `yuke-agent` gave.
 */
id: InputId, 
/**
 * Who sent the input.
 */
source: InputSource, 
/**
 * What the input is.
 */
kind: InputKind, 
/**
 * The blocks that the user saw, only when they differ from the blocks that the model read.
 */
displayContent?: Array<Block> | null, 
/**
 * The number of blocks of the commit that the model read for this input.
 */
blockCount: number, };

/**
 * One block that a frontend shows for a result. The model never sees it.
 */
export type DisplayBlock = { "kind": "markdown", 
/**
 * The Markdown source.
 */
text: string, } | { "kind": "diff", 
/**
 * The path of the file. A relative path starts in the folder of the call.
 */
path: string, 
/**
 * Unified hunks, each with its `@@` header.
 */
patch: string, };

/**
 * Why a client must remove a draft without a confirmed saved replacement.
 */
export type DraftDiscardReason = "failed" | "unconfirmed";

/**
 * The ephemeral identity of one live provider attempt. The store never saves it.
 * A reconnect cannot resume this draft. The client replaces prior drafts with saved history.
 */
export type DraftId = string;

/**
 * A named reasoning effort from the closed portable set.
 */
export type Effort = "minimal" | "low" | "medium" | "high" | "xhigh" | "max";

/**
 * The number of an event in its session. The events of a session have the numbers 1, 2, 3, and so on.
 */
export type EventNumber = number;

/**
 * The params of `extension/event`.
 */
export type ExtensionEventParams = { 
/**
 * The session of the event. The field is absent for an event of the whole process.
 */
sessionId?: SessionId | null, 
/**
 * The name that the host gives the plugin.
 */
extension: string, 
/**
 * The name of the event. The plugin chooses it.
 */
event: string, 
/**
 * The data of the event. The plugin chooses its shape, and it puts a version in it when the shape changes.
 */
data: unknown, };

/**
 * Why a response ended. At `Length` a tool call can hold cut-off arguments, so do not run such a call.
 * `Pause` marks an Anthropic server-tool loop at its iteration cap. The same content resumes the loop.
 */
export type FinishReason = "stop" | "length" | "content_filter" | "refusal" | "tool_calls" | "pause" | "unknown";

/**
 * An accepted input. It holds the blocks that the user saw, and other blocks for the model when they differ. An input
 * has at least one block.
 */
export type Input = { 
/**
 * Who sent the input.
 */
source: InputSource, 
/**
 * What the input is.
 */
kind: InputKind, 
/**
 * The blocks that the user saw.
 */
content: Array<Block>, 
/**
 * The blocks that the model reads, only when they differ from the content.
 */
modelContent?: Array<Block> | null, };

/**
 * The id of a pending input. A store gives each input of a session a larger id than the inputs before it.
 */
export type InputId = number;

/**
 * What an input is. A client shows a message in the conversation, and a notification as a notice.
 */
export type InputKind = "message" | "notification";

/**
 * Who sent an input. It records the sender only. It grants no permission and sets no visibility.
 */
export type InputSource = { "kind": "user" } | { "kind": "plugin", 
/**
 * The name of the plugin.
 */
name: string, };

/**
 * The id of a question. The server gives each question a larger id than the questions before it, in each session.
 */
export type InteractionId = number;

/**
 * One question. A client shows it in its own way.
 */
export type InteractionRequest = { "kind": "confirm", 
/**
 * The question.
 */
title: string, 
/**
 * More text about the question. It can be empty.
 */
message: string, } | { "kind": "select", 
/**
 * The question.
 */
title: string, 
/**
 * The options, in display order. They are unique.
 */
options: Array<string>, } | { "kind": "input", 
/**
 * The question.
 */
title: string, 
/**
 * The text that an empty field shows.
 */
placeholder?: string | null, 
/**
 * The field hides what the user types, as for a password.
 */
secret: boolean, };

/**
 * An answer. Its kind matches the kind of the question, or the question ended without an answer.
 */
export type InteractionResponse = { "kind": "confirm", 
/**
 * `true` for yes.
 */
value: boolean, } | { "kind": "select", 
/**
 * One of the options of the question.
 */
value: string, } | { "kind": "input", 
/**
 * The text.
 */
value: string, } | { "kind": "canceled" };

/**
 * A background job.
 */
export type Job = { 
/**
 * The id of the job, for example `job-1a2b`.
 */
id: string, 
/**
 * The command of the job.
 */
command: string, 
/**
 * The file that holds the output of the job.
 */
log: string, } & ({ "state": "running" } | { "state": "ended", 
/**
 * The exit code, when the process exited.
 */
exitCode?: number | null, 
/**
 * The signal that ended the process.
 */
signal?: number | null, 
/**
 * A stop ended the job: `job/stop`, a close, or the end of the server.
 */
stopped: boolean, });

/**
 * The result of `catalog/list`.
 */
export type ListCatalogResult = { 
/**
 * The providers in catalog order: the built-in ones, then the additions of `providers.json`.
 */
providers: Array<ProviderInfo>, };

/**
 * The params of `session/list`.
 */
export type ListSessionsParams = { 
/**
 * Only the sessions whose newest settings name this folder. None lists the sessions of every folder.
 */
cwd?: string | null, 
/**
 * The most rows of the page, from 1 to 100. None gives 50.
 */
limit?: number | null, 
/**
 * The `nextCursor` of the page before, with the same `cwd`. None starts at the newest session.
 */
cursor?: string | null, };

/**
 * The result of `session/list`.
 */
export type ListSessionsResult = { 
/**
 * The sessions of the page, newest first by their newest event. The pages are no snapshot: a session that a new
 * event moves to the front between two pages comes only in a new list.
 */
sessions: Array<SessionRow>, 
/**
 * The cursor of the next page. None when no older session exists.
 */
nextCursor?: string | null, };

/**
 * A live fact of a session. Saved events remain authoritative after reconnect.
 */
export type LiveUpdate = { "sessionUpdate": "state", 
/**
 * Whether a turn runs.
 */
state: SessionState, } | { "sessionUpdate": "job", 
/**
 * The job.
 */
job: Job, } | { "sessionUpdate": "input_accepted", 
/**
 * The id of the input.
 */
inputId: InputId, 
/**
 * The input.
 */
input: Input, } | { "sessionUpdate": "interaction_requested", 
/**
 * The id that the answer names.
 */
interactionId: InteractionId, 
/**
 * The plugin that asks, or a part of yuke with a name that starts with `host:`.
 */
source: string, 
/**
 * The question.
 */
request: InteractionRequest, } | { "sessionUpdate": "interaction_closed", 
/**
 * The question.
 */
interactionId: InteractionId, } | { "sessionUpdate": "mcp_server", 
/**
 * The name of the server in its config.
 */
name: string, 
/**
 * The config file of the server.
 */
source: McpServerSource, } & ({ "state": "connecting" } | { "state": "connected", 
/**
 * The number of its tools.
 */
tools: number, } | { "state": "failed", 
/**
 * Why.
 */
error: string, } | { "state": "disabled" } | { "state": "untrusted" }) | { "sessionUpdate": "input_removed", 
/**
 * The id of the input.
 */
inputId: InputId, } | { "sessionUpdate": "turn_unconfirmed" } | { "sessionUpdate": "draft_started", 
/**
 * The identity of this attempt, distinct across turns and process restarts.
 */
draftId: DraftId, } | { "sessionUpdate": "model", 
/**
 * The draft of this fact.
 */
draftId: DraftId, 
/**
 * The model fact.
 */
event: ModelUpdate, } | { "sessionUpdate": "draft_committed", 
/**
 * The draft to replace, including any blocks absent from `blocks`.
 */
draftId: DraftId, 
/**
 * The saved commit that holds every retained block.
 */
eventNumber: EventNumber, 
/**
 * Original draft block ids in saved block order. Array index `i` maps to commit block index `i`.
 * Draft blocks absent from this array do not enter history.
 */
blocks: Array<number>, } | { "sessionUpdate": "draft_discarded", 
/**
 * The draft to remove.
 */
draftId: DraftId, 
/**
 * Why the draft has no confirmed replacement.
 */
reason: DraftDiscardReason, } | { "sessionUpdate": "tool_started", 
/**
 * The position of the saved call, even when the provider repeats its call id.
 */
execution: BlockPosition, 
/**
 * The resolved call after the deferred-tool bridge. Its call id remains provider data.
 */
call: ToolCall, } | { "sessionUpdate": "tool_output", 
/**
 * The position of the saved call.
 */
execution: BlockPosition, 
/**
 * The new output text.
 */
text: string, } | { "sessionUpdate": "tool_finished", 
/**
 * The position of the saved call.
 */
execution: BlockPosition, 
/**
 * The result of the call.
 */
result: ToolResult, 
/**
 * What a frontend shows in place of the result text. The model never sees it.
 */
display: Array<DisplayBlock>, } | { "sessionUpdate": "retry_scheduled", 
/**
 * The wait in milliseconds.
 */
afterMs: number, 
/**
 * The failure text.
 */
error: string, } | { "sessionUpdate": "round_failed", 
/**
 * The failure text with each cause.
 */
error: string, };

/**
 * One MCP server of a session.
 */
export type McpServer = { 
/**
 * The name of the server in its config.
 */
name: string, 
/**
 * The config file of the server.
 */
source: McpServerSource, } & ({ "state": "connecting" } | { "state": "connected", 
/**
 * The number of its tools.
 */
tools: number, } | { "state": "failed", 
/**
 * Why.
 */
error: string, } | { "state": "disabled" } | { "state": "untrusted" });

/**
 * The config file of an MCP server.
 */
export type McpServerSource = "user" | "project";

/**
 * One attachment. Its media type selects the block each protocol writes.
 */
export type Media = { 
/**
 * The bytes in the caller's store. The encoder reads them through [`Request::blobs`] only when it writes the
 * element.
 */
blob: Blob, 
/**
 * The IANA media type, such as `image/png` or `application/pdf`.
 */
mime: string, 
/**
 * The name a provider requires beside file bytes. An image needs none.
 */
filename?: string, };

/**
 * A kind of content that a model reads.
 */
export type Modality = "text" | "image" | "audio" | "video" | "pdf";

/**
 * A model of a provider.
 */
export type ModelInfo = { 
/**
 * The model half of a model reference.
 */
id: string, 
/**
 * The display name.
 */
name: string, 
/**
 * The context window in tokens. None when the catalog does not know it.
 */
contextWindow?: number | null, 
/**
 * The output limit in tokens. None when the catalog does not know it.
 */
maxOutputTokens?: number | null, 
/**
 * The reasoning choices of the model, each with the settings that a session sends for it.
 */
reasoning: Array<ReasoningChoice>, 
/**
 * The price bands in threshold order. The last band that the prompt reaches prices the whole request.
 */
cost: Array<PriceBand>, 
/**
 * Whether the model calls tools. None when the catalog does not know it.
 */
tools?: boolean | null, 
/**
 * Whether the model takes deferred tools. None when the catalog does not know it.
 */
toolSearch?: boolean | null, 
/**
 * The kinds of content that the model reads. Empty when the catalog does not know them.
 */
input: Array<Modality>, };

/**
 * A model of a provider, by the ids of the config.
 */
export type ModelReference = { 
/**
 * The id of the provider.
 */
provider: string, 
/**
 * The id of the model at the provider.
 */
model: string, };

/**
 * An owned model event for clients. Block ids belong to one draft and follow block start order.
 */
export type ModelUpdate = { "kind": "block_started", 
/**
 * The block id.
 */
block: number, 
/**
 * The content kind.
 */
blockKind: BlockKind, } | { "kind": "text_delta", 
/**
 * The block id.
 */
block: number, 
/**
 * The new text.
 */
text: string, } | { "kind": "refusal_delta", 
/**
 * The block id.
 */
block: number, 
/**
 * The new text.
 */
text: string, } | { "kind": "reasoning_delta", 
/**
 * The block id.
 */
block: number, 
/**
 * The new text.
 */
text: string, } | { "kind": "reasoning_section_started", 
/**
 * The block id.
 */
block: number, } | { "kind": "tool_input_delta", 
/**
 * The block id.
 */
block: number, 
/**
 * The argument fragment, which need not be valid JSON alone.
 */
text: string, } | { "kind": "block_stopped", 
/**
 * The block id.
 */
block: number, 
/**
 * The authoritative complete call for a tool block, otherwise `None`.
 */
call: ToolCall | null, } | { "kind": "response_completed", 
/**
 * The normalized finish reason.
 */
finishReason: FinishReason, 
/**
 * The provider's finish reason.
 */
rawFinishReason: string, 
/**
 * The provider's token counts.
 */
usage: Usage, };

/**
 * The severity of a notice.
 */
export type NoticeLevel = "debug" | "info" | "warn" | "error";

/**
 * The params of `notice`.
 */
export type NoticeParams = { 
/**
 * The session of the notice. The field is absent for a notice of the whole process.
 */
sessionId?: SessionId | null, 
/**
 * The severity of the notice. A client uses it to show the notice.
 */
level: NoticeLevel, 
/**
 * The plugin or the part of yuke that sent the notice.
 */
source: string, 
/**
 * The text for the user.
 */
message: string, };

/**
 * The model and host that answered a request. Provider state returns only to the same model at the same host.
 */
export type Origin = { 
/**
 * The upstream model ID.
 */
model: string, 
/**
 * The route base URL without its final slashes, so `https://h/v1/` and `https://h/v1` are one origin.
 */
baseUrl: string, };

/**
 * How a turn ended without a failure.
 */
export type Outcome = { "completed": { 
/**
 * The reason in the closed set.
 */
finishReason: FinishReason, } } | "stopped" | "cancelled";

/**
 * Ask for a response that matches a JSON Schema. Anthropic, and OpenAI with a strict schema, enforce it while
 * they sample.
 */
export type OutputSchema = { 
/**
 * The schema name OpenAI requires. Anthropic takes no name.
 */
name: string, 
/**
 * A JSON Schema object text, written verbatim. The caller checks it.
 */
schema: string, 
/**
 * OpenAI strict mode. A non-strict schema gives no guarantee.
 */
strict: boolean, };

/**
 * The part of the output that a folded call shows. An error always shows its first rows.
 */
export type Preview = "head" | "tail" | "none";

/**
 * The prices of one band, in US dollars per million tokens. A missing price is unknown, never zero.
 */
export type PriceBand = { 
/**
 * The smallest prompt that this band prices. The prompt counts every input token, the cached ones too.
 */
minPromptTokens: number, 
/**
 * The price of an input token.
 */
input?: number | null, 
/**
 * The price of an output token.
 */
output?: number | null, 
/**
 * The price of a reasoning token, which replaces the output price for it.
 */
reasoning?: number | null, 
/**
 * The price of a token that the prompt cache gives.
 */
cacheRead?: number | null, 
/**
 * The price of a token that the prompt cache keeps.
 */
cacheWrite?: number | null, };

/**
 * A provider and its models. The `id` of the provider and the `id` of a model make the
 * [`ModelReference`](crate::ModelReference) of a session.
 */
export type ProviderInfo = { 
/**
 * The provider half of a model reference.
 */
id: string, 
/**
 * The display name.
 */
name: string, 
/**
 * Whether the provider has its credential.
 */
state: ProviderState, 
/**
 * The models in catalog order.
 */
models: Array<ModelInfo>, };

/**
 * Whether a provider has its credential. The server checks that a key or a login is there. It does not test it.
 */
export type ProviderState = { "kind": "ready" } | { "kind": "needs_api_key", 
/**
 * The name of the environment variable.
 */
variable: string, } | { "kind": "needs_login" };

/**
 * Reasoning text, and the provider state that returns with it. A request carries the state only to the origin that
 * produced it, in that protocol. Elsewhere the block drops, except where a dialect replays the text.
 */
export type Reasoning = { 
/**
 * The reasoning text.
 */
text: string, 
/**
 * `None` for text alone: a block that never finished, or one whose provider sent no state.
 */
replay?: ReasoningReplay | null, };

/**
 * A reasoning level that a user can pick for a model, and the reasoning settings that a session sends for it.
 */
export type ReasoningChoice = { 
/**
 * The level.
 */
level: ReasoningLevel, 
/**
 * The reasoning settings that a session sends for this level, as the `reasoning` of its settings.
 */
settings: ReasoningSettings, };

/**
 * A reasoning level of a model.
 */
export type ReasoningLevel = "default" | "off" | "minimal" | "low" | "medium" | "high" | "xhigh" | "max";

/**
 * Provider state, and the origin that may receive it again. The state must return to its provider verbatim.
 */
export type ReasoningReplay = { 
/**
 * The model and host that produced the state.
 */
origin: Origin, 
/**
 * Which provider state `data` holds.
 */
kind: ReplayKind, 
/**
 * The state bytes.
 */
data: string, };

/**
 * The reasoning one request asks for, as the caller chose it for the model. Each serializer writes the settings its
 * protocol has.
 */
export type ReasoningSettings = { 
/**
 * Whether and how the model thinks. `None` leaves the endpoint default.
 */
thinking: Thinking | null, 
/**
 * How hard the model thinks. `None` leaves the endpoint default.
 */
effort: Effort | null, };

/**
 * A new context: `head`, then the last `keep` blocks of the old context. A compaction gives a summary and the recent
 * blocks. Another rewrite gives the whole new context as `head` and keeps nothing. A hook asks for one in a
 * [`RoundPlan`](crate::RoundPlan), and a [`Commit`] saves it.
 */
export type Replaced = { 
/**
 * The new first blocks, such as a summary.
 */
head: Array<Block>, 
/**
 * The number of blocks at the end of the old context that stay after `head`. In a plan, a number above the length
 * keeps the whole old context; a commit holds the number that stayed.
 */
keep: number, };

/**
 * The kind of provider state that a reasoning block must return verbatim. Each kind names the protocol that
 * produced the state. Only the encoder of that protocol writes it.
 */
export type ReplayKind = "anthropic_signature" | "anthropic_redacted" | "responses_encrypted" | "openrouter_details";

/**
 * The display of one tool result of a commit.
 */
export type ResultDisplay = { 
/**
 * The index of the result in the blocks of the commit.
 */
blockIndex: number, 
/**
 * What a frontend shows in place of the result text.
 */
blocks: Array<DisplayBlock>, };

/**
 * Whether a session is open in the server, and whether a turn runs in it.
 */
export type SessionActivity = "closed" | "idle" | "running";

/**
 * The id of a session: a version 7 UUID, so the ids sort by the millisecond of their creation.
 */
export type SessionId = string;

/**
 * A saved session with its facts and its activity at the moment of the answer.
 */
export type SessionRow = { 
/**
 * The saved facts.
 */
session: SessionSummary, 
/**
 * The activity.
 */
activity: SessionActivity, };

/**
 * The current choice of a session: the model, the request settings, and the working folder. It holds no credential
 * and no route.
 */
export type SessionSettings = { 
/**
 * The model of the next turn.
 */
model: ModelReference, 
/**
 * The request settings of the next turn.
 */
settings: Settings, 
/**
 * The folder that the tools of the session work in.
 */
cwd: string, };

/**
 * A session for a new viewer: its settings, and the updates that show it. The updates are its last saved events, its
 * state, its pending inputs, its running jobs, its MCP servers, and its open questions. The later updates follow it.
 */
export type SessionSnapshot = { 
/**
 * The settings of the session when the snapshot starts. A later change comes as a saved event.
 */
settings: SessionSettings, 
/**
 * The updates that show the session, in order.
 */
updates: Array<SessionUpdate>, };

/**
 * Whether a session runs a turn.
 */
export type SessionState = "running" | "idle";

/**
 * The saved facts of a session, as `session/list` and `session/get` give them.
 */
export type SessionSummary = { 
/**
 * The session.
 */
sessionId: SessionId, 
/**
 * The model of the newest settings.
 */
model: ModelReference, 
/**
 * The working folder of the newest settings.
 */
cwd: string, 
/**
 * The trimmed user text of the first message input with text, at most 200 characters. None before such an
 * input.
 */
preview?: string | null, 
/**
 * The creation time, in milliseconds since the Unix epoch.
 */
createdAt: number, 
/**
 * The time of the newest event, in milliseconds since the Unix epoch. A fork starts at its creation time.
 */
updatedAt: number, 
/**
 * The source of a fork. The source can be gone.
 */
forkOf?: SessionId | null, };

/**
 * A saved event or a temporary fact of a turn.
 */
export type SessionUpdate = StoredEvent | LiveUpdate;

/**
 * The settings of a request apart from its system prompt, its context, its tools, and its blobs. A caller can store
 * one for each session, and [`Request::settings`] applies it. It names no model and holds no secret.
 */
export type Settings = { 
/**
 * The output limit. `None` leaves the endpoint default.
 */
maxOutputTokens: number | null, 
/**
 * The reasoning settings.
 */
reasoning: ReasoningSettings, 
/**
 * The sampling temperature. `None` leaves the endpoint default.
 */
temperature: number | null, 
/**
 * The nucleus sampling mass. `None` leaves the endpoint default.
 */
topP: number | null, 
/**
 * The tool control.
 */
toolChoice: ToolChoice, 
/**
 * The schema of the response. `None` leaves the response free.
 */
outputSchema: OutputSchema | null, };

/**
 * One saved event of a session, with its event number. Its JSON holds the number as `seq` beside the fields of the
 * event.
 */
export type StoredEvent = { 
/**
 * The number of the event in its session.
 */
seq: EventNumber, } & ({ "sessionUpdate": "commit", 
/**
 * The commit, with its own blocks.
 */
commit: Commit, 
/**
 * The inputs that the commit consumed, in input order.
 */
consumed: Array<ConsumedInput>, } | { "sessionUpdate": "settings" } & SessionSettings);

/**
 * The argument of a call that its summary line shows.
 */
export type Subject = { 
/**
 * The name of a top-level string argument.
 */
argument: string, 
/**
 * What the value of the argument names.
 */
kind: SubjectKind, };

/**
 * What the subject argument names. A frontend can open a file or a URI.
 */
export type SubjectKind = "text" | "file" | "uri";

/**
 * Whether and how the model thinks before it answers.
 */
export type Thinking = "off" | { "adaptive": ThinkingDisplay | null } | { "budget": number };

/**
 * Whether a thinking block returns its summary text. Anthropic bills the full thinking either way.
 */
export type ThinkingDisplay = "summarized" | "omitted";

/**
 * A tool call of the assistant.
 */
export type ToolCall = { 
/**
 * The provider's call id.
 */
callId: string, 
/**
 * The tool name.
 */
name: string, 
/**
 * A JSON object text, written verbatim. An empty text writes `{}`. The caller checks it.
 */
arguments: string, };

/**
 * The tool controls every host understands.
 */
export type ToolChoice = "auto" | "none";

/**
 * A tool definition for the provider.
 */
export type ToolDefinition = { 
/**
 * The tool name.
 */
name: string, 
/**
 * What the tool does, for the model.
 */
description: string, 
/**
 * A JSON Schema object text, written verbatim. The caller checks it.
 */
inputSchema: string, 
/**
 * Exclude the definition from the prompt until a tool search names it. A request with a deferred tool asks for
 * the native tool search. The encoder refuses it for Chat Completions and for a target without
 * [`Target::tool_search`].
 */
deferLoading: boolean, };

/**
 * How a frontend shows the calls of a tool. The model never sees the hints.
 */
export type ToolHints = { 
/**
 * The name of the summary line in place of the tool name.
 */
title: string | null, 
/**
 * The argument of the call that the summary line shows.
 */
subject: Subject | null, 
/**
 * The part of the output that a folded call shows.
 */
preview: Preview, };

/**
 * The result of one tool call.
 */
export type ToolResult = { 
/**
 * The call this result answers.
 */
callId: string, 
/**
 * The result text.
 */
content: string, 
/**
 * The call failed.
 */
isError: boolean, 
/**
 * Attachments beside the text. Each protocol places them where its result shape allows.
 */
media?: Array<Media>, 
/**
 * The deferred tools this result loads. Anthropic references each one by name. Responses answers its search
 * with the declarations. A request that defers no tool writes only the text of the result.
 */
loaded?: Array<ToolDefinition>, };

/**
 * How a turn ended, in a form that a journal can save. A failure keeps the text of its error, and
 * [`crate::TurnError::Round`] gives the caller the error itself.
 */
export type TurnEnd = { "outcome": Outcome } | { "failed": string };

/**
 * Token counts of one attempt, in the convention of OpenAI: a total includes the parts named after it. A provider can
 * leave out a count. A missing count is not zero.
 */
export type Usage = { 
/**
 * Every prompt token, `cache_read` and `cache_write` among them.
 */
input: number | null, 
/**
 * Every generated token, `reasoning` among them.
 */
output: number | null, 
/**
 * The output tokens the model spent on reasoning.
 */
reasoning: number | null, 
/**
 * The input tokens read from the prompt cache.
 */
cacheRead: number | null, 
/**
 * The input tokens written to the prompt cache.
 */
cacheWrite: number | null, };
