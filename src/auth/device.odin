package auth

import "core:encoding/json"
import "core:math"
import "core:mem"
import "core:strconv"
import "core:strings"

import "src:secret"

// Generic device-flow bounds and the RFC 8628 device grant type.
DEVICE_HANDLE_MAX_BYTES :: 4096
DEVICE_USER_CODE_MAX_BYTES :: 128
DEVICE_VERIFICATION_URL_MAX_BYTES :: 2048
DEVICE_POLL_INTERVAL_MIN_S :: 1
DEVICE_POLL_INTERVAL_MAX_S :: 60
DEVICE_CODE_LIFETIME_MAX_S :: 24 * 60 * 60

// RFC 8628 §3.5 poll interval when a standard device response omits `interval`.
DEVICE_DEFAULT_POLL_INTERVAL_S :: 5
DEVICE_CODE_GRANT_TYPE :: "urn:ietf:params:oauth:grant-type:device_code"

// Codex device endpoints (its device auth is non-standard; see Device_Profile).
CODEX_DEVICE_USER_CODE_URL :: "https://auth.openai.com/api/accounts/deviceauth/usercode"
CODEX_DEVICE_TOKEN_URL :: "https://auth.openai.com/api/accounts/deviceauth/token"
CODEX_DEVICE_REDIRECT_URI :: "https://auth.openai.com/deviceauth/callback"
CODEX_DEVICE_TIMEOUT_MS :: 15 * 60 * 1000

// The device-code protocol a provider speaks.
Device_Profile :: enum {
    // Non-standard: pending is HTTP 403/404, and the poll returns an
    // authorization code that is exchanged for tokens in a second request.
    Codex,

    // RFC 8628: pending/backoff are error-body codes, and the poll returns the
    // token set directly on approval.
    Rfc8628,
}

// Daemon-private device session: how to poll, and what to show the user. `handle`
// is Codex's `device_auth_id` or the RFC 8628 `device_code`. Owned.
Device_Session :: struct {
    handle:           string,
    user_code:        string,
    verification_uri: string,
    interval_s:       u64,
    expires_in_s:     u64,
}

// The authorization grant a Codex device poll returns, exchanged for tokens in a
// second step. Owned.
Device_Grant :: struct {
    authorization_code: string,
    code_challenge:     string,
    code_verifier:      string,
}

// One classified device poll. `Device_Tokens`: body is a token set (RFC 8628);
// `Device_Exchange`: a grant to redeem (Codex); `Device_Failed.message` is static.
Device_Pending :: struct {}

Device_Slow_Down :: struct {}

Device_Tokens :: struct {}

Device_Exchange :: struct {
    grant: Device_Grant,
}

Device_Failed :: struct {
    message: string,
}

Device_Poll_Result :: union {
    Device_Pending,
    Device_Slow_Down,
    Device_Tokens,
    Device_Exchange,
    Device_Failed,
}

device_session_destroy :: proc(value: ^Device_Session, allocator := context.allocator) {
    assert(value != nil, "device session cleanup needs a value")
    secret.string_destroy(&value.handle, allocator)
    secret.string_destroy(&value.user_code, allocator)
    secret.string_destroy(&value.verification_uri, allocator)
    value^ = {}
}

device_grant_destroy :: proc(value: ^Device_Grant, allocator := context.allocator) {
    assert(value != nil, "device grant cleanup needs a value")
    secret.string_destroy(&value.authorization_code, allocator)
    secret.string_destroy(&value.code_challenge, allocator)
    secret.string_destroy(&value.code_verifier, allocator)
    value^ = {}
}

