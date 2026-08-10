package auth

import "core:strconv"
import "core:strings"
import "core:testing"

@(test)
test_pkce_challenge_matches_rfc_7636_vector :: proc(t: ^testing.T) {
    verifier := "dBjftJeZ4CVP-mB92K27uhbUJU1p1r_wW1gFWFOEjXk"
    challenge, err := pkce_challenge(verifier, context.allocator)
    testing.expect_value(t, err, OAuth_Error.None)
    defer secret_delete(&challenge, context.allocator)

    testing.expect_value(t, challenge, "E9Melhoa2OwvFrEMTJguCHaoeK1t8URWbuGJSstw-cM")
}

@(test)
test_url_encode_uses_rfc_3986_unreserved_set :: proc(t: ^testing.T) {
    encoded, err := url_encode("azAZ09-_.~ +/%&=", context.allocator)
    testing.expect_value(t, err, OAuth_Error.None)
    defer secret_delete(&encoded, context.allocator)

    testing.expect_value(t, encoded, "azAZ09-_.~%20%2B%2F%25%26%3D")
}

@(test)
test_authorization_flow_contains_dynamic_callback_and_no_padding :: proc(t: ^testing.T) {
    flow, err := authorization_flow_create(codex_provider(), 1457, "yuke-daemon/1", context.allocator)
    testing.expect_value(t, err, OAuth_Error.None)
    defer authorization_flow_destroy(&flow, context.allocator)

    testing.expect_value(t, len(flow.verifier), 43)
    testing.expect(t, !strings.contains(flow.verifier, "="), "PKCE verifier is unpadded base64url")
    testing.expect_value(t, len(flow.state), 32)
    testing.expect_value(t, flow.redirect_uri, "http://localhost:1457/auth/callback")
    testing.expect(t, strings.contains(flow.auth_url, "code_challenge_method=S256"), "S256 challenge")
    testing.expect(
        t,
        strings.contains(
            flow.auth_url,
            "scope=openid%20profile%20email%20offline_access%20api.connectors.read%20api.connectors.invoke",
        ),
        "Codex connector scopes",
    )
    testing.expect(
        t,
        strings.contains(flow.auth_url, "redirect_uri=http%3A%2F%2Flocalhost%3A1457%2Fauth%2Fcallback"),
        "callback is encoded",
    )
    testing.expect(t, strings.contains(flow.auth_url, "originator=yuke-daemon%2F1"), "originator is encoded")
}

@(test)
test_authorization_code_body_uses_dynamic_callback_and_pkce :: proc(t: ^testing.T) {
    flow := Authorization_Flow {
        verifier     = "dBjftJeZ4CVP-mB92K27uhbUJU1p1r_wW1gFWFOEjXk",
        redirect_uri = "http://localhost:1457/auth/callback",
    }
    body, err := authorization_code_body(codex_provider(), flow, "code +/%")
    testing.expect_value(t, err, OAuth_Error.None)
    defer secret_delete(&body, context.allocator)

    testing.expect(
        t,
        strings.contains(body, "grant_type=authorization_code&code=code%20%2B%2F%25"),
        "authorization code is form encoded",
    )
    testing.expect(t, strings.contains(body, "redirect_uri=http%3A%2F%2Flocalhost%3A1457"), "callback matches")
    testing.expect(t, strings.contains(body, "code_verifier=dBjftJeZ4"), "PKCE verifier is included")
}

@(test)
test_query_value_decode_is_strict :: proc(t: ^testing.T) {
    decoded, err := query_value_decode("code%20with%2Bplus+space")
    testing.expect_value(t, err, OAuth_Error.None)
    defer secret_delete(&decoded, context.allocator)
    testing.expect_value(t, decoded, "code with+plus space")

    _, short_err := query_value_decode("code%2")
    testing.expect_value(t, short_err, OAuth_Error.Invalid_Input)
    _, hex_err := query_value_decode("code%XX")
    testing.expect_value(t, hex_err, OAuth_Error.Invalid_Input)
}

test_access_token :: proc(allocator := context.allocator) -> string {
    return test_access_token_expires(0, allocator)
}

