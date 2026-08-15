package oauth

import "core:strings"
import "core:testing"

import "src:secret"

// An opaque, non-JWT access token parses; account id stays empty, expiry from expires_in.
@(test)
test_xai_token_response_parse_opaque_access_token :: proc(t: ^testing.T) {
    response := `{"access_token":"opaque-xai-token","refresh_token":"r-new","expires_in":21600,"token_type":"Bearer"}`

    credentials, parse_err := token_response_parse(provider(.Xai), response, 1_700_000_000_000)
    testing.expect_value(t, parse_err, OAuth_Error.None)
    defer credentials_destroy(&credentials)

    testing.expect_value(t, credentials.account_id, "")
    testing.expect_value(t, credentials.access_token, "opaque-xai-token")
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
