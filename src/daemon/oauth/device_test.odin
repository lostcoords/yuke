package oauth

import "core:strings"
import "core:testing"


// --- Codex device flow (non-standard: 403/404 pending, two-step exchange) ---

@(test)
test_codex_device_auth_parse_and_poll_body :: proc(t: ^testing.T) {
    session, err := device_auth_parse(
        provider(.Codex),
        `{"device_auth_id":"machine-secret","user_code":"CODE-12345","interval":"5"}`,
    )
    testing.expect_value(t, err, OAuth_Error.None)
    defer device_session_destroy(&session)

    testing.expect_value(t, session.handle, "machine-secret")
    testing.expect_value(t, session.user_code, "CODE-12345")
    testing.expect_value(t, session.interval_s, u64(5))
    testing.expect_value(t, session.expires_in_s, u64(15 * 60))
    testing.expect_value(t, session.verification_uri, CODEX_DEVICE_VERIFICATION_URL)

    body, content_type, body_err := device_poll_body(provider(.Codex), session)
    testing.expect_value(t, body_err, OAuth_Error.None)
    defer delete(body, context.allocator)
    testing.expect_value(t, content_type, "application/json")
    testing.expect_value(t, body, `{"device_auth_id":"machine-secret","user_code":"CODE-12345"}`)
}

@(test)
test_codex_device_auth_parse_alias_and_interval_rules :: proc(t: ^testing.T) {
    _, zero_err := device_auth_parse(
        provider(.Codex),
        `{"device_auth_id":"machine-secret","usercode":"CODE-12345","interval":"0"}`,
    )
    testing.expect_value(t, zero_err, OAuth_Error.Invalid_Response)

    _, missing_err := device_auth_parse(
        provider(.Codex),
        `{"device_auth_id":"machine-secret","user_code":"CODE-12345"}`,
    )
    testing.expect_value(t, missing_err, OAuth_Error.Invalid_Response)

    _, number_err := device_auth_parse(
        provider(.Codex),
        `{"device_auth_id":"machine-secret","user_code":"CODE-12345","interval":5}`,
    )
    testing.expect_value(t, number_err, OAuth_Error.Invalid_Response)

    _, large_err := device_auth_parse(
        provider(.Codex),
        `{"device_auth_id":"machine-secret","user_code":"CODE-12345","interval":"61"}`,
    )
    testing.expect_value(t, large_err, OAuth_Error.Invalid_Response)
}

@(test)
test_codex_device_classify_and_grant_body :: proc(t: ^testing.T) {
    pending_403, _ := device_poll_classify(provider(.Codex), 403, "", context.allocator)
    _, is_pending_403 := pending_403.(Device_Pending)
    testing.expect(t, is_pending_403, "codex 403 keeps polling")

    pending_404, _ := device_poll_classify(provider(.Codex), 404, "", context.allocator)
    _, is_pending_404 := pending_404.(Device_Pending)
    testing.expect(t, is_pending_404, "codex 404 keeps polling")

    rejected, _ := device_poll_classify(provider(.Codex), 400, "", context.allocator)
    _, is_failed := rejected.(Device_Failed)
    testing.expect(t, is_failed, "codex non-2xx (not 403/404) is terminal")

    verifier := "dBjftJeZ4CVP-mB92K27uhbUJU1p1r_wW1gFWFOEjXk"
    approved, approved_aerr := strings.concatenate(
        {`{"authorization_code":"poll-code","code_challenge":"challenge","code_verifier":"`, verifier, `"}`},
    )
    testing.expect(t, approved_aerr == nil, "grant fixture allocation")
    defer delete(approved, context.allocator)

    outcome, outcome_err := device_poll_classify(provider(.Codex), 200, approved, context.allocator)
    testing.expect_value(t, outcome_err, OAuth_Error.None)
    exchange, is_exchange := outcome.(Device_Exchange)
    if !testing.expect(t, is_exchange, "codex 2xx yields a grant to exchange") do return
    grant := exchange.grant
    defer device_grant_destroy(&grant)
    testing.expect_value(t, grant.authorization_code, "poll-code")

    body, body_err := device_grant_body(provider(.Codex), grant)
    testing.expect_value(t, body_err, OAuth_Error.None)
    defer delete(body, context.allocator)
    testing.expect(t, strings.contains(body, "code=poll-code"), "authorization code is exchanged")
    testing.expect(
        t,
        strings.contains(body, "redirect_uri=https%3A%2F%2Fauth.openai.com%2Fdeviceauth%2Fcallback"),
        "device redirect is exact",
    )
}

// --- RFC 8628 device flow (standard: error-body pending, direct tokens) ---

@(test)
test_rfc8628_device_auth_body_is_form_with_referrer :: proc(t: ^testing.T) {
    body, content_type, err := device_auth_body(provider(.Xai), "yuke-odin")
    testing.expect_value(t, err, OAuth_Error.None)
    defer delete(body, context.allocator)

    testing.expect_value(t, content_type, "application/x-www-form-urlencoded")
    testing.expect(t, strings.contains(body, "client_id=b1a00492-073a-47ea-816f-4c329264a828"), "client id")
    testing.expect(t, strings.contains(body, "referrer=yuke-odin"), "referrer client identity")
    testing.expect(t, strings.contains(body, "grok-cli%3Aaccess"), "scope encoded")
}