test_access_token_expires :: proc(expires_at_s: u64, allocator := context.allocator) -> string {
    header, header_err := base64url_encode(transmute([]byte)string(`{"alg":"none"}`), allocator)
    if header_err != .None {
        return ""
    }
    defer secret_delete(&header, allocator)

    payload_json := `{"https://api.openai.com/auth":{"chatgpt_account_id":"acct-123"}}`
    payload_owned: string
    defer secret_delete(&payload_owned, allocator)

    if expires_at_s > 0 {
        exp_buf: [20]byte
        exp := strconv.write_uint(exp_buf[:], expires_at_s, 10)
        with_exp, payload_aerr := strings.concatenate(
            {`{"exp":`, exp, `,"https://api.openai.com/auth":{"chatgpt_account_id":"acct-123"}}`},
            allocator,
        )
        if payload_aerr != nil {
            return ""
        }
        payload_owned = with_exp
        payload_json = payload_owned
    }
    payload, payload_err := base64url_encode(transmute([]byte)payload_json, allocator)
    if payload_err != .None {
        return ""
    }
    defer secret_delete(&payload, allocator)

    token, token_aerr := strings.concatenate({header, ".", payload, ".sig"}, allocator)
    if token_aerr != nil {
        return ""
    }

    return token
}

@(test)
test_account_id_and_token_response_parse :: proc(t: ^testing.T) {
    token := test_access_token()
    testing.expect(t, token != "", "test JWT")
    defer secret_delete(&token, context.allocator)

    account, account_err := codex_account_id(token)
    testing.expect_value(t, account_err, OAuth_Error.None)
    testing.expect_value(t, account, "acct-123")
    secret_delete(&account, context.allocator)

    response, response_aerr := strings.concatenate(
        {
            `{"access_token":"`,
            token,
            `","id_token":"`,
            token,
            `","refresh_token":"refresh-new","expires_in":3600,"token_type":"Bearer"}`,
        },
    )
    testing.expect(t, response_aerr == nil, "token response allocation")
    defer secret_delete(&response, context.allocator)

    credentials, parse_err := token_response_parse(codex_provider(), response, 1_700_000_000_000)
    testing.expect_value(t, parse_err, OAuth_Error.None)
    defer credentials_destroy(&credentials)

    testing.expect_value(t, credentials.access_token, token)
    testing.expect_value(t, credentials.refresh_token, "refresh-new")
    testing.expect_value(t, credentials.account_id, "acct-123")
    testing.expect_value(t, credentials.expires_at_ms, u64(1_700_003_600_000))
}

@(test)
test_login_token_response_requires_a_refresh_token :: proc(t: ^testing.T) {
    token := test_access_token()
    defer secret_delete(&token, context.allocator)

    response, response_aerr := strings.concatenate(
        {`{"access_token":"`, token, `","id_token":"`, token, `","expires_in":300}`},
    )
    testing.expect(t, response_aerr == nil, "token response allocation")
    defer secret_delete(&response, context.allocator)

    _, missing_err := token_response_parse(codex_provider(), response, 10_000)
    testing.expect_value(t, missing_err, OAuth_Error.Invalid_Response)
}

@(test)
test_login_token_response_overflow_releases_the_derived_account :: proc(t: ^testing.T) {
    token := test_access_token()
    defer secret_delete(&token, context.allocator)

    response, response_aerr := strings.concatenate(
        {
            `{"access_token":"`,
            token,
            `","id_token":"`,
            token,
            `","refresh_token":"refresh","expires_in":18446744073709551615}`,
        },
    )
    testing.expect(t, response_aerr == nil, "token response allocation")
    defer secret_delete(&response, context.allocator)

    _, parse_err := token_response_parse(codex_provider(), response, max(u64))
    testing.expect_value(t, parse_err, OAuth_Error.Invalid_Response)
}

@(test)
test_refresh_request_is_json_and_escapes_the_rotating_token :: proc(t: ^testing.T) {
    body, err := refresh_request_body(codex_provider(), `refresh-"\\token`)
    testing.expect_value(t, err, OAuth_Error.None)
    defer secret_delete(&body, context.allocator)

    testing.expect_value(
        t,
        body,
        `{"client_id":"app_EMoamEEZ73f0CkXaXp7hrann","grant_type":"refresh_token","refresh_token":"refresh-\"\\\\token"}`,
    )
}

@(test)
test_refresh_response_merges_optional_tokens_and_retains_account :: proc(t: ^testing.T) {
    existing := OAuth_Credentials {
        access_token  = "access-old",
        refresh_token = "refresh-old",
        expires_at_ms = 1_700_000_000_000,
        account_id    = "acct-old",
    }
    access := test_access_token_expires(1_800_000_000)
    testing.expect(t, access != "", "expiring test JWT")
    defer secret_delete(&access, context.allocator)

    response, response_aerr := strings.concatenate(
        {`{"id_token":null,"access_token":"`, access, `","refresh_token":"refresh-new"}`},
    )
    testing.expect(t, response_aerr == nil, "refresh response allocation")
    defer secret_delete(&response, context.allocator)

    credentials, parse_err := refresh_response_parse(codex_provider(), response, existing, 1_700_000_000_000)
    testing.expect_value(t, parse_err, OAuth_Error.None)
    defer credentials_destroy(&credentials)

    testing.expect_value(t, credentials.access_token, access)
    testing.expect_value(t, credentials.refresh_token, "refresh-new")
    testing.expect_value(t, credentials.account_id, "acct-old")
    testing.expect_value(t, credentials.expires_at_ms, u64(1_800_000_000_000))
}

