// The control-plane codec: pure JSON building and parsing for the yuke-cloud device API
// (`docs/relay-control-plane.md`). The daemon fetches link tickets, the client fetches
// connect tickets, and `yuke login` runs the device-code enrollment. This file is only the
// message shapes; the curl transport and the poll/retry loop live in the caller, so the
// codec is testable without a network.
package relay

import "core:encoding/base64"
import "core:encoding/json"

// Why a control-plane message could not be built or parsed.
Control_Error :: enum {
    // No error.
    None,

    // The response JSON is not the shape this contract defines.
    Malformed,

    // A body could not be allocated.
    Out_Of_Memory,
}

// The bearer scheme presented on every device-authed control-plane call.
BEARER_PREFIX :: "Bearer "

// POST /api/v1/device_codes request body. The static public key is base64 — an opaque string
// to the control plane, decoded back to 32 bytes by whoever pins it from the roster.
@(private = "file")
Enroll_Start_Body :: struct {
    name:              string `json:"name"`,
    platform:          string `json:"platform"`,
    static_public_key: string `json:"static_public_key"`,
}

// The 201 response to device_codes: what the human needs, plus how to poll.
Enroll_Start :: struct {
    device_code:               string `json:"device_code"`,
    user_code:                 string `json:"user_code"`,
    verification_uri:          string `json:"verification_uri"`,
    verification_uri_complete: string `json:"verification_uri_complete"`,
    expires_in:                int `json:"expires_in"`,
    interval:                  int `json:"interval"`,
}

// A device_codes/token poll outcome, decided by HTTP status.
Enroll_Poll :: enum {
    // 428: waiting for browser approval; poll again after `interval`.
    Pending,

    // 201: approved; `Enroll_Credential` is set.
    Approved,

    // 403: the human denied the enrollment.
    Denied,

    // 400/expired/unknown: start over.
    Expired,
}

// The credential minted on approval. Strings owned by the decode allocator.
Enroll_Credential :: struct {
    device_id:  string `json:"device_id"`,
    credential: string `json:"credential"`,
    relay_url:  string `json:"relay_url"`,
}

// A relay ticket response (`link_tickets`/`connect_tickets`). Strings owned by the decode
// allocator; `expires_at` is left as its ISO-8601 string for the caller to interpret.
Control_Ticket :: struct {
    ticket:     string `json:"ticket"`,
    relay_url:  string `json:"relay_url"`,
    expires_at: string `json:"expires_at"`,
}

// POST /api/v1/connect_tickets request body.
@(private = "file")
Connect_Body :: struct {
    device_id: string `json:"device_id"`,
}

// Encode a device_codes start request. `static_public_key` is the raw 32-byte X25519 public
// key, base64-encoded into the body.
enroll_start_encode :: proc(
    name: string,
    platform: string,
    static_public_key: []u8,
    allocator := context.allocator,
) -> (
    []u8,
    Control_Error,
) {
    assert(len(static_public_key) == NOISE_STATIC_KEY_SIZE, "enroll needs a 32-byte public key")

    encoded := base64.encode(static_public_key, base64.ENC_TABLE, context.temp_allocator)
    body := Enroll_Start_Body {
        name              = name,
        platform          = platform,
        static_public_key = encoded,
    }

    out, err := json.marshal(body, {}, allocator)
    if err != nil {
        return nil, .Out_Of_Memory
    }

    return out, .None
}

// Decode the 201 device_codes response.
enroll_start_decode :: proc(body: []u8, allocator := context.allocator) -> (Enroll_Start, Control_Error) {
    out: Enroll_Start
    if json.unmarshal(body, &out, .JSON, allocator) != nil {
        return {}, .Malformed
    }

    if out.device_code == "" || out.user_code == "" || out.verification_uri == "" || out.interval <= 0 {
        return {}, .Malformed
    }

    return out, .None
}

// Decode a device_codes/token poll by its HTTP status: 201 approved (with the credential),
// 428 pending, 403 denied, anything else (400/expired/invalid) start over.
enroll_poll_decode :: proc(
    status: int,
    body: []u8,
    allocator := context.allocator,
) -> (
    Enroll_Poll,
    Enroll_Credential,
    Control_Error,
) {
    switch status {
    case 201:
        cred: Enroll_Credential
        if json.unmarshal(body, &cred, .JSON, allocator) != nil {
            return .Expired, {}, .Malformed
        }

        if cred.device_id == "" || cred.credential == "" || cred.relay_url == "" {
            return .Expired, {}, .Malformed
        }

        return .Approved, cred, .None

    case 428:
        return .Pending, {}, .None

    case 403:
        return .Denied, {}, .None
    }

    return .Expired, {}, .None
}

// Encode a connect_tickets request body for `device_id`.
connect_ticket_encode :: proc(device_id: string, allocator := context.allocator) -> ([]u8, Control_Error) {
    out, err := json.marshal(Connect_Body{device_id = device_id}, {}, allocator)
    if err != nil {
        return nil, .Out_Of_Memory
    }

    return out, .None
}

// Decode a relay ticket response (`link_tickets`/`connect_tickets`).
ticket_decode :: proc(body: []u8, allocator := context.allocator) -> (Control_Ticket, Control_Error) {
    out: Control_Ticket
    if json.unmarshal(body, &out, .JSON, allocator) != nil {
        return {}, .Malformed
    }

    if out.ticket == "" || out.relay_url == "" {
        return {}, .Malformed
    }

    return out, .None
}
