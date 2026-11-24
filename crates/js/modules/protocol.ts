// Generated from the protocol types by the bindings test of `yuke-protocol`. Do not edit.
// The types of the protocol that plugins use, as the clients of the protocol see them.

/**
 * The params of `plugin/add`.
 */
export type AddPluginsParams = { 
/**
 * The URL of the repository, as `git` takes it.
 */
git: string, 
/**
 * The names of the plugins to add, as `plugin/find` gives them. Without them, the repository must have one plugin.
 */
names?: Array<string>, 
/**
 * The branch, tag, or commit that an update follows. Without it, an update follows the default branch.
 */
ref?: string, };

/**
 * The result of `plugin/add`.
 */
export type AddPluginsResult = { 
/**
 * The added plugins, in the order of the names.
 */
plugins: Array<AddedPlugin>, };

/**
 * One plugin that `plugin/add` added.
 */
export type AddedPlugin = { 
/**
 * The name of its `plugin.json`.
 */
name: string, 
/**
 * The full commit id in the lock.
 */
commit: string, };

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
 * The params of `plugin/apply`.
 */
export type ApplyPluginsParams = { 
/**
 * The new commits to write, as the `changes` of `plugin/check` give them. Each plugin must be in the lock.
 */
plugins: Array<LockedPlugin>, };

/**
 * Assistant text, and the phase that the provider gave it.
 */
export type AssistantText = { 
/**
 * The text.
 */
text: string, 
/**
 * The phase of the text, or no phase when the provider sent none. The encoder sends the phase back to OpenAI
 * Responses.
 */
phase?: TextPhase, };

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
 * The byte count of the content.
 */
len: number, };

/**
 * One block of the context. Its kind fixes its role, so it holds only content of that role.
 * yuke groups the blocks into the messages of each provider protocol.
 */
export type Block = { "kind": "userText", 
/**
 * The text.
 */
text: string, } | { "kind": "media" } & Media | { "kind": "toolResult" } & ToolResult | { "kind": "assistantText" } & AssistantText | { "kind": "reasoning" } & Reasoning | { "kind": "toolCall" } & ToolCall;

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
 * A block starts.
 */
export type BlockStarted = { 
/**
 * The block id.
 */
blockId: number, 
/**
 * What the block holds.
 */
content: StartedBlock, };

/**
 * A block stops. Reasoning signatures and encrypted replay data stay outside this update.
 */
export type BlockStopped = { 
/**
 * The block id.
 */
blockId: number, 
/**
 * The complete call of a tool block. Another block has none.
 */
call?: ToolCall, };

/**
 * The hints of one tool call of a commit, and its working folder.
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
 * The working folder of the call. A relative path of the call starts there.
 */
folder?: string, };

/**
 * The params of `plugin/check`.
 */
export type CheckPluginsParams = { 
/**
 * The plugins to check.
 */
target: PluginTarget, };

/**
 * The result of `plugin/check`.
 */
export type CheckPluginsResult = { 
/**
 * Each checked plugin whose ref moved. A plugin out of `changes` and `failed` is at the newest commit of its ref.
 */
changes: Array<PluginChange>, 
/**
 * Each plugin that the server could not check. The others have their check.
 */
failed: Array<FailedPlugin>, };

/**
 * The change of the context since the last commit, and the facts of the turn. Replay each commit in order on a copy
 * of the context: apply `replaced`, then append `blocks`. The copy then equals the context.
 */
export type Commit = { 
/**
 * The replacement of the context. A commit with a replacement holds no blocks.
 */
replaced?: Replaced, 
/**
 * The blocks after the saved blocks, in context order.
 */
blocks: Array<Block>, 
/**
 * The facts of the answer in `blocks`. A commit without an answer has none.
 */
answer?: Answer, 
/**
 * How the turn ended. A commit in the middle of a turn has none.
 */
end?: TurnEnd, 
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
 * The display of each tool result that has blocks or a duration, in block order.
 */
results: Array<ResultDisplay>, };

