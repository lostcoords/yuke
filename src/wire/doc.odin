/*
package wire is the authoritative Odin representation of the yuke wire protocol
(version 1): the types, their JSON encoding and decoding, validation, and the
closed registries of method and broadcast names. Wire values are non-owning and
borrow the decoder's allocator; data that escapes a frame is deep-copied via a
type's `*_clone(value, allocator)` procedure. The codec is streaming and
token-based (no intermediate value tree), and the closed sets — methods,
broadcasts, union arms, enum values — stay closed.

Framing is JSON-RPC 2.0. `jsonrpc: "2.0"` is validated on decode and written
from `JSONRPC_VERSION` on emit, so it is never stored on a frame type; envelope
emit order is `jsonrpc`, `id`, then `method`/`result`/`error`, and decoding is
order-insensitive. Requests and broadcasts share one `method` namespace;
broadcasts are notifications (no `id`), so nothing replies to them. Batching is
not supported, and the daemon never sends a request to the client — the one
interaction needing an answer, permission, is a notification plus a
client-originated `permission.decide`. Everything JSON-RPC leaves unspecified —
ordering, replay, subscription gating, droppability — is ours: see `Seq`,
`session.resync`, and `broadcast_name_class`.

Two deliberate deviations from the spec. A malformed frame closes the connection
with `CLOSE.protocol_error` instead of drawing a `-32600` response. And a
duplicated *envelope* member is `.Bad_Frame_Type`, where the spec is silent:
last-wins would let a peer and an intermediary disagree about which `id` or
`method` is authoritative. Payload readers stay last-wins, because the envelope
is the only place that disagreement can happen.

The package is layered as:

  - `constants.odin`: `PROTOCOL_VERSION`, `LIMITS`, and `CLOSE` — the protocol
    version, shared bounds, and close codes.
  - `ids.odin`: identifier types. Global durable ids (session, workspace, job,
    rule) are fixed 16-byte lowercase hex; session-scoped ids (message, run,
    input, …) are `u64` identity keys, not indices. `Request_Id` is the opaque
    verbatim JSON token of a correlation id, echoed unparsed.
  - `common.odin`: request-failure `Error_Code`, its durable JSON-RPC `code`
    numbers, and the `Error_Object` carried by a failed response.
  - `frames.odin`: the top-level frame shells — `Request`, `Response`
    (`result` xor `error`), and `Notification` — plus the streaming header scan
    that classifies a server frame by which members are present.
  - `methods.odin`: the closed `Method_Name` enum and the typed
    `Request_Params` / `Response_Result` unions keyed off it.
  - `broadcasts.odin`: the closed `Broadcast_Name` enum, the `Broadcast_Data`
    union, and `broadcast_name_class` — the source of truth for sequencing,
    subscription gating, and droppability.
  - `json.odin`: the discriminator-first `Emitter` and the field writers shared
    by every `*_emit`. One encoding serves both the client protocol and the
    daemon's event log, so a stored row re-emitted for a client is byte-identical.
  - `stream.odin`: the streaming `Decoder` front end. Tagged readers scan for a
    discriminator and rewind so member order is insignificant; `dec_skip`
    discards unknown fields or unmaterialized payloads without building a tree.
  - `validate.odin`: `Validation_Error` and the `@bounded` / `@fixed` length
    and cross-field checks shared by every `*_validate`.
  - Domain shape files — `initialize.odin`, `catalog.odin`, `session.odin`,
    `transcript.odin`, `run.odin`,
    `content.odin`, `input.odin`, `tool` state, `permission.odin`,
    `workspace.odin`, `cron.odin`, `notice.odin`, `view.odin` — each holds the
    types, `*_emit`, `*_from_reader`, `*_validate`, and `*_clone` for one area
    of the protocol.
*/

package wire
