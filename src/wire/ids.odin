package wire
import "libs:json"

import "core:strconv"

// @fixed 16
// 16 lowercase hex chars. Doubles as an on-disk directory name.
Session_Id :: distinct [16]u8

// @fixed 16
// 16 lowercase hex chars. Doubles as an on-disk directory name.
Workspace_Id :: distinct [16]u8

// @fixed 16
// 16 lowercase hex chars. Doubles as an on-disk record name.
Job_Id :: distinct [16]u8

// @fixed 16
// 16 lowercase hex chars. Identifies one remembered permission rule.
Rule_Id :: distinct [16]u8

// @fixed 32
// 32 lowercase hex chars. Identifies one daemon-owned OAuth login attempt.
Login_Id :: distinct [32]u8

// @bounded MAX_REQUEST_ID_BYTES
// Correlation id as its verbatim JSON token — `7`, `"abc"` with quotes, or `null`.
// Opaque: JSON-RPC requires the response id to equal the request id.
Request_Id :: distinct string

// Session-scoped, daemon-minted, strictly increasing, never reused.
Message_Id :: distinct u64

// Session-scoped, daemon-minted, strictly increasing, never reused.
Run_Id :: distinct u64

// Session-scoped, daemon-minted, strictly increasing, never reused.
Input_Id :: distinct u64

// Part ordinal in message.content[], from 0. JSON number on the wire, like the
// other session-scoped ids.
Part_Id :: distinct u64

// Per-session monotonic sequence number on durable broadcasts.
Seq :: distinct u64

// Monotonic compact-session-index revision within one daemon lifetime.
Session_Revision :: distinct u64

// Monotonic cron-index revision within one daemon lifetime.
Cron_Revision :: distinct u64

// Monotonic run-config revision within a session.
Config_Rev :: distinct u64

// Format an originated numeric id into `buf`, returning the token that borrows it.
// `buf` must outlive the returned id; a 20-byte buffer holds any u64.
req_id :: proc(n: u64, buf: []u8) -> Request_Id {
    assert(len(buf) >= 20, "request id buffer must hold any u64")
    assert(n <= MAX_REQUEST_ID, "originated request ids stay in the JSON safe integer range")

    return Request_Id(strconv.write_uint(buf, n, 10))
}

// Parse an id token back to the number we originated; `ok` is false if it is not a
// bare integer we could have issued. An over-long token would wrap `parse_i64`.
req_id_to_u64 :: proc(id: Request_Id) -> (n: u64, ok: bool) {
    if len(id) > json.MAX_INTEGER_TOKEN_DIGITS do return 0, false

    i, parsed := strconv.parse_i64(string(id))

    if !parsed || i < 0 || i > MAX_REQUEST_ID do return 0, false

    return u64(i), true
}

// Verify the token is one of JSON-RPC's permitted id forms and within its bound.
req_id_validate :: proc(id: Request_Id) -> Validation_Error {
    s := string(id)

    if len(s) == 0 do return .Mismatched_Payload

    enforce_bounded(MAX_REQUEST_ID_BYTES, s) or_return

    if s[0] == '"' {
        if len(s) < 2 || s[len(s) - 1] != '"' do return .Mismatched_Payload

        return .None
    }

    if s == "null" do return .None

    // Must parse in full: the lexer accepts `1e`, which would echo as malformed JSON.
    if _, ok := strconv.parse_f64(s); !ok do return .Mismatched_Payload

    return .None
}

// Write an id field verbatim, so the echo is byte-identical.
field_request_id :: proc(e: ^json.Emitter, name: string, id: Request_Id) {
    assert(req_id_validate(id) == .None, "emitted a correlation id that is not valid JSON")
    json.key(e, name)
    json.val_raw(e, string(id))
}