@(test)
test_rfc8628_device_auth_parse_and_poll_body :: proc(t: ^testing.T) {
    session, err := device_auth_parse(
        provider(.Xai),
        `{"device_code":"dev-code","user_code":"WXYZ-7788","verification_uri":"https://x.ai/device","verification_uri_complete":"https://x.ai/device?code=WXYZ-7788","expires_in":900,"interval":5}`,
    )
    testing.expect_value(t, err, OAuth_Error.None)
    defer device_session_destroy(&session)

    testing.expect_value(t, session.handle, "dev-code")
    testing.expect_value(t, session.user_code, "WXYZ-7788")
    testing.expect_value(t, session.interval_s, u64(5))
    testing.expect_value(t, session.expires_in_s, u64(900))
    testing.expect_value(t, session.verification_uri, "https://x.ai/device?code=WXYZ-7788")

    body, content_type, body_err := device_poll_body(provider(.Xai), session)
    testing.expect_value(t, body_err, OAuth_Error.None)
    defer delete(body, context.allocator)
    testing.expect_value(t, content_type, "application/x-www-form-urlencoded")
    testing.expect(
        t,
        strings.contains(body, "grant_type=urn%3Aietf%3Aparams%3Aoauth%3Agrant-type%3Adevice_code"),
        "device_code grant",
    )
    testing.expect(t, strings.contains(body, "device_code=dev-code"), "device code echoed")
}

@(test)
test_rfc8628_device_auth_parse_rejects_invalid_timing :: proc(t: ^testing.T) {
    base :: `{"device_code":"dev-code","user_code":"WXYZ-7788","verification_uri":"https://x.ai/device"`

    _, missing_expiry := device_auth_parse(provider(.Xai), base + `,"interval":5}`)
    testing.expect_value(t, missing_expiry, OAuth_Error.Invalid_Response)

    _, zero_expiry := device_auth_parse(provider(.Xai), base + `,"expires_in":0,"interval":5}`)
    testing.expect_value(t, zero_expiry, OAuth_Error.Invalid_Response)

    _, fractional_expiry := device_auth_parse(provider(.Xai), base + `,"expires_in":900.5,"interval":5}`)
    testing.expect_value(t, fractional_expiry, OAuth_Error.Invalid_Response)

    _, zero_interval := device_auth_parse(provider(.Xai), base + `,"expires_in":900,"interval":0}`)
    testing.expect_value(t, zero_interval, OAuth_Error.Invalid_Response)

    _, fractional_interval := device_auth_parse(provider(.Xai), base + `,"expires_in":900,"interval":5.5}`)
    testing.expect_value(t, fractional_interval, OAuth_Error.Invalid_Response)

    defaulted, defaulted_err := device_auth_parse(provider(.Xai), base + `,"expires_in":900}`)
    testing.expect_value(t, defaulted_err, OAuth_Error.None)
    defer device_session_destroy(&defaulted)
    testing.expect_value(t, defaulted.interval_s, u64(DEVICE_DEFAULT_POLL_INTERVAL_S))
}

@(test)
test_rfc8628_device_classify_states :: proc(t: ^testing.T) {
    tokens, _ := device_poll_classify(provider(.Xai), 200, `{"access_token":"a"}`, context.allocator)
    _, is_tokens := tokens.(Device_Tokens)
    testing.expect(t, is_tokens, "200 means tokens are ready")

    pending, _ := device_poll_classify(provider(.Xai), 400, `{"error":"authorization_pending"}`, context.allocator)
    _, is_pending := pending.(Device_Pending)
    testing.expect(t, is_pending, "authorization_pending keeps polling")

    slow, _ := device_poll_classify(provider(.Xai), 400, `{"error":"slow_down"}`, context.allocator)
    _, is_slow := slow.(Device_Slow_Down)
    testing.expect(t, is_slow, "slow_down widens the interval")

    transient, _ := device_poll_classify(provider(.Xai), 429, `{}`, context.allocator)
    _, is_transient := transient.(Device_Pending)
    testing.expect(t, is_transient, "429 is a transient retry")

    denied, _ := device_poll_classify(provider(.Xai), 400, `{"error":"access_denied"}`, context.allocator)
    _, denied_failed := denied.(Device_Failed)
    testing.expect(t, denied_failed, "access_denied is terminal")

    expired, _ := device_poll_classify(provider(.Xai), 400, `{"error":"expired_token"}`, context.allocator)
    _, expired_failed := expired.(Device_Failed)
    testing.expect(t, expired_failed, "expired_token is terminal")

    unknown, _ := device_poll_classify(provider(.Xai), 400, `{"error":"teapot"}`, context.allocator)
    _, unknown_failed := unknown.(Device_Failed)
    testing.expect(t, unknown_failed, "unknown errors are terminal, not an infinite poll")
}
