package relay

import "core:encoding/base64"
import "core:strings"
import "core:testing"
import "libs:json"

@(test)
test_enroll_start_encode :: proc(t: ^testing.T) {
    ids := []string{"pub_laptop", "pub_phone"}
    body := enroll_start_encode("my-laptop", "darwin", nil, "client", "token", ids, context.temp_allocator)

    // The request round-trips to the documented shape.
    Parsed :: struct {
        name:              string `json:"name"`,
        platform:          string `json:"platform"`,
        static_public_key: string `json:"static_public_key"`,
        session_kind:      string `json:"session_kind"`,
        device_ids:        []string `json:"device_ids"`,
    }
    parsed: Parsed
    testing.expect(t, json.unmarshal(body, &parsed, .JSON, context.temp_allocator) == nil, "request is valid JSON")
    testing.expect(t, parsed.name == "my-laptop", "name")
    testing.expect(t, parsed.platform == "darwin", "platform")
    testing.expect(t, parsed.session_kind == "token", "session_kind")
    testing.expect(t, len(parsed.device_ids) == 2, "device_ids")
    testing.expect(t, parsed.static_public_key == "", "client grant has no pin")

    free_all(context.temp_allocator)
}

@(test)
test_enroll_poll_encode :: proc(t: ^testing.T) {
    body := enroll_poll_encode("dc-abc", context.temp_allocator)

    Parsed :: struct {
        device_code: string `json:"device_code"`,
    }
    parsed: Parsed
    testing.expect(t, json.unmarshal(body, &parsed, .JSON, context.temp_allocator) == nil, "request is valid JSON")
    testing.expect(t, parsed.device_code == "dc-abc", "device_code round-trips")

    free_all(context.temp_allocator)
}

@(test)
test_enroll_start_decode :: proc(t: ^testing.T) {
    body := `{
        "device_code": "dc-abc",
        "user_code": "WXYZ-1234",
        "verification_uri": "https://yuke.sh/enroll",
        "verification_uri_complete": "https://yuke.sh/enroll?code=WXYZ-1234",
        "expires_in": 900,
        "interval": 5
    }`

    start, err := enroll_start_decode(transmute([]u8)body, context.temp_allocator)
    testing.expect_value(t, err, Control_Error.None)
    testing.expect(t, start.device_code == "dc-abc", "device_code")
    testing.expect(t, start.user_code == "WXYZ-1234", "user_code")
    testing.expect(t, start.verification_uri == "https://yuke.sh/enroll", "verification_uri")
    testing.expect(t, start.interval == 5, "interval")

    // A body missing a required field is malformed.
    _, bad := enroll_start_decode(transmute([]u8)string(`{"user_code":"x"}`), context.temp_allocator)
    testing.expect_value(t, bad, Control_Error.Malformed)

    free_all(context.temp_allocator)
}

@(test)
test_enroll_poll_decode :: proc(t: ^testing.T) {
    // 201 approved carries the credential.
    approved_body := `{"device_id":"dev-42","credential":"cred-xyz","relay_url":"wss://relay.yuke.sh"}`
    poll, cred, err := enroll_poll_decode(201, transmute([]u8)approved_body, context.temp_allocator)
    testing.expect_value(t, err, Control_Error.None)
    testing.expect_value(t, poll, Enroll_Poll.Approved)
    testing.expect(t, cred.device_id == "dev-42", "device_id")
    testing.expect(t, cred.credential == "cred-xyz", "credential")
    testing.expect(t, cred.relay_url == "wss://relay.yuke.sh", "relay_url")

    // 428 pending, 403 denied, 400 expired — status decides, body ignored.
    poll, _, _ = enroll_poll_decode(428, transmute([]u8)string(""), context.temp_allocator)
    testing.expect_value(t, poll, Enroll_Poll.Pending)

    poll, _, _ = enroll_poll_decode(403, transmute([]u8)string(""), context.temp_allocator)
    testing.expect_value(t, poll, Enroll_Poll.Denied)

    poll, _, _ = enroll_poll_decode(400, transmute([]u8)string(""), context.temp_allocator)
    testing.expect_value(t, poll, Enroll_Poll.Expired)

    // A 201 that is missing a field is malformed.
    _, _, mal := enroll_poll_decode(201, transmute([]u8)string(`{"device_id":"d"}`), context.temp_allocator)
    testing.expect_value(t, mal, Control_Error.Malformed)

    client_body := `{"session_id":"sess_1","credential":"yk_sess_x","relay_url":"wss://relay.yuke.sh"}`
    poll, cred, err = enroll_poll_decode(201, transmute([]u8)client_body, context.temp_allocator, "client")
    testing.expect_value(t, err, Control_Error.None)
    testing.expect_value(t, poll, Enroll_Poll.Approved)
    testing.expect(t, cred.session_id == "sess_1", "client session_id")

    both_body := `{"device_id":"dev-1","credential":"yk_dev_x","session_id":"sess_1","session_credential":"yk_sess_x","relay_url":"wss://relay.yuke.sh"}`
    poll, cred, err = enroll_poll_decode(201, transmute([]u8)both_body, context.temp_allocator, "both")
    testing.expect_value(t, err, Control_Error.None)
    testing.expect(t, cred.session_credential == "yk_sess_x", "both session_credential")

    free_all(context.temp_allocator)
}