/**
 * A `commit` event: a commit of a turn, and the inputs that it consumed. The blocks of the commit start with the model
 * blocks of those inputs.
 */
export type CommitEvent = { 
/**
 * The commit, with its own blocks.
 */
commit: Commit, 
/**
 * The inputs that the commit consumed, in input order.
 */
consumed: Array<ConsumedInput>, };

/**
 * An input that a commit consumed. The commit starts with the model blocks of its consumed inputs, in input order.
 * This input has the next `blockCount` blocks.
 */
export type ConsumedInput = { 
/**
 * The id that the session gave the input when it accepted it.
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
 * The blocks that the user saw, only when they differ from the blocks that the model read. An empty list means
 * that the user saw nothing.
 */
displayContent?: Array<Block>, 
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
 * Replace the draft with blocks from the named saved commit. The array supplies source ids in destination order.
 */
export type DraftCommitted = { 
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
blocks: Array<number>, };

/**
 * Why a client must remove a draft without a confirmed saved replacement.
 */
export type DraftDiscardReason = "failed" | "unconfirmed";

/**
 * Remove a draft. This does not remove any saved history.
 */
export type DraftDiscarded = { 
/**
 * The draft to remove.
 */
draftId: DraftId, 
/**
 * Why the draft has no confirmed replacement.
 */
reason: DraftDiscardReason, };

/**
 * The ephemeral identity of one live provider attempt. The store never saves it.
 * A reconnect cannot resume this draft. The client replaces prior drafts with saved history.
 */
export type DraftId = string;

/**
 * A `model` update: one fact of the model in a draft. It holds no provider replay state.
 */
export type DraftModelUpdate = { 
/**
 * The draft of this fact.
 */
draftId: DraftId, 
/**
 * The model fact.
 */
event: ModelUpdate, };

/**
 * A provider attempt starts a new draft.
 */
export type DraftStarted = { 
/**
 * The identity of this attempt, distinct across turns and process restarts.
 */
draftId: DraftId, };

/**
 * A named reasoning effort from the portable set.
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
sessionId?: SessionId, 
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
 * The params of `extension/request`.
 */
export type ExtensionRequestParams = { 
/**
 * The session of the plugin.
 */
sessionId: SessionId, 
/**
 * The name that the host gives the plugin.
 */
extension: string, 
/**
 * The name of the request. The plugin chooses it.
 */
request: string, 
/**
 * The data of the request. The plugin chooses its shape.
 */
data: unknown, };

/**
 * A plugin that `plugin/check` could not check.
 */
export type FailedPlugin = { 
/**
 * The name of its `plugin.json`.
 */
name: string, 
/**
 * The reason of the failure.
 */
error: string, };

/**
 * The params of `plugin/find`.
 */
export type FindPluginsParams = { 
/**
 * The URL of the repository, as `git` takes it. yuke looks at its default branch.
 */
git: string, };

/**
 * The result of `plugin/find`.
 */
export type FindPluginsResult = { 
/**
 * The plugins of the repository, in the order of their folders.
 */
plugins: Array<FoundPlugin>, };

/**
 * Why a response ended. At `Length` a tool call can hold cut-off arguments, so do not run such a call.
 * `Pause` marks an Anthropic server-tool loop at its iteration cap. The same content resumes the loop.
 */
export type FinishReason = "stop" | "length" | "contentFilter" | "refusal" | "toolCalls" | "pause" | "unknown";

/**
 * One plugin of a repository: a folder with a `plugin.json`.
 */
export type FoundPlugin = { 
/**
 * The name of its `plugin.json`.
 */
name: string, 
/**
 * The folder in the repository. Without it, the plugin is the root.
 */
folder?: string, };

/**
 * An accepted input. It holds the blocks that the user saw, and other blocks for the model when they differ. The model
 * reads at least one block. An input with no content is hidden: the user sees nothing, a client shows nothing, and
 * the model reads the model content.
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
 * The blocks that the user saw. They are empty for a hidden input.
 */
content: Array<Block>, 
/**
 * The blocks that the model reads, only when they differ from the content.
 */
modelContent?: Array<Block>, };