// Body + content-type for the first device-authorization request. `originator` is
// the client-identity value (RFC 8628 sends it as `referrer`; Codex ignores it).
device_auth_body :: proc(
    provider: ^Provider,
    originator: string,
    allocator := context.allocator,
) -> (
    body: string,
    content_type: string,
    err: OAuth_Error,
) {
    assert(provider != nil, "device request needs a provider")

    switch provider.device_profile {
    case .Codex:
        value, aerr := strings.concatenate({`{"client_id":"`, provider.client_id, `"}`}, allocator)
        if aerr != nil {
            return "", "", .Out_Of_Memory
        }

        return value, "application/json", .None

    case .Rfc8628:
        assert(provider.authorize_originator_param != "", "RFC 8628 device request needs a client-identity param")
        if originator == "" || len(originator) > 64 {
            return "", "", .Invalid_Input
        }

        client_id, client_err := url_encode(provider.client_id, allocator)
        scope, scope_err := url_encode(provider.scope, allocator)
        referrer, referrer_err := url_encode(originator, allocator)
        defer secret.string_destroy(&client_id, allocator)
        defer secret.string_destroy(&scope, allocator)
        defer secret.string_destroy(&referrer, allocator)
        if client_err != .None || scope_err != .None || referrer_err != .None {
            return "", "", .Out_Of_Memory
        }

        value, aerr := strings.concatenate(
            {"client_id=", client_id, "&scope=", scope, "&", provider.authorize_originator_param, "=", referrer},
            allocator,
        )
        if aerr != nil {
            return "", "", .Out_Of_Memory
        }

        return value, "application/x-www-form-urlencoded", .None
    }

    return "", "", .Invalid_Input
}

// Body + content-type for one device approval poll. Owned and secret.
device_poll_body :: proc(
    provider: ^Provider,
    session: Device_Session,
    allocator := context.allocator,
) -> (
    body: string,
    content_type: string,
    err: OAuth_Error,
) {
    assert(provider != nil, "device poll needs a provider")

    if !device_session_valid(session) {
        return "", "", .Invalid_Input
    }

    switch provider.device_profile {
    case .Codex:
        Payload :: struct {
            device_auth_id: string `json:"device_auth_id"`,
            user_code:      string `json:"user_code"`,
        }
        bytes, marshal_err := json.marshal(
            Payload{device_auth_id = session.handle, user_code = session.user_code},
            allocator = allocator,
        )
        if marshal_err != nil {
            return "", "", .Out_Of_Memory
        }

        return transmute(string)bytes, "application/json", .None

    case .Rfc8628:
        grant_type, grant_err := url_encode(DEVICE_CODE_GRANT_TYPE, allocator)
        client_id, client_err := url_encode(provider.client_id, allocator)
        device_code, device_err := url_encode(session.handle, allocator)
        defer secret.string_destroy(&grant_type, allocator)
        defer secret.string_destroy(&client_id, allocator)
        defer secret.string_destroy(&device_code, allocator)
        if grant_err != .None || client_err != .None || device_err != .None {
            return "", "", .Out_Of_Memory
        }

        value, aerr := strings.concatenate(
            {"grant_type=", grant_type, "&device_code=", device_code, "&client_id=", client_id},
            allocator,
        )
        if aerr != nil {
            return "", "", .Out_Of_Memory
        }

        return value, "application/x-www-form-urlencoded", .None
    }

    return "", "", .Invalid_Input
}

