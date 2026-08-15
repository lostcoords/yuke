package oauth

// Authentication-capable providers. This one discriminator selects the
// descriptor and every provider-specific OAuth behavior.
Kind :: enum {
    Codex,
    Xai,
}

// One provider's OAuth adapter: endpoints, public client identity, and the few
// behaviors that differ. Immutable package value with a stable address; hold the pointer.
Provider :: struct {
    // Closed provider identity; selects protocol behavior without parallel profiles.
    kind:                       Kind,

    // Stable id used by durable credentials and on the wire.
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

    // Proactive-refresh lead and the expiry fallback used when a response carries
    // no usable lifetime, both in milliseconds.
    refresh_lead_ms:            u64,
    refresh_fallback_ms:        u64,

    // Failed-refresh identifiers that mean the rotating token is gone for good.
    // Matched against a top-level `error` string or a nested `error.code`.
    refresh_permanent_codes:    []string,
}

// Resolve the closed provider identity to its immutable descriptor.
provider :: proc(kind: Kind) -> ^Provider {
    switch kind {
    case .Codex:
        return &codex_descriptor

    case .Xai:
        return &xai_descriptor
    }

    unreachable()
}

// Resolve a durable/wire provider id to the closed provider identity.
kind_from_id :: proc(id: string) -> (Kind, bool) {
    for kind in Kind {
        if provider(kind).id == id {
            return kind, true
        }
    }

    return {}, false
}