/**
 * The session accepted an input. It is pending until a saved commit names it in `consumed`, or until an
 * `inputRemoved` update names it.
 */
export type InputAccepted = { 
/**
 * The id of the input.
 */
inputId: InputId, 
/**
 * The input.
 */
input: Input, };

/**
 * The id of a pending input. A store gives each input of a session a larger id than the inputs before it.
 */
export type InputId = number;

/**
 * What an input is. A client shows a message in the conversation, and a notification as a notice.
 */
export type InputKind = "message" | "notification";

/**
 * A pending input was removed. The model never reads it.
 */
export type InputRemoved = { 
/**
 * The id of the input.
 */
inputId: InputId, };

/**
 * Who sent an input. It records the sender only. It grants no permission and sets no visibility.
 */
export type InputSource = { "kind": "user" } | { "kind": "plugin", 
/**
 * The name of the plugin.
 */
name: string, };

/**
 * A question ended: the user answered it, its asker stopped waiting, or its session closed. The client removes it.
 */
export type InteractionClosed = { 
/**
 * The question.
 */
interactionId: InteractionId, };

/**
 * The id of a question. The server gives each question a larger id than the questions before it, in each session.
 */
export type InteractionId = number;

/**
 * A request to the user. A client shows it in its own way.
 */
export type InteractionRequest = { "kind": "questions", 
/**
 * The questions, in display order. The ids are unique. The labels of a question are unique, and each question
 * has an option or `other`.
 */
questions: Array<Question>, };

/**
 * A plugin or yuke asks the user a question. The client answers with `interaction/respond`. The question stays open
 * until an `interactionClosed` update names it.
 */
export type InteractionRequested = { 
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
request: InteractionRequest, };

/**
 * The response to a request. Its kind matches the kind of the request, or the user closed the request without an
 * answer.
 */
export type InteractionResponse = { "kind": "questions", 
/**
 * One answer per question, each with a value or `other`.
 */
answers: Array<QuestionAnswer>, } | { "kind": "cancelled" };

/**
 * A background job.
 */
export type Job = { 
/**
 * The id of the job.
 */
id: JobId, 
/**
 * A short text for display.
 */
label: string, 
/**
 * Whether the job runs, and how it ended.
 */
state: JobState, } & ({ "kind": "process", 
/**
 * The exact command.
 */
command: string, 
/**
 * The file that holds the output.
 */
log: string, 
/**
 * The exit code, when the process exited. An ended process without one did not exit by itself.
 */
exitCode?: number, } | { "kind": "plugin", 
/**
 * The name of the plugin.
 */
plugin: string, });

/**
 * The id of a background job, for example `job-1a2b`. A job id is unique among the jobs of one session.
 */
export type JobId = string;

/**
 * Whether a job runs, and how it ended.
 */
export type JobState = "running" | "ended" | "stopped";

/**
 * A `job` update: a background job of the session started or ended. The update holds the whole job, so a client
 * replaces its copy.
 */
export type JobUpdate = { 
/**
 * The job.
 */
job: Job, };

/**
 * The result of `catalog/list`.
 */
export type ListCatalogResult = { 
/**
 * The providers in catalog order: the built-in ones, then the additions of `providers.json`.
 */
providers: Array<ProviderInfo>, };

/**
 * The result of `plugin/list`.
 */
export type ListPluginsResult = { 
/**
 * The plugins in the order of `config.json`.
 */
plugins: Array<ManagedPlugin>, };

/**
 * The params of `session/list`.
 */
export type ListSessionsParams = { 
/**
 * Only the sessions whose newest settings name this folder. Without it, the list has the sessions of every folder.
 */
folder?: string, 
/**
 * Only the children of this session. Without it, the list has the sessions without a parent.
 */
parent?: SessionId, 
/**
 * The most rows of the page, from 1 to 100. The default is 50.
 */
limit?: number, 
/**
 * The `nextCursor` of the page before, with the same `folder` and `parent`. Without it, the page starts at the newest
 * session.
 */
cursor?: string, };

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
 * The cursor of the next page. It is absent when no older session exists.
 */
