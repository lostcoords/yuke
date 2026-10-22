// Generated from the protocol types by the bindings test of `yuke-protocol`. Do not edit.
// The types of the protocol that plugins use, as the clients of the protocol see them.

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
 * A named reasoning effort from the closed portable set.
 */
export type Effort = "minimal" | "low" | "medium" | "high" | "xhigh" | "max";

/**
 * Why a response ended. At `Length` a tool call can hold cut-off arguments, so do not run such a call.
 * `Pause` marks an Anthropic server-tool loop at its iteration cap. The same content resumes the loop.
 */
export type FinishReason = "stop" | "length" | "content_filter" | "refusal" | "tool_calls" | "pause" | "unknown";

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
 * The kind of provider state that a reasoning block must return verbatim. Each kind names the protocol that
 * produced the state. Only the encoder of that protocol writes it.
 */
export type ReplayKind = "anthropic_signature" | "anthropic_redacted" | "responses_encrypted" | "openrouter_details";

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
