package oauth

import "core:encoding/json"
import "core:strings"

CODEX_PROVIDER_ID :: "openai-codex"
CODEX_CLIENT_ID :: "app_EMoamEEZ73f0CkXaXp7hrann"
CODEX_AUTHORIZE_URL :: "https://auth.openai.com/oauth/authorize"
CODEX_TOKEN_URL :: "https://auth.openai.com/oauth/token"
CODEX_DEVICE_BASE_URL :: "https://auth.openai.com/api/accounts"
CODEX_DEVICE_VERIFICATION_URL :: "https://auth.openai.com/codex/device"
CODEX_SCOPE :: "openid profile email offline_access api.connectors.read api.connectors.invoke"
CODEX_JWT_AUTH_CLAIM :: "https://api.openai.com/auth"
CODEX_CALLBACK_PORTS := [2]int{1455, 1457}
CODEX_CALLBACK_HOST :: "localhost"
CODEX_CALLBACK_PATH :: "/auth/callback"

CODEX_REFRESH_FALLBACK_MS :: 8 * 24 * 60 * 60 * 1000
CODEX_REFRESH_LEAD_MS :: 5 * 60 * 1000

// Refresh `error.code` values that mean the rotating token is gone for good.
@(rodata)
CODEX_REFRESH_PERMANENT_CODES := [?]string {
    "refresh_token_expired",
    "refresh_token_reused",
    "refresh_token_invalidated",
}

// The Codex/OpenAI provider descriptor. Immutable, stable address.
codex_descriptor := Provider {
    kind                       = .Codex,
    id                         = CODEX_PROVIDER_ID,
    client_id                  = CODEX_CLIENT_ID,
    scope                      = CODEX_SCOPE,
    authorize_url              = CODEX_AUTHORIZE_URL,
    token_url                  = CODEX_TOKEN_URL,
    authorize_extra_params     = "&id_token_add_organizations=true&codex_cli_simplified_flow=true",
    authorize_originator_param = "originator",
    callback_host              = CODEX_CALLBACK_HOST,
    callback_path              = CODEX_CALLBACK_PATH,
    callback_ports             = CODEX_CALLBACK_PORTS[:],
    device_user_code_url       = CODEX_DEVICE_USER_CODE_URL,
    device_token_url           = CODEX_DEVICE_TOKEN_URL,
    device_redirect_uri        = CODEX_DEVICE_REDIRECT_URI,
    device_verification_url    = CODEX_DEVICE_VERIFICATION_URL,
    refresh_lead_ms            = CODEX_REFRESH_LEAD_MS,
    refresh_fallback_ms        = CODEX_REFRESH_FALLBACK_MS,
    refresh_permanent_codes    = CODEX_REFRESH_PERMANENT_CODES[:],
}

// Extract the Codex `chatgpt-account-id` from the id_token JWT. Reads an
// already-transport-authenticated token; does not verify the signature.
codex_account_id :: proc(id_token: string, allocator := context.allocator) -> (account_id: string, err: OAuth_Error) {
    value, object, parse_err := jwt_payload_object(id_token, allocator)
    if parse_err != .None {
        return "", parse_err
    }
    defer secret_json_destroy(value, allocator)

    claim_value, claim_found := object[CODEX_JWT_AUTH_CLAIM]
    if !claim_found {
        return "", .Invalid_Response
    }

    claim, claim_ok := claim_value.(json.Object)
    if !claim_ok {
        return "", .Invalid_Response
    }

    account, account_ok := json_string_member(claim, "chatgpt_account_id")
    if !account_ok || account == "" || len(account) > 256 {
        return "", .Invalid_Response
    }

    cloned, aerr := strings.clone(account, allocator)
    if aerr != nil {
        return "", .Out_Of_Memory
    }
    account_id = cloned

    return account_id, .None
}