nextCursor?: string, };

/**
 * A live fact of a session. Saved events remain authoritative after reconnect. Each variant holds a type of the same
 * name, apart from `state`, `job`, and `model`.
 */
export type LiveUpdate = { "kind": "state" } & StateUpdate | { "kind": "job" } & JobUpdate | { "kind": "inputAccepted" } & InputAccepted | { "kind": "interactionRequested" } & InteractionRequested | { "kind": "interactionClosed" } & InteractionClosed | { "kind": "mcpServer" } & McpServer | { "kind": "inputRemoved" } & InputRemoved | { "kind": "turnUnconfirmed" } | { "kind": "draftStarted" } & DraftStarted | { "kind": "model" } & DraftModelUpdate | { "kind": "draftCommitted" } & DraftCommitted | { "kind": "draftDiscarded" } & DraftDiscarded | { "kind": "toolStarted" } & ToolStarted | { "kind": "toolOutput" } & ToolOutput | { "kind": "toolFinished" } & ToolFinished | { "kind": "retryScheduled" } & RetryScheduled | { "kind": "roundFailed" } & RoundFailed;

/**
 * A Git plugin and its commit in `plugins.lock`.
 */
export type LockedPlugin = { 
/**
 * The plugin.
 */
source: PluginSource, 
/**
 * The full commit id.
 */
commit: string, };

/**
 * The id of a login of `auth/login` or `mcp/login`. A server process gives each login a larger id than the logins
 * before it.
 */
export type LoginId = number;

/**
 * How a login ended.
 */
export type LoginOutcome = { "kind": "succeeded" } | { "kind": "cancelled" } | { "kind": "failed", 
/**
 * Why. The text holds no token.
 */
error: string, };

/**
 * The result of `auth/login`: the code that the user confirms on the page of the provider.
 */
export type LoginResult = { 
/**
 * The login. Its `auth/loginFinished` names it.
 */
loginId: LoginId, 
/**
 * The page where the user approves the login.
 */
verificationUrl: string, 
/**
 * The code that the user confirms on the page, or enters when the page asks.
 */
userCode: string, };

/**
 * One plugin of `config.json` in `plugin/list`.
 */
export type ManagedPlugin = { 
/**
 * The folder of a local plugin, or the source of a Git plugin.
 */
source: PluginOrigin, 
/**
 * The name of its `plugin.json`, when the server can read it.
 */
name?: string, 
/**
 * Its state on disk.
 */
state: PluginState, 
/**
 * Whether the running plugins hold it.
 */
load: PluginLoad, };

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
source: McpServerSource, 
/**
 * Its state.
 */
state: McpServerState, };

/**
 * The config file of an MCP server.
 */
export type McpServerSource = "user" | "project";

/**
 * The state of one MCP server of a session.
 */
export type McpServerState = { "kind": "connecting" } | { "kind": "connected", 
/**
 * The number of its tools.
 */
tools: number, } | { "kind": "failed", 
/**
 * Why.
 */
error: string, } | { "kind": "disabled" } | { "kind": "untrusted" } | { "kind": "needsLogin" };

/**
 * One attachment. Its media type selects the block each protocol writes.
 */
export type Media = { 
/**
 * The bytes in the store of the session. A request reads them only when it sends the
 * element.
 */
blob: Blob, 
/**
 * The IANA media type, such as `image/png` or `application/pdf`.
 */
mimeType: string, 
/**
 * The name a provider requires beside file bytes. An image needs none.
 */
filename?: string, };

/**
 * A kind of content: what an attachment holds, and what a model reads or writes. `Other` is a media type that no
 * protocol names, and no model lists.
 */
export type Modality = "text" | "image" | "audio" | "video" | "pdf" | "other";

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
 * The context window in tokens. It is absent when the catalog does not know it.
 */
contextWindow?: number, 
/**
 * The output limit in tokens. It is absent when the catalog does not know it.
 */
