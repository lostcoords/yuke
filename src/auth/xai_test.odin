package auth

import "core:strings"
import "core:testing"

import "src:secret"

// An unsigned JWT carrying `payload_json` as its claim set; the flow only
// projects claims and never verifies the signature.
xai_test_jwt :: proc(payload_json: string, allocator := context.allocator) -> string {
    header, header_err := base64url_encode(transmute([]byte)string(`{"alg":"ES256"}`), allocator)
    if header_err != .None {
        return ""
    }
    defer secret.string_destroy(&header, allocator)

    payload, payload_err := base64url_encode(transmute([]byte)payload_json, allocator)
    if payload_err != .None {
        return ""
    }
    defer secret.string_destroy(&payload, allocator)

    token, token_aerr := strings.concatenate({header, ".", payload, ".sig"}, allocator)
    if token_aerr != nil {
        return ""
    }

    return token
}

// The access token xAI issues carries the durable identity in `principal_id`.
xai_test_id_token :: proc(allocator := context.allocator) -> string {
    return xai_test_jwt(`{"sub":"xai-user-123"}`, allocator)
}

@(test)
test_xai_account_id_reads_oidc_sub :: proc(t: ^testing.T) {
    token := xai_test_id_token()
    testing.expect(t, token != "", "test JWT")
    defer secret.string_destroy(&token, context.allocator)

    account, err := xai_account_id(token)
    testing.expect_value(t, err, OAuth_Error.None)
    testing.expect_value(t, account, "xai-user-123")
    secret.string_destroy(&account, context.allocator)
}

@(test)
test_xai_token_response_parse_uses_sub_and_expires_in :: proc(t: ^testing.T) {
    token := xai_test_id_token()
    defer secret.string_destroy(&token, context.allocator)

    response, response_aerr := strings.concatenate(
        {
            `{"access_token":"`,
            token,
            `","id_token":"`,
            token,
            `","refresh_token":"r-new","expires_in":21600,"token_type":"Bearer"}`,
        },
    )
    testing.expect(t, response_aerr == nil, "token response allocation")
    defer secret.string_destroy(&response, context.allocator)

    credentials, parse_err := token_response_parse(provider(.Xai), response, 1_700_000_000_000)
    testing.expect_value(t, parse_err, OAuth_Error.None)
    defer credentials_destroy(&credentials)

    testing.expect_value(t, credentials.account_id, "xai-user-123")
    testing.expect_value(t, credentials.refresh_token, "r-new")
    testing.expect_value(t, credentials.expires_at_ms, u64(1_700_021_600_000))
}

@(test)
test_xai_account_id_prefers_principal_id :: proc(t: ^testing.T) {
    token := xai_test_jwt(`{"principal_id":"acct-42","sub":"xai-user-123"}`)
    defer secret.string_destroy(&token, context.allocator)

    account, err := xai_account_id(token)
    testing.expect_value(t, err, OAuth_Error.None)
    testing.expect_value(t, account, "acct-42")
    secret.string_destroy(&account, context.allocator)
}

// The RFC 8628 device token response may omit `id_token`; xAI's identity lives in
// the access token, so the parse must still succeed and key on `principal_id`.
@(test)
test_xai_device_token_response_without_id_token_succeeds :: proc(t: ^testing.T) {
    access := xai_test_jwt(`{"principal_id":"acct-42"}`)
    defer secret.string_destroy(&access, context.allocator)

    response, response_aerr := strings.concatenate(
        {`{"access_token":"`, access, `","refresh_token":"r-new","expires_in":21600,"token_type":"Bearer"}`},
    )
    testing.expect(t, response_aerr == nil, "token response allocation")
    defer secret.string_destroy(&response, context.allocator)

    credentials, parse_err := token_response_parse(provider(.Xai), response, 1_700_000_000_000)
    testing.expect_value(t, parse_err, OAuth_Error.None)
    defer credentials_destroy(&credentials)

    testing.expect_value(t, credentials.account_id, "acct-42")
    testing.expect_value(t, credentials.refresh_token, "r-new")
    testing.expect_value(t, credentials.expires_at_ms, u64(1_700_021_600_000))
}

@(test)
test_xai_refresh_body_is_form_encoded :: proc(t: ^testing.T) {
    body, content_type, err := refresh_request_body(provider(.Xai), "r-token")
    testing.expect_value(t, err, OAuth_Error.None)
    defer secret.string_destroy(&body, context.allocator)
    testing.expect_value(t, content_type, "application/x-www-form-urlencoded")

    testing.expect_value(
        t,
        body,
        "grant_type=refresh_token&client_id=b1a00492-073a-47ea-816f-4c329264a828&refresh_token=r-token",
    )
}

@(test)
test_xai_refresh_failure_classifies_top_level_invalid_grant :: proc(t: ^testing.T) {
    testing.expect(
        t,
        refresh_failure_permanent(provider(.Xai), `{"error":"invalid_grant"}`),
        "invalid_grant is terminal",
    )
    testing.expect(t, !refresh_failure_permanent(provider(.Xai), `{"error":"slow_down"}`), "transient stays retryable")
    testing.expect(t, !refresh_failure_permanent(provider(.Xai), `not json`), "malformed stays retryable")
}

@(test)
test_xai_authorize_url_uses_referrer_and_pkce :: proc(t: ^testing.T) {
    flow, err := authorization_flow_create(provider(.Xai), 1456, "yuke-odin", context.allocator)
    testing.expect_value(t, err, OAuth_Error.None)
    defer authorization_flow_destroy(&flow, context.allocator)

    testing.expect(t, strings.has_prefix(flow.auth_url, XAI_AUTHORIZE_URL), "xAI authorize endpoint")
    testing.expect(t, strings.contains(flow.auth_url, "code_challenge_method=S256"), "PKCE S256")
    testing.expect(t, strings.contains(flow.auth_url, "referrer=yuke-odin"), "referrer client-identity param")
    testing.expect(
        t,
        strings.contains(
            flow.auth_url,
            "scope=openid%20profile%20email%20offline_access%20grok-cli%3Aaccess%20api%3Aaccess",
        ),
        "xAI scopes encoded",
    )
    // xAI's public client registers the redirect as 127.0.0.1 + /callback; a
    // localhost host or the Codex /auth/callback path is a redirect_uri mismatch.
    testing.expect_value(t, flow.redirect_uri, "http://127.0.0.1:1456/callback")
    testing.expect(
        t,
        strings.contains(flow.auth_url, "redirect_uri=http%3A%2F%2F127.0.0.1%3A1456%2Fcallback"),
        "authorize URL carries the encoded xAI redirect",
    )
}
