package auth

import "core:mem"

// Provider-specific refresh response and request behavior.
Refresh_Profile :: enum {
    Codex,
    Standard,
}

// Token from which a provider projects its durable account identity.
Account_Token :: enum {
    Id,
    Access,
}

// One provider's OAuth adapter: endpoints, public client identity, and the few
// behaviors that differ. Immutable package value with a stable address; hold the pointer.
Provider :: struct {
    // Stable id; the key under `providers` in auth.json and on the wire.
    id:                         string,

    // Public OAuth client id. These are desktop clients with no secret.
    client_id:                  string,

    // Space-separated OAuth scopes requested at authorization.
    scope:                      string,

    // Authorization-code (browser) endpoints. `token_url` is a cstring (curl target);
    // `authorize_url` is a string concatenated into the browser URL.
    authorize_url:              string,
    token_url:                  cstring,

    // Static query suffix appended verbatim to the authorize URL, each segment
    // introduced by `&` (e.g. Codex's simplified-flow flags). Empty is fine.
    authorize_extra_params:     string,

    // Client-identifier query param on the authorize URL (`originator` for Codex),
    // appended url-encoded as `&<param>=<value>`. Empty omits it.
    authorize_originator_param: string,

    // Loopback host + path the registered redirect_uri fixes; the daemon serves
    // `callback_path`. Codex: localhost + /auth/callback, xAI: 127.0.0.1 + /callback.
    callback_host:              string,
    callback_path:              string,

    // Ports tried in order to bind the loopback callback for the browser flow.
    callback_ports:             []int,

    // Device-authorization endpoints and the page the user visits. The HTTP targets
    // are cstrings; the redirect uri and verification url are strings.
    device_user_code_url:       cstring,
    device_token_url:           cstring,
    device_redirect_uri:        string,
    device_verification_url:    string,

    // Which device-code protocol this provider speaks.
    device_profile:             Device_Profile,

    // Refresh request and response behavior.
    refresh_profile:            Refresh_Profile,

    // Proactive-refresh lead and the expiry fallback used when a response carries
    // no usable lifetime, both in milliseconds.
    refresh_lead_ms:            u64,
    refresh_fallback_ms:        u64,

    // Failed-refresh identifiers that mean the rotating token is gone for good.
    // Matched against a top-level `error` string or a nested `error.code`.
    refresh_permanent_codes:    []string,

    // Which token carries the account identity.
    account_token:              Account_Token,

    // Project the account id out of `account_token`.
    account_id:                 proc(token: string, allocator: mem.Allocator) -> (string, OAuth_Error),
}