maxOutputTokens?: number, 
/**
 * The reasoning choices of the model, each with the settings that a session sends for it.
 */
reasoning: Array<ReasoningChoice>, 
/**
 * The price bands in threshold order. The last band that the prompt reaches prices the whole request.
 */
cost: Array<PriceBand>, 
/**
 * Whether the model calls tools. It is absent when the catalog does not know it.
 */
tools?: boolean, 
/**
 * Whether the model takes deferred tools. It is absent when the catalog does not know it.
 */
toolSearch?: boolean, 
/**
 * The kinds of content that the model reads. Empty when the catalog does not know them. It never lists `other`.
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
 * A fact of the model in a draft. Block ids belong to one draft and follow block start order. Each variant holds a
 * type of the same name.
 */
export type ModelUpdate = { "kind": "blockStarted" } & BlockStarted | { "kind": "textDelta" } & TextDelta | { "kind": "refusalDelta" } & RefusalDelta | { "kind": "reasoningDelta" } & ReasoningDelta | { "kind": "reasoningSectionStarted" } & ReasoningSectionStarted | { "kind": "toolInputDelta" } & ToolInputDelta | { "kind": "blockStopped" } & BlockStopped | { "kind": "responseCompleted" } & ResponseCompleted;

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
sessionId?: SessionId, 
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
text: string, };

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
 * The new commit of one Git plugin whose ref moved.
 */
export type PluginChange = { 
/**
 * The name of its `plugin.json`.
 */
name: string, 
/**
 * The plugin.
 */
source: PluginSource, 
/**
 * The commit of the lock.
 */
old: string, 
/**
 * The commit that its ref names now. It is installed.
 */
new: string, 
/**
 * The commits of the move.
 */
log: PluginLog, };

/**
 * Whether the running plugins hold one plugin of `plugin/list`.
 */
export type PluginLoad = { "kind": "loaded" } | { "kind": "pending" } | { "kind": "failed", 
/**
 * Why, with the name of the plugin.
 */
error: string, };

/**
 * The commits between the locked commit and the new one, or why the server cannot read them.
 */
export type PluginLog = { "kind": "commits", 
/**
 * Newest first, as a short id and a subject each.
 */
commits: Array<string>, } | { "kind": "failed", 
/**
 * Why.
 */
error: string, };

/**
 * Where a plugin of `config.json` comes from: a local folder, or a Git plugin. JSON holds a folder as a string, and a
 * Git plugin as its `PluginSource` object.
 */
export type PluginOrigin = string | PluginSource;

/**
 * A Git plugin of `config.json`, as `plugins.lock` keys it.
 */
export type PluginSource = { 
/**
 * The URL of the repository, as `git` takes it.
 */
git: string, 
/**
 * The plugin folder in the repository. Without it, the plugin is the root.
 */
folder?: string, 
/**
 * The branch, tag, or commit that an update follows. Without it, an update follows the default branch.
 */
ref?: string, };

/**
 * The state on disk of one plugin of `plugin/list`.
 */
export type PluginState = { "kind": "local" } | { "kind": "notInstalled" } | { "kind": "installed", 
/**
 * The full commit id of the lock.
 */
commit: string, };

/**
 * Which Git plugins `plugin/check` checks: each one, or the ones with these names in their `plugin.json`.
 */
export type PluginTarget = { "kind": "all" } | { "kind": "names", 
/**
 * The names.
 */
names: Array<string>, };

/**
 * The part of the output that a folded call shows. An error always shows its first rows.
 */
export type Preview = "head" | "tail" | "none";

/**
 * The prices of one band, in US dollars per million tokens. A missing price is unknown, and never zero.
 */
export type PriceBand = { 
/**
 * The smallest prompt this band prices. The prompt counts every input token, the cached ones too.
 */
minPromptTokens: number, 
/**
 * The price of an input token.
 */
input?: number, 
/**
 * The price of an output token.
 */
output?: number, 
/**
 * A reasoning token is also an output token. This price replaces the output price for it.
 */
reasoning?: number, 
/**
 * The price of a token read from the prompt cache.
 */
cacheRead?: number, 
/**
 * The price of a token written to the prompt cache.
 */
cacheWrite?: number, };