@(test)
test_refresh_response_updates_account_only_from_returned_id_token :: proc(t: ^testing.T) {
    existing := OAuth_Credentials {
        access_token  = "access-old",
        refresh_token = "refresh-old",
        expires_at_ms = 1_700_000_000_000,
        account_id    = "acct-old",
    }
    id_token := test_access_token()
    defer secret_delete(&id_token, context.allocator)

    response, response_aerr := strings.concatenate({`{"id_token":"`, id_token, `"}`})
    testing.expect(t, response_aerr == nil, "refresh response allocation")
    defer secret_delete(&response, context.allocator)

    credentials, parse_err := refresh_response_parse(codex_provider(), response, existing, 1_700_000_000_000)
    testing.expect_value(t, parse_err, OAuth_Error.None)
    defer credentials_destroy(&credentials)

    testing.expect_value(t, credentials.access_token, "access-old")
    testing.expect_value(t, credentials.refresh_token, "refresh-old")
    testing.expect_value(t, credentials.account_id, "acct-123")
    testing.expect_value(t, credentials.expires_at_ms, existing.expires_at_ms)
}

@(test)
test_refresh_response_may_omit_every_token_field :: proc(t: ^testing.T) {
    existing := OAuth_Credentials {
        access_token  = "access-old",
        refresh_token = "refresh-old",
        expires_at_ms = 1_700_000_000_000,
        account_id    = "acct-old",
    }

    credentials, parse_err := refresh_response_parse(codex_provider(), `{}`, existing, 1_800_000_000_000)
    testing.expect_value(t, parse_err, OAuth_Error.None)
    defer credentials_destroy(&credentials)

    testing.expect_value(t, credentials, existing)
}

@(test)
test_refresh_response_rejects_present_empty_or_wrong_type_tokens :: proc(t: ^testing.T) {
    existing := OAuth_Credentials {
        access_token  = "access-old",
        refresh_token = "refresh-old",
        expires_at_ms = 1_700_000_000_000,
        account_id    = "acct-old",
    }

    _, empty_err := refresh_response_parse(codex_provider(), `{"access_token":""}`, existing, 0)
    testing.expect_value(t, empty_err, OAuth_Error.Invalid_Response)
    _, type_err := refresh_response_parse(codex_provider(), `{"refresh_token":7}`, existing, 0)
    testing.expect_value(t, type_err, OAuth_Error.Invalid_Response)
    _, malformed_err := refresh_response_parse(codex_provider(), `not json`, existing, 0)
    testing.expect_value(t, malformed_err, OAuth_Error.Invalid_Response)
}

@(test)
test_refresh_failure_classifies_only_terminal_rotating_token_errors :: proc(t: ^testing.T) {
    testing.expect(
        t,
        refresh_failure_permanent(codex_provider(), `{"error":{"code":"refresh_token_expired"}}`),
        "expired",
    )
    testing.expect(
        t,
        refresh_failure_permanent(codex_provider(), `{"error":{"code":"refresh_token_reused"}}`),
        "reused",
    )
    testing.expect(
        t,
        !refresh_failure_permanent(codex_provider(), `{"error":{"code":"temporarily_unavailable"}}`),
        "transient",
    )
    testing.expect(t, !refresh_failure_permanent(codex_provider(), `not json`), "malformed")
}

@(test)
test_oauth_refresh_window_saturates :: proc(t: ^testing.T) {
    testing.expect(t, oauth_needs_refresh(codex_provider(), 60_000, 0), "short-lived token refreshes immediately")
    testing.expect(t, oauth_needs_refresh(codex_provider(), 1_000_000, 900_000), "inside lead window")
    testing.expect(t, !oauth_needs_refresh(codex_provider(), 1_000_000, 100_000), "outside lead window")
    testing.expect_value(t, oauth_refresh_after_ms(codex_provider(), 60_000, 0), u64(0))
    testing.expect_value(t, oauth_refresh_after_ms(codex_provider(), 1_000_000, 100_000), u64(600_000))
}
