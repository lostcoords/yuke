# yuke — the model-call boundary (auxiliary LLM calls)

Status: proposal.
Source of truth: `src/provider/` and future call tasks.
Last verified: 2026-08-31.

The engine must make LLM calls that are NOT a user turn: a session title from a small model, a pre-flight
tool-safety judge, summarize/compaction, and later a hook/tool/sub-agent call. Three research passes
(OpenCode/Crush/Goose, pi/Codex/Cline, fx/AI-SDK) converge on one design. yuke's decoupled provider layer is
the right foundation; it needs one new boundary above it.

## The decision: a `Call` beside the `Turn`

- A **Turn** commits a user message and an assistant message, streams, folds, and broadcasts. (Today's
  `run.zig`.)
- A **Call** invokes a model for an internal result. It reuses the SAME provider transport, serializers,
  reducers, drain/stream, limits, and cancellation. It does NOT reuse the turn transaction, the transcript
  commit, the assistant fold, or the `message.committed` broadcast.
- No system in the research has one universal application `generate()`. Each shares a low-level provider
  primitive and adds thin task wrappers (title, compaction, judge). yuke does the same.

## The `ModelCall` primitive

```zig
// Composes the existing seams; imports NO transcript, db, or broadcast.
pub const ModelCallRequest = struct {
    model: []const u8,          // a public model id; the resolver maps it to the upstream binding
    system: []const u8 = "",
    prompt: []const wire.content.ContentPart, // or a small message list; a direct builder, not the transcript
    max_output_tokens: u32,
    output: enum { text, json } = .text,      // json/structured for a judge or classifier
};
pub const ModelCallResult = struct { text: []const u8, usage: TokenUsage, finish: StopReason };

pub fn generate(arena, io, transport, request: ModelCallRequest) !ModelCallResult
```

- **Reuse:** build a request body (a direct prompt builder), serialize, `transport.open`, then collect text
  with `transport.stream` and a text-collecting callback. A separate lightweight fold, NOT `fold.assistant`
  (which rejects tool blocks and builds a full wire message).
- **Model per call:** resolve `request.model` through the existing `ModelBinding`/`findModel`. NEVER mutate
  the session's model. Model tiering (a configured small/fast model + a per-task override + fallback to the
  main model) belongs to the provider-config slice.
- **One-shot first:** expose `generate` as collect-to-text. The serializers force `"stream": true` today, so
  reuse the SSE path and collect only text and usage. Add non-streaming serializers later if needed.

## Result sinks (explicit, caller-owned)

- **Title:** write session metadata (a `setTitle`), NOT an assistant message. Schedule after the first
  committed user message, detached, off the response critical path; ignore its failure.
- **Safety judge (auto mode):** run deterministic policy FIRST. Then, only when needed, call a judge with the
  tool name, arguments, and limited context. Give it no tools or read-only tools. Require closed JSON. Enforce
  a deadline and an attempt limit. Fail CLOSED for safety.
- **Compaction:** use the existing `compaction` wire message and the `compaction` RunKind.
- **Sub-agent (later):** a child scope with its own call id, context, model, budget, depth, and cancellation.
  Nested calls disabled by default; add depth and concurrency limits.

## What yuke already has (we are on the right step)

- The transport seam (`ResponseBody` open/read/cancel/deinit), the request serializers, the stream reducers,
  `drain`/`stream`, and the response byte cap.
- `ModelBinding`/`findModel` for per-call model resolution.
- The `compaction` wire message type and RunKind.

## The missing pieces (small)

1. A `provider` `generate` primitive that composes the seams with no transcript/turn coupling.
2. A direct prompt builder (a request from a custom message list, not the stored transcript).
3. A text collector beside `drain` (the `transport.stream` text-callback covers this).
4. The provider-config slice for model tiering (the small model).
5. The first aux job: session title generation.

The `buildRequest` extraction planned for the streaming turn is the same shared seam this primitive needs, so
shape it as a general provider-call step, not a turn-only helper.