/**
 * The credential that a ready provider uses.
 */
export type ProviderCredential = { "kind": "none" } | { "kind": "variable", 
/**
 * The name of the environment variable.
 */
name: string, } | { "kind": "storedApiKey" } | { "kind": "login" };

/**
 * A provider and its models. The `id` of the provider and the `id` of a model make the
 * `ModelReference` of a session.
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
 * Whether the provider can serve a request.
 */
state: ProviderState, 
/**
 * The models in catalog order. Empty when the provider is not ready.
 */
models: Array<ModelInfo>, };

/**
 * Whether a provider can serve a request. The server checks that the credential is there. It does not test the
 * credential.
 */
export type ProviderState = { "kind": "ready", 
/**
 * The credential that a request uses.
 */
credential: ProviderCredential, } | { "kind": "needsApiKey", 
/**
 * The name of the environment variable.
 */
variable: string, } | { "kind": "needsLogin" };

/**
 * One question of a request.
 */
export type Question = { 
/**
 * The id that the answer names.
 */
id: string, 
/**
 * A short name of the question.
 */
header: string, 
/**
 * The question. It can have more than one line.
 */
question: string, 
/**
 * The options, in display order. Without options and with `other`, the question is a text field.
 */
options: Array<QuestionOption>, 
/**
 * The user can choose more than one option. A missing flag is `false`.
 */
multiple?: boolean, 
/**
 * The user can type an answer of their own. A missing flag is `false`.
 */
other?: boolean, 
/**
 * The text field hides what the user types, as for a password. Only a question without options has it. A missing
 * flag is `false`.
 */
secret?: boolean, };

/**
 * The answer to one question.
 */
export type QuestionAnswer = { 
/**
 * The id of the question.
 */
id: string, 
/**
 * The labels of the chosen options. A question without `multiple` has at most one.
 */
values: Array<string>, 
/**
 * The text that the user typed, only for a question with `other`.
 */
other?: string, };

/**
 * One option of a question.
 */
export type QuestionOption = { 
/**
 * The text of the option, which the answer names.
 */
label: string, 
/**
 * More text about the option.
 */
description?: string, };

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
 * Absent for text alone: a block that never finished, or one whose provider sent no state.
 */
replay?: ReasoningReplay, };

/**
 * A reasoning level that a user can pick for a model, and the reasoning settings that a session sends for it.
 */
export type ReasoningChoice = { 
/**
 * The level.
 */
level: ReasoningSelection, 
/**
 * The reasoning settings that a session sends for this level, as the `reasoning` of its settings.
 */
settings: ReasoningSettings, };

/**
 * Reasoning text arrives.
 */
export type ReasoningDelta = { 
/**
 * The block id.
 */
blockId: number, 
/**
 * The new text.
 */
text: string, };

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
 * A reasoning section starts.
 */
export type ReasoningSectionStarted = { 
/**
 * The block id.
 */
blockId: number, };

/**
 * What a user selects for the reasoning of a model: the default of the endpoint, no reasoning, or an effort. JSON
 * holds each selection as its name: `default`, `off`, or the name of the effort.
 */
export type ReasoningSelection = "default" | "off" | Effort;

/**
 * The reasoning one request asks for, as the caller chose it for the model. Each serializer writes the settings its
 * protocol has.
 */
export type ReasoningSettings = { 
/**
 * Whether and how the model thinks. Without it, the endpoint default applies.
 */
thinking?: Thinking, 
/**
 * How hard the model thinks. Without it, the endpoint default applies.
 */
effort?: Effort, };

/**
 * Refusal text arrives.
 */
export type RefusalDelta = { 
/**
 * The block id.
 */
blockId: number, 
/**
 * The new text.
 */
text: string, };

/**
 * The params of `plugin/remove`.
 */
export type RemovePluginParams = { 
/**
 * The name of the `plugin.json` of the plugin, a Git plugin or a local one.
 */
name: string, };

