/*
package wire is the authoritative Odin representation of the yuke wire protocol
(version 1): the types, their JSON encoding and decoding, validation, and the
closed registries of method and broadcast names. Wire values are non-owning and
borrow the decoder's allocator; data that escapes a frame is deep-copied via a
type's `*_clone(value, allocator)` procedure. The codec is streaming and
token-based (no intermediate value tree), and the closed sets — methods,
broadcasts, union arms, enum values — stay closed.

The package is layered as:

  - `constants.odin`: `PROTOCOL_VERSION`, `LIMITS`, and `CLOSE` — the protocol
    version, shared bounds, and close codes.
  - `ids.odin`: identifier types. Global durable ids (session, workspace, job,
    rule) are fixed 16-byte lowercase hex; session-scoped ids (message, run,
    input, …) are `u64` identity keys, not indices.
  - `common.odin`: request-failure `Error_Code` and the `Error_Object` carried
    by a failed response.
  - `frames.odin`: the top-level frame shells — `Client_Frame` (`client.hello`
    or `request`), and the server `Response` / `Broadcast` / `hello`. Each
    shell emits its discriminator first.
  - `methods.odin`: the closed `Method_Name` enum and the typed
    `Request_Params` / `Response_Result` unions keyed off it.
  - `broadcasts.odin`: the closed `Broadcast_Name` enum, the `Broadcast_Data`
    union, and `broadcast_name_class` — the source of truth for sequencing,
    subscription gating, and droppability.
  - `json.odin`: the discriminator-first `Emitter` and the field writers shared
    by every `*_emit`.
  - `stream.odin`: the streaming `Decoder` front end. Tagged readers scan for a
    discriminator and rewind so member order is insignificant; `dec_skip`
    discards unknown fields or unmaterialized payloads without building a tree.
  - `validate.odin`: `Validation_Error` and the `@bounded` / `@fixed` length
    and cross-field checks shared by every `*_validate`.
  - Domain shape files — `client_hello.odin`, `server_hello.odin`,
    `catalog.odin`, `session.odin`, `transcript.odin`, `run.odin`,
    `content.odin`, `input.odin`, `tool` state, `permission.odin`,
    `workspace.odin`, `cron.odin`, `notice.odin`, `view.odin` — each holds the
    types, `*_emit`, `*_from_reader`, `*_validate`, and `*_clone` for one area
    of the protocol.
*/

package wire
