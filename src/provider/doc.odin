/*
The provider package defines connections and neutral streaming semantics for
yuke's closed provider-protocol set. The turn driver runs over
`libs:bindings/curl` and `libs:http/sse` and supports every wire protocol:
Anthropic Messages, OpenAI Chat, and OpenAI Responses, each with its own request
builder and streaming decoder.

Boundaries. Model selection, catalog lookup, and profile resolution happen
above the transport and are invisible here. So does retry execution: a turn is
single-attempt, and the engine drives the pure policy (`retry_backoff`,
`error_retryable`) with its own counter, timer, and cancel check.

Lifecycle. A Client and every Running or Completing Turn are address-pinned on
one nbio loop. Curl callbacks only parse and queue. A zero-delay nbio operation
delivers `on_event` after curl leaves its callback region, so the engine may
cancel from an event callback. Curl completion waits for queued events to drain;
then turn storage is released before `on_done`, allowing immediate Turn reuse.
Synchronous start failure and caller cancellation are silent.

Allocation. Turn memory lives in two OS-backed virtual arenas. `retained` holds
everything that outlives one SSE event — decoder-retained strings, the event
queue, the error-body prefix — and is freed once at turn cleanup. `scratch`
holds one decode or status classification at a time; each use is an `Arena_Temp`
watermark rewound after the call, reusing committed pages across events. `scratch`
never aliases `retained`: a kept string is cloned into `retained` before its
scratch tree is rewound. Every proc taking an `allocator` allocates into it and
frees nothing; the owner reclaims in bulk.

Borrowing. Every `Stream_Event` string borrows the turn's `retained` arena the
decoder wrote it into; the engine clones whatever it persists from `on_event`.
Cancellation from that callback defers arena teardown until the callback returns.

Replay. Anthropic request projection preserves assistant-part order and replays
signed thinking and opaque redacted thinking all-or-nothing, only when the
originating protocol and resolved model match the new request; empty signed
thinking text is still emitted. Tool results become leading blocks of the
following provider user message.

Errors. Peer-supplied HTTP status and `curl.Code` are never asserted on.
Non-2xx bodies are never fed to SSE; classification retains at most
`MAX_ERROR_BODY_BYTES` and stops curl after the prefix without losing the HTTP
status. Assertions guard our own resolved state; configuration values such as
an empty resolved credential fail the turn as `.Invalid_Request` instead.
*/

package provider