// Parse the device-authorization response into a pollable session. The machine
// handle stays daemon-private.
device_auth_parse :: proc(
    provider: ^Provider,
    data: string,
    allocator := context.allocator,
) -> (
    out: Device_Session,
    err: OAuth_Error,
) {
    assert(provider != nil, "device parse needs a provider")

    defer if err != .None {
        device_session_destroy(&out, allocator)
    }

    value, object, parse_err := json_object(data, allocator)
    if parse_err != .None {
        return {}, parse_err
    }
    defer secret_json_destroy(value, allocator)

    handle_key := provider.device_profile == .Codex ? "device_auth_id" : "device_code"
    handle, handle_ok := json_string_member(object, handle_key)
    user_code, code_ok := json_string_member(object, "user_code")
    if !code_ok {
        user_code, code_ok = json_string_member(object, "usercode")
    }
    if !handle_ok || !code_ok {
        return {}, .Invalid_Response
    }

    interval, interval_err := device_interval_member(object, provider.device_profile)
    if interval_err != .None {
        return {}, interval_err
    }

    expires_in_s := u64(CODEX_DEVICE_TIMEOUT_MS / 1000)
    if provider.device_profile == .Rfc8628 {
        expires, expires_present, expires_valid := json_optional_positive_u64_member(object, "expires_in")
        if !expires_present || !expires_valid || expires > DEVICE_CODE_LIFETIME_MAX_S {
            return {}, .Invalid_Response
        }
        expires_in_s = expires
    }

    verification := provider.device_verification_url
    if provider.device_profile == .Rfc8628 {
        uri, uri_ok := json_string_member(object, "verification_uri_complete")
        if !uri_ok {
            uri, uri_ok = json_string_member(object, "verification_uri")
        }
        if !uri_ok {
            return {}, .Invalid_Response
        }
        verification = uri
    }

    cloned_handle, handle_aerr := strings.clone(handle, allocator)
    if handle_aerr != nil {
        return {}, .Out_Of_Memory
    }
    out.handle = cloned_handle

    cloned_code, code_aerr := strings.clone(user_code, allocator)
    if code_aerr != nil {
        return {}, .Out_Of_Memory
    }
    out.user_code = cloned_code

    cloned_uri, uri_aerr := strings.clone(verification, allocator)
    if uri_aerr != nil {
        return {}, .Out_Of_Memory
    }
    out.verification_uri = cloned_uri
    out.interval_s = interval
    out.expires_in_s = expires_in_s

    if !device_session_valid(out) || out.verification_uri == "" {
        return {}, .Invalid_Response
    }

    return out, .None
}

// Classify one device poll response into the next step of the loop.
device_poll_classify :: proc(
    provider: ^Provider,
    status: int,
    data: string,
    allocator := context.allocator,
) -> (
    result: Device_Poll_Result,
    err: OAuth_Error,
) {
    assert(provider != nil, "device classify needs a provider")

    switch provider.device_profile {
    case .Codex:
        if status == 403 || status == 404 {
            return Device_Pending{}, .None
        }
        if status < 200 || status >= 300 {
            return Device_Failed{message = "device approval was rejected"}, .None
        }

        grant, grant_err := codex_device_grant_parse(data, allocator)
        if grant_err != .None {
            return {}, grant_err
        }

        return Device_Exchange{grant = grant}, .None

    case .Rfc8628:
        if status >= 200 && status < 300 {
            return Device_Tokens{}, .None
        }
        if status == 408 || status == 429 || status >= 500 {
            return Device_Pending{}, .None
        }

        return rfc8628_error_result(data, allocator), .None
    }

    return {}, .Invalid_Input
}

// Build the second-step token-exchange form for a Codex device grant.
device_grant_body :: proc(
    provider: ^Provider,
    grant: Device_Grant,
    allocator := context.allocator,
) -> (
    string,
    OAuth_Error,
) {
    assert(provider != nil && provider.device_profile == .Codex, "device grant exchange is Codex-only")

    flow := Authorization_Flow {
        verifier     = grant.code_verifier,
        redirect_uri = provider.device_redirect_uri,
    }

    return authorization_code_body(provider, flow, grant.authorization_code, allocator)
}

