package relay

import "core:encoding/json"
import "core:testing"

@(test)
test_enroll_start_encode :: proc(t: ^testing.T) {
    key: [NOISE_STATIC_KEY_SIZE]u8
    for i in 0 ..< NOISE_STATIC_KEY_SIZE {
        key[i] = u8(i)
    }

    body, err := enroll_start_encode("my-laptop", "darwin", key[:], context.temp_allocator)
    testing.expect_value(t, err, Control_Error.None)

    // The request round-trips to the documented shape.
    Parsed :: struct {
        name:              string `json:"name"`,
        platform:          string `json:"platform"`,
        static_public_key: string `json:"static_public_key"`,
    }
    parsed: Parsed
    testing.expect(t, json.unmarshal(body, &parsed, .JSON, context.temp_allocator) == nil, "request is valid JSON")
    testing.expect(t, parsed.name == "my-laptop", "name")
    testing.expect(t, parsed.platform == "darwin", "platform")
    testing.expect(t, parsed.static_public_key != "", "static_public_key present and base64")

    free_all(context.temp_allocator)
}

@(test)
test_enroll_poll_encode :: proc(t: ^testing.T) {
    body, err := enroll_poll_encode("dc-abc", context.temp_allocator)
    testing.expect_value(t, err, Control_Error.None)

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
    req, cerr := connect_ticket_encode("target-dev", context.temp_allocator)
    testing.expect_value(t, cerr, Control_Error.None)
    Parsed :: struct {
        device_id: string `json:"device_id"`,
    }
    parsed: Parsed
    testing.expect(t, json.unmarshal(req, &parsed, .JSON, context.temp_allocator) == nil, "request is valid JSON")
    testing.expect(t, parsed.device_id == "target-dev", "device_id")

    free_all(context.temp_allocator)
}