/**
 * A new context: `head`, then the last `keep` blocks of the old context. A compaction gives a summary and the recent
 * blocks. Another rewrite gives the whole new context as `head` and keeps nothing. A hook asks for one in a
 * `RoundPlan`, and a `Commit` saves it.
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
export type ReplayKind = "anthropicSignature" | "anthropicRedacted" | "responsesEncrypted" | "openrouterDetails";

/**
 * The settings of a request apart from its system prompt, its context, its tools, and its blobs. A caller can store
 * one for each session. It names no model and holds no secret.
 */
export type RequestSettings = { 
/**
 * The output limit. Without it, the endpoint default applies.
 */
maxOutputTokens?: number, 
/**
 * The reasoning settings.
 */
reasoning: ReasoningSettings, 
/**
 * The sampling temperature. Without it, the endpoint default applies.
 */
temperature?: number, 
/**
 * The nucleus sampling mass. Without it, the endpoint default applies.
 */
topP?: number, 
/**
 * The tool control.
 */
toolChoice: ToolChoice, 
/**
 * The schema of the response. Without it, the response is free.
 */
outputSchema?: OutputSchema, };

/**
 * The response completes. This does not end its turn or confirm a durable save.
 */
export type ResponseCompleted = { 
/**
 * The normalized finish reason.
 */
finishReason: FinishReason, 
/**
 * The finish reason of the provider.
 */
rawFinishReason: string, 
/**
 * The token counts of the provider.
 */
usage: Usage, };

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
blocks: Array<DisplayBlock>, 
/**
 * The duration of the tool in milliseconds, without the hooks. A call that did not run has no duration.
 */
durationMs?: number, };

/**
 * An attempt failed. The same request follows after a wait.
 */
export type RetryScheduled = { 
/**
 * The wait in milliseconds.
 */
afterMs: number, 
/**
 * The failure text.
 */
error: string, };

/**
 * A round failed after its retries.
 */
export type RoundFailed = { 
/**
 * The failure text with each cause.
 */
error: string, };

/**
 * The id of a session: a version 7 UUID, so the ids sort by the millisecond of their creation.
 */
export type SessionId = string;

/**
 * A saved session with its facts and its state at the moment of the answer.
 */
export type SessionRow = { 
/**
 * Whether the session is open in this server, and whether a turn runs in it.
 */
state: SessionState, 
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
folder: string, 
/**
 * The display title from a message, an explicit rename, or a fork of a titled session.
 */
title?: SessionTitle, 
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
forkOf?: SessionId, 
/**
 * The parent session. A removal of the parent removes this session.
 */
parent?: SessionId, };

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
settings: RequestSettings, 
/**
 * The folder that the tools of the session work in.
 */
folder: string, };

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
 * Whether a session is open in the server, and whether a turn runs in it. A `state` update of an open session is
 * `idle` or `running`.
 */
export type SessionState = "closed" | "idle" | "running";

/**
 * A non-empty session title with normalized whitespace and at most 200 Unicode scalar values.
 */
export type SessionTitle = string;

/**
 * A saved event or a temporary fact of a turn.
 */
export type SessionUpdate = StoredEvent | LiveUpdate;

/**
 * The params of `auth/setApiKey`.
 */
export type SetApiKeyParams = { 
/**
 * The id of a provider with an API key variable, as `catalog/list` gives it.
 */
provider: string, 
/**
 * The API key. It is not empty.
 */
apiKey: string, };

/**
 * What a block holds when it starts. A refusal is the text of a model that declined the request.
 */
export type StartedBlock = { "kind": "text" } | { "kind": "refusal" } | { "kind": "reasoning" } | { "kind": "toolCall", 
/**
 * The name of the tool, or an empty name when the provider has not named it yet. The block stop gives
 * the final call.
 */
name: string, };

/**
 * A `state` update: the session starts or ends a turn.
 */
export type StateUpdate = { 
/**
 * Whether a turn runs.
 */
state: SessionState, };