@(private)
codex_device_grant_parse :: proc(data: string, allocator: mem.Allocator) -> (out: Device_Grant, err: OAuth_Error) {
    defer if err != .None {
        device_grant_destroy(&out, allocator)
    }

    value, object, parse_err := json_object(data, allocator)
    if parse_err != .None {
        return {}, parse_err
    }
    defer secret_json_destroy(value, allocator)

    authorization_code, code_ok := json_string_member(object, "authorization_code")
    code_challenge, challenge_ok := json_string_member(object, "code_challenge")
    code_verifier, verifier_ok := json_string_member(object, "code_verifier")
    if !code_ok ||
       !challenge_ok ||
       !verifier_ok ||
       authorization_code == "" ||
       len(authorization_code) > AUTHORIZATION_CODE_MAX_BYTES ||
       code_challenge == "" ||
       len(code_challenge) > DEVICE_HANDLE_MAX_BYTES ||
       len(code_verifier) < 43 ||
       len(code_verifier) > 128 {
        return {}, .Invalid_Response
    }

    code, code_aerr := strings.clone(authorization_code, allocator)
    if code_aerr != nil {
        return {}, .Out_Of_Memory
    }
    out.authorization_code = code

    challenge, challenge_aerr := strings.clone(code_challenge, allocator)
    if challenge_aerr != nil {
        return {}, .Out_Of_Memory
    }
    out.code_challenge = challenge

    verifier, verifier_aerr := strings.clone(code_verifier, allocator)
    if verifier_aerr != nil {
        return {}, .Out_Of_Memory
    }
    out.code_verifier = verifier

    return out, .None
}

// Map an RFC 8628 error-body to a poll result. Unknown or malformed bodies are
// terminal rather than an infinite poll.
@(private)
rfc8628_error_result :: proc(data: string, allocator: mem.Allocator) -> Device_Poll_Result {
    value, object, parse_err := json_object(data, allocator)
    if parse_err != .None {
        return Device_Failed{message = "device approval failed"}
    }
    defer secret_json_destroy(value, allocator)

    code, code_ok := json_string_member(object, "error")
    if !code_ok {
        return Device_Failed{message = "device approval failed"}
    }

    switch code {
    case "authorization_pending":
        return Device_Pending{}

    case "slow_down":
        return Device_Slow_Down{}

    case "access_denied":
        return Device_Failed{message = "device login was denied"}

    case "expired_token":
        return Device_Failed{message = "device code expired"}
    }

    return Device_Failed{message = "device approval failed"}
}

// The positive integral poll interval. RFC 8628 defaults an absent value to five seconds;
// Codex's proprietary response is required to carry its string interval.
@(private)
device_interval_member :: proc(object: json.Object, profile: Device_Profile) -> (interval: u64, err: OAuth_Error) {
    interval_value, found := object["interval"]
    if !found {
        if profile == .Rfc8628 {
            return DEVICE_DEFAULT_POLL_INTERVAL_S, .None
        }

        return 0, .Invalid_Response
    }

    // Parser has `parse_integers` off, so RFC 8628's numeric interval arrives as a
    // float; Codex sends it as a string and rejects any numeric shape.
    #partial switch shape in interval_value {
    case json.String:
        parsed: bool
        interval, parsed = strconv.parse_u64(strings.trim_space(shape))
        if !parsed {
            return 0, .Invalid_Response
        }

    case json.Float:
        if profile == .Codex ||
           shape < DEVICE_POLL_INTERVAL_MIN_S ||
           shape > f64(DEVICE_POLL_INTERVAL_MAX_S) ||
           math.floor(shape) != shape {
            return 0, .Invalid_Response
        }
        interval = u64(shape)

    case:
        return 0, .Invalid_Response
    }

    if interval < DEVICE_POLL_INTERVAL_MIN_S || interval > DEVICE_POLL_INTERVAL_MAX_S {
        return 0, .Invalid_Response
    }

    return interval, .None
}

@(private)
device_session_valid :: proc(value: Device_Session) -> bool {
    return(
        value.handle != "" &&
        len(value.handle) <= DEVICE_HANDLE_MAX_BYTES &&
        value.user_code != "" &&
        len(value.user_code) <= DEVICE_USER_CODE_MAX_BYTES &&
        len(value.verification_uri) <= DEVICE_VERIFICATION_URL_MAX_BYTES &&
        value.interval_s >= DEVICE_POLL_INTERVAL_MIN_S &&
        value.interval_s <= DEVICE_POLL_INTERVAL_MAX_S &&
        value.expires_in_s > 0 &&
        value.expires_in_s <= DEVICE_CODE_LIFETIME_MAX_S \
    )
}