@(test)
test_ticket_codec :: proc(t: ^testing.T) {
    body := `{"ticket":"tok-123","relay_url":"wss://relay.yuke.sh","expires_at":"2026-08-10T06:00:00Z"}`
    tk, err := ticket_decode(transmute([]u8)body, context.temp_allocator)
    testing.expect_value(t, err, Control_Error.None)
    testing.expect(t, tk.ticket == "tok-123", "ticket")
    testing.expect(t, tk.relay_url == "wss://relay.yuke.sh", "relay_url")
    testing.expect(t, tk.expires_at == "2026-08-10T06:00:00Z", "expires_at")

    _, bad := ticket_decode(transmute([]u8)string(`{"relay_url":"x"}`), context.temp_allocator)
    testing.expect_value(t, bad, Control_Error.Malformed)

    // connect_tickets request body.
    req := connect_ticket_encode("target-dev", context.temp_allocator)
    Parsed :: struct {
        device_id: string `json:"device_id"`,
    }
    parsed: Parsed
    testing.expect(t, json.unmarshal(req, &parsed, .JSON, context.temp_allocator) == nil, "request is valid JSON")
    testing.expect(t, parsed.device_id == "target-dev", "device_id")

    free_all(context.temp_allocator)
}

@(test)
test_roster_decode :: proc(t: ^testing.T) {
    // A base64 32-byte key for the pin round-trip.
    key: [NOISE_STATIC_KEY_SIZE]u8
    for i in 0 ..< NOISE_STATIC_KEY_SIZE {
        key[i] = u8(i)
    }

    encoded := base64.encode(key[:], base64.ENC_TABLE, context.temp_allocator)

    body := fmt_roster(encoded)
    roster, err := roster_decode(transmute([]u8)body, context.temp_allocator)
    testing.expect_value(t, err, Control_Error.None)
    testing.expect(t, len(roster) == 2, "two devices")
    testing.expect(t, roster[0].device_id == "dev-server", "device_id")
    testing.expect(t, roster[0].name == "server", "name")
    testing.expect(t, roster[0].online, "online flag")
    testing.expect(t, !roster[0].is_self, "not self")
    testing.expect(t, roster[1].is_self, "self flag")

    // The pinned key round-trips to the raw 32 bytes.
    pin: [NOISE_STATIC_KEY_SIZE]u8
    testing.expect(t, roster_pin_decode(roster[0].static_public_key, pin[:]), "pin decodes")
    testing.expect(t, pin == key, "pin matches the original key")

    // A garbage or wrong-length key is rejected, not asserted.
    testing.expect(t, !roster_pin_decode("!!!!", pin[:]), "bad base64 rejected")
    short := base64.encode([]u8{1, 2, 3}, base64.ENC_TABLE, context.temp_allocator)
    testing.expect(t, !roster_pin_decode(short, pin[:]), "wrong-length key rejected")

    // A shape that is not `{devices:[…]}`, or an entry missing a required field, is malformed.
    _, e1 := roster_decode(transmute([]u8)string(`{"devices":"nope"}`), context.temp_allocator)
    testing.expect_value(t, e1, Control_Error.Malformed)

    _, e2 := roster_decode(transmute([]u8)string(`{"devices":[{"name":"x"}]}`), context.temp_allocator)
    testing.expect_value(t, e2, Control_Error.Malformed)

    free_all(context.temp_allocator)
}

// Build a two-device roster body with `key` as the first device's base64 static key.
@(private = "file")
fmt_roster :: proc(key: string) -> string {
    parts := []string {
        `{"devices":[`,
        `{"device_id":"dev-server","name":"server","static_public_key":"`,
        key,
        `","online":true,"is_self":false},`,
        `{"device_id":"dev-laptop","name":"laptop","static_public_key":"`,
        key,
        `","online":false,"is_self":true}]}`,
    }

    return strings.concatenate(parts, context.temp_allocator)
}
