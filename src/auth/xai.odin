package auth

import "core:strings"

// xAI Grok OAuth: standard OAuth 2.0 + RFC 8628, PKCE S256, public client.
// Endpoints from OIDC discovery at auth.x.ai; client-identity param is `referrer`.
XAI_PROVIDER_ID :: "xai-grok"
XAI_CLIENT_ID :: "b1a00492-073a-47ea-816f-4c329264a828"
XAI_AUTHORIZE_URL :: "https://auth.x.ai/oauth2/authorize"
XAI_TOKEN_URL :: "https://auth.x.ai/oauth2/token"
XAI_DEVICE_URL :: "https://auth.x.ai/oauth2/device/code"
XAI_SCOPE :: "openid profile email offline_access grok-cli:access api:access"
XAI_CALLBACK_PORTS := [1]int{0}

// xAI registers the redirect as 127.0.0.1 + `/callback` (any loopback port); both
// must match the client registration or the redirect_uri is rejected.
XAI_CALLBACK_HOST :: "127.0.0.1"
XAI_CALLBACK_PATH :: "/callback"

// Access tokens live ~6h, refreshed 5 min ahead; the fallback only applies to a
// response with no usable lifetime, which standard device/token responses never carry.
XAI_REFRESH_LEAD_MS :: 5 * 60 * 1000
XAI_REFRESH_FALLBACK_MS :: 6 * 60 * 60 * 1000

// Standard-OAuth terminal refresh error (top-level `error`).
@(rodata)
XAI_REFRESH_PERMANENT_CODES := [?]string{"invalid_grant"}

// The xAI provider descriptor. Immutable, stable address. Device support arrives
// with the RFC 8628 flow profile; browser + refresh work today.
xai_descriptor := Provider {
    id                         = XAI_PROVIDER_ID,
    client_id                  = XAI_CLIENT_ID,
    scope                      = XAI_SCOPE,
    authorize_url              = XAI_AUTHORIZE_URL,
    token_url                  = XAI_TOKEN_URL,
    authorize_extra_params     = "",
    authorize_originator_param = "referrer",
    callback_host              = XAI_CALLBACK_HOST,
    callback_path              = XAI_CALLBACK_PATH,
    callback_ports             = XAI_CALLBACK_PORTS[:],
    device_user_code_url       = XAI_DEVICE_URL,
    device_token_url           = XAI_TOKEN_URL,
    device_redirect_uri        = "",
    device_verification_url    = "",
    device_profile             = .Rfc8628,
    refresh_profile            = .Standard,
    refresh_lead_ms            = XAI_REFRESH_LEAD_MS,
    refresh_fallback_ms        = XAI_REFRESH_FALLBACK_MS,
    refresh_permanent_codes    = XAI_REFRESH_PERMANENT_CODES[:],
    account_token              = .Access,
    account_id                 = xai_account_id,
}

// The xAI provider descriptor; the returned pointer is stable for the program.
xai_provider :: proc() -> ^Provider {
    return &xai_descriptor
}

// Project the xAI account id from the access token: `principal_id` (fallback
// `sub`). Reads an already-transport-authenticated JWT; does not verify the sig.
xai_account_id :: proc(token: string, allocator := context.allocator) -> (account_id: string, err: OAuth_Error) {
    value, object, parse_err := jwt_payload_object(token, allocator)
    if parse_err != .None {
        return "", parse_err
    }
    defer secret_json_destroy(value, allocator)

    subject, subject_ok := json_string_member(object, "principal_id")
    if !subject_ok || subject == "" {
        subject, subject_ok = json_string_member(object, "sub")
    }
    if !subject_ok || subject == "" || len(subject) > 256 {
        return "", .Invalid_Response
    }

    cloned, aerr := strings.clone(subject, allocator)
    if aerr != nil {
        return "", .Out_Of_Memory
    }
    account_id = cloned

    return account_id, .None
}
