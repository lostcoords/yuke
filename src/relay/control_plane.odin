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
}

// The bearer scheme presented on every device-authed control-plane call.
BEARER_PREFIX :: "Bearer "

// POST /api/v1/device_codes request body. The static public key is base64 — an opaque string
// to the control plane, decoded back to 32 bytes by whoever pins it from the roster.
@(private = "file")
Enroll_Start_Body :: struct {
    name:              string `json:"name"`,
    platform:          string `json:"platform"`,
    static_public_key: string `json:"static_public_key,omitempty"`,
    intent:            string `json:"intent"`,
    session_kind:      string `json:"session_kind,omitempty"`,
    device_ids:        []string `json:"device_ids,omitempty"`,
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
    device_id:          string `json:"device_id"`,
    credential:         string `json:"credential"`,
    relay_url:          string `json:"relay_url"`,
    session_id:         string `json:"session_id"`,
    session_credential: string `json:"session_credential"`,
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

// One device in the account roster (`GET /api/v1/devices`). Only the fields the client acts
// on are modeled; the rest of each entry is ignored. `static_public_key` is base64 — decode
// it to 32 raw bytes with `roster_pin_decode` before pinning the Noise handshake. `is_self`
// flags the calling device so the menu can skip it. Strings owned by the decode allocator.
Roster_Device :: struct {
    device_id:         string `json:"device_id"`,
    name:              string `json:"name"`,
    static_public_key: string `json:"static_public_key"`,
    online:            bool `json:"online"`,
    is_self:           bool `json:"is_self"`,
}

// GET /api/v1/devices response envelope.
@(private = "file")
Roster_Body :: struct {
    devices: []Roster_Device `json:"devices"`,
}

// Encode a device_codes start request. `static_public_key` is the raw 32-byte X25519 public
// key, base64-encoded into the body.
enroll_start_encode :: proc(
    name: string,
    platform: string,
    static_public_key: []u8,
    intent: string,
    session_kind := "",
    device_ids: []string = nil,
    allocator := context.allocator,
) -> []u8 {
    encoded := ""
    if len(static_public_key) > 0 {
        assert(len(static_public_key) == NOISE_STATIC_KEY_SIZE, "enroll needs a 32-byte public key")
        encoded = base64.encode(static_public_key, base64.ENC_TABLE, context.temp_allocator)
    }

    body := Enroll_Start_Body {
        name              = name,
        platform          = platform,
        static_public_key = encoded,
        intent            = intent if intent != "" else "daemon",
        session_kind      = session_kind,
        device_ids        = device_ids,
    }

    out, _ := json.marshal(body, {}, allocator)

    return out
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

// POST /api/v1/device_codes/token request body.
@(private = "file")
Poll_Body :: struct {
    device_code: string `json:"device_code"`,
}

// Encode a device_codes/token poll request for `device_code`.
enroll_poll_encode :: proc(device_code: string, allocator := context.allocator) -> []u8 {
    out, _ := json.marshal(Poll_Body{device_code = device_code}, {}, allocator)

    return out
}

// Decode a device_codes/token poll by its HTTP status: 201 approved (with the credential),
// 428 pending, 403 denied, anything else (400/expired/invalid) start over.
enroll_poll_decode :: proc(
    status: int,
    body: []u8,
    allocator := context.allocator,
    intent := "daemon",
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

        if cred.relay_url == "" || cred.credential == "" {
            return .Expired, {}, .Malformed
        }
        switch intent {
        case "client":
            if cred.session_id == "" {
                return .Expired, {}, .Malformed
            }
        case "both":
            if cred.device_id == "" || cred.session_id == "" || cred.session_credential == "" {
                return .Expired, {}, .Malformed
            }
        case:
            if cred.device_id == "" {
                return .Expired, {}, .Malformed
            }
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
connect_ticket_encode :: proc(device_id: string, allocator := context.allocator) -> []u8 {
    out, _ := json.marshal(Connect_Body{device_id = device_id}, {}, allocator)

    return out
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

// Decode a `GET /api/v1/devices` response into the account roster. The slice and its strings
// are owned by `allocator`. A body that is not `{devices:[…]}`, or any entry missing its
// device_id or static key, is `.Malformed` — the control plane is authoritative, so a
// well-formed roster always carries both on every device.
roster_decode :: proc(body: []u8, allocator := context.allocator) -> ([]Roster_Device, Control_Error) {
    out: Roster_Body
    if json.unmarshal(body, &out, .JSON, allocator) != nil {
        return nil, .Malformed
    }

    for device in out.devices {
        if device.device_id == "" || device.static_public_key == "" {
            return nil, .Malformed
        }
    }

    return out.devices, .None
}

// Decode a roster entry's base64 `static_public_key` into the 32 raw bytes a client pins.
// Returns false on bad base64 or a length other than 32. Control-plane input, so a bad key
// degrades rather than asserting.
roster_pin_decode :: proc(static_public_key: string, out: []u8) -> bool {
    assert(len(out) == NOISE_STATIC_KEY_SIZE, "roster pin needs a 32-byte buffer")

    raw, err := base64.decode(static_public_key, base64.DEC_TABLE, nil, context.temp_allocator)
    if err != nil || len(raw) != NOISE_STATIC_KEY_SIZE {
        return false
    }

    copy(out, raw)

    return true
}