/**
 * One saved event of a session, with its event number. Its JSON holds the number as `seq` beside the fields of the
 * event.
 */
export type StoredEvent = { 
/**
 * The number of the event in its session.
 */
seq: EventNumber, } & ({ "kind": "commit" } & CommitEvent | { "kind": "settings" } & SessionSettings);

/**
 * The argument of a call that its head line shows.
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
 * The result of `plugin/sync`.
 */
export type SyncPluginsResult = { 
/**
 * Whether `plugins.lock` changed.
 */
written: boolean, };

/**
 * Answer text arrives.
 */
export type TextDelta = { 
/**
 * The block id.
 */
blockId: number, 
/**
 * The new text.
 */
text: string, };

/**
 * The place of assistant text in its turn. The names come from OpenAI Responses, which asks each request to send
 * the phase of each earlier output item back.
 */
export type TextPhase = "commentary" | "finalAnswer";

/**
 * Whether and how the model thinks before it answers.
 */
export type Thinking = { "kind": "off" } | { "kind": "adaptive", 
/**
 * Whether a thinking block returns its summary text. Without it, the endpoint default applies.
 */
display?: ThinkingDisplay, } | { "kind": "budget", 
/**
 * The most thinking tokens.
 */
tokens: number, };

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
 * the native tool search. A request fails for Chat Completions and for a target without the
 * native tool search.
 */
deferLoading: boolean, };

/**
 * A tool ends. Its result stays provisional until a saved commit confirms it. A `turnUnconfirmed` update discards it.
 */
export type ToolFinished = { 
/**
 * The position of the saved call.
 */
position: BlockPosition, 
/**
 * The result of the call.
 */
result: ToolResult, 
/**
 * What a frontend shows in place of the result text. The model never sees it.
 */
display: Array<DisplayBlock>, 
/**
 * The duration of the tool in milliseconds, without the hooks. A call that did not run has no duration.
 */
durationMs?: number, };

/**
 * How a frontend shows the calls of a tool. The model never sees the hints.
 */
export type ToolHints = { 
/**
 * The name that the head line shows in place of the tool name.
 */
title?: string, 
/**
 * The argument of the call that the head line shows.
 */
subject?: Subject, 
/**
 * The part of the output that a folded call shows.
 */
preview: Preview, };

/**
 * A fragment of tool arguments arrives. The final arguments come with the block stop.
 */
export type ToolInputDelta = { 
/**
 * The block id.
 */
blockId: number, 
/**
 * The argument fragment, which need not be valid JSON alone.
 */
text: string, };

/**
 * A tool emits temporary output that the model does not receive.
 */
export type ToolOutput = { 
/**
 * The position of the saved call.
 */
position: BlockPosition, 
/**
 * The new output text.
 */
text: string, };

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
 * The driver handles a saved call. A denied call also has this update.
 */
export type ToolStarted = { 
/**
 * The position of the saved call, even when the provider repeats its call id.
 */
position: BlockPosition, 
/**
 * The call after yuke resolves a deferred tool. Its call id stays the id of the provider.
 */
call: ToolCall, };

/**
 * How a turn ended, in a form that a journal can save. A failure keeps the text of its error.
 */
export type TurnEnd = { "kind": "completed", 
/**
 * The reason in the closed set.
 */
finishReason: FinishReason, } | { "kind": "stopped" } | { "kind": "cancelled" } | { "kind": "failed", 
/**
 * Why.
 */
error: string, };

/**
 * Token counts of one attempt, in the convention of OpenAI: a total includes the parts named after it. A provider can
 * leave out a count. A missing count is not zero.
 */
export type Usage = { 
/**
 * Every prompt token, `cache_read` and `cache_write` among them.
 */
input?: number, 
/**
 * Every generated token, `reasoning` among them.
 */
output?: number, 
/**
 * The output tokens the model spent on reasoning.
 */
reasoning?: number, 
/**
 * The input tokens read from the prompt cache.
 */
cacheRead?: number, 
/**
 * The input tokens written to the prompt cache.
 */
cacheWrite?: number, };
