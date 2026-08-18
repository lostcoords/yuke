package oauth

import "core:crypto"
import "core:crypto/sha2"
import "core:encoding/base64"
import "core:encoding/hex"
import "core:math"
import "core:mem"
import "core:strconv"
import "core:strings"
import "libs:json"


// OAuth credentials retained only by the daemon. Every string is owned by the
// containing daemon state or a short-lived operation.
OAuth_Credentials :: struct {
    access_token:  string,
    refresh_token: string,
    expires_at_ms: u64,
    account_id:    string,
}

// Errors from the OAuth flow mechanics (URL/body building, response parsing).
// Peer input degrades to these, never asserts.
OAuth_Error :: enum {
    None,
    Invalid_Input,
    Invalid_Response,
}

credentials_valid_for :: proc(provider: ^Provider, credentials: OAuth_Credentials) -> bool {
    assert(provider != nil, "credential validation needs a provider")

    return(
        credentials.access_token != "" &&
        credentials.refresh_token != "" &&
        credentials.expires_at_ms > 0 &&
        (provider.kind != .Codex || credentials.account_id != "") \
    )
}

credentials_destroy :: proc(credentials: ^OAuth_Credentials, allocator := context.allocator) {
    assert(credentials != nil, "credential cleanup needs a value")
    delete(credentials.access_token, allocator)
    delete(credentials.refresh_token, allocator)
    delete(credentials.account_id, allocator)
    credentials^ = {}
}

@(private)
credentials_clone :: proc(source: OAuth_Credentials, allocator := context.allocator) -> (out: OAuth_Credentials) {
    out.expires_at_ms = source.expires_at_ms
    out.access_token = strings.clone(source.access_token, allocator)
    out.refresh_token = strings.clone(source.refresh_token, allocator)
    out.account_id = strings.clone(source.account_id, allocator)

    return out
}

// Generic bound on an OAuth authorization code, shared across providers.
AUTHORIZATION_CODE_MAX_BYTES :: 4096

// Secrets and public URL for one browser authorization-code attempt. Owned.
Authorization_Flow :: struct {
    verifier:     string,
    state:        string,
    redirect_uri: string,
    auth_url:     string,
}

authorization_flow_destroy :: proc(flow: ^Authorization_Flow, allocator := context.allocator) {
    assert(flow != nil, "authorization flow cleanup needs a value")
    delete(flow.verifier, allocator)
    delete(flow.state, allocator)
    delete(flow.redirect_uri, allocator)
    delete(flow.auth_url, allocator)
    flow^ = {}
}

// Mint a PKCE S256 browser flow for a listener already bound to `port`.
authorization_flow_create :: proc(
    provider: ^Provider,
    port: int,
    originator: string,
    allocator := context.allocator,
) -> (
    flow: Authorization_Flow,
    err: OAuth_Error,
) {
    assert(provider != nil, "browser flow needs a provider")
    assert(provider.authorize_originator_param != "", "browser flow needs an originator parameter name")
    assert(
        provider.callback_host != "" && provider.callback_path != "" && provider.callback_path[0] == '/',
        "browser flow needs a loopback redirect host and path",
    )

    if port <= 0 || port > 65535 || originator == "" || len(originator) > 64 do return {}, .Invalid_Input

    defer if err != .None do authorization_flow_destroy(&flow, allocator)

    verifier_bytes: [32]byte
    crypto.rand_bytes(verifier_bytes[:])
    flow.verifier = base64url_encode(verifier_bytes[:], allocator)
    assert(len(flow.verifier) == 43, "32 random bytes yield a 43-byte PKCE verifier")

    state_bytes: [16]byte
    crypto.rand_bytes(state_bytes[:])
    state, _ := hex.encode(state_bytes[:], allocator)
    flow.state = transmute(string)state

    port_buf: [20]byte
    port_string := strconv.write_int(port_buf[:], i64(port), 10)
    flow.redirect_uri = strings.concatenate(
        {"http://", provider.callback_host, ":", port_string, provider.callback_path},
        allocator,
    )

    challenge, challenge_err := pkce_challenge(flow.verifier, allocator)
    if challenge_err != .None do return {}, challenge_err
    defer delete(challenge, allocator)

    client_id := url_encode(provider.client_id, allocator)
    redirect_uri := url_encode(flow.redirect_uri, allocator)
    scope := url_encode(provider.scope, allocator)
    encoded_challenge := url_encode(challenge, allocator)
    state_param := url_encode(flow.state, allocator)
    originator_param := url_encode(originator, allocator)
    defer delete(client_id, allocator)
    defer delete(redirect_uri, allocator)
    defer delete(scope, allocator)
    defer delete(encoded_challenge, allocator)
    defer delete(state_param, allocator)
    defer delete(originator_param, allocator)

    flow.auth_url = strings.concatenate(
        {
            provider.authorize_url,
            "?response_type=code&client_id=",
            client_id,
            "&redirect_uri=",
            redirect_uri,
            "&scope=",
            scope,
            "&code_challenge=",
            encoded_challenge,
            "&code_challenge_method=S256&state=",
            state_param,
            provider.authorize_extra_params,
            "&",
            provider.authorize_originator_param,
            "=",
            originator_param,
        },
        allocator,
    )

    return flow, .None
}

// Build the form body that redeems a browser callback code. Owned and secret.
authorization_code_body :: proc(
    provider: ^Provider,
    flow: Authorization_Flow,
    code: string,
    allocator := context.allocator,
) -> (
    body: string,
    err: OAuth_Error,
) {
    assert(provider != nil, "authorization-code body needs a provider")

    if code == "" || len(code) > AUTHORIZATION_CODE_MAX_BYTES || flow.verifier == "" || flow.redirect_uri == "" do return "", .Invalid_Input

    encoded_code := url_encode(code, allocator)
    encoded_redirect := url_encode(flow.redirect_uri, allocator)
    encoded_verifier := url_encode(flow.verifier, allocator)
    defer delete(encoded_code, allocator)
    defer delete(encoded_redirect, allocator)
    defer delete(encoded_verifier, allocator)

    value := strings.concatenate(
        {
            "grant_type=authorization_code&code=",
            encoded_code,
            "&redirect_uri=",
            encoded_redirect,
            "&client_id=",
            provider.client_id,
            "&code_verifier=",
            encoded_verifier,
        },
        allocator,
    )

    return value, .None
}

// Strict application/x-www-form-urlencoded value decode for an OAuth callback.
query_value_decode :: proc(input: string, allocator := context.allocator) -> (output: string, err: OAuth_Error) {
    if len(input) > AUTHORIZATION_CODE_MAX_BYTES * 3 do return "", .Invalid_Input

    decoded_len := 0
    index := 0
    for index < len(input) {
        if input[index] != '%' {
            decoded_len += 1
            index += 1
            continue
        }

        if index + 2 >= len(input) do return "", .Invalid_Input

        _, high_ok := hex_digit_value(input[index + 1])
        _, low_ok := hex_digit_value(input[index + 2])
        if !high_ok || !low_ok do return "", .Invalid_Input

        decoded_len += 1
        index += 3
    }

    decoded := make([]byte, decoded_len, allocator)
    defer if err != .None {
        if len(decoded) > 0 do crypto.zero_explicit(raw_data(decoded), len(decoded))
        delete(decoded, allocator)
    }

    at := 0
    index = 0
    for index < len(input) {
        switch input[index] {
        case '+':
            decoded[at] = ' '
            at += 1
            index += 1

        case '%':
            if index + 2 >= len(input) do return "", .Invalid_Input

            high, high_ok := hex_digit_value(input[index + 1])
            low, low_ok := hex_digit_value(input[index + 2])
            if !high_ok || !low_ok do return "", .Invalid_Input

            decoded[at] = high << 4 | low
            at += 1
            index += 3

        case:
            decoded[at] = input[index]
            at += 1
            index += 1
        }
    }

    assert(at == len(decoded), "query decoder filled its exact allocation")
    output = transmute(string)decoded

    return output, .None
}

// Parse a successful OAuth token response. Unknown response members are ignored;
// the required credential fields remain strict.
token_response_parse :: proc(
    provider: ^Provider,
    data: string,
    now_ms: u64,
    allocator := context.allocator,
) -> (
    credentials: OAuth_Credentials,
    err: OAuth_Error,
) {
    assert(provider != nil, "token parse needs a provider")

    defer if err != .None do credentials_destroy(&credentials, allocator)

    value, object, parse_err := json_object(data, allocator)
    if parse_err != .None {
        err = parse_err

        return
    }
    defer secret_json_destroy(value, allocator)

    id_token, id_token_ok := json_string_member(object, "id_token")
    access, access_ok := json_string_member(object, "access_token")
    refresh, refresh_ok := json_string_member(object, "refresh_token")
    expires_in, expires_present, expires_valid := json_optional_positive_u64_member(object, "expires_in")

    if !access_ok || access == "" || !refresh_ok || refresh == "" || !expires_valid {
        err = .Invalid_Response

        return
    }

    // Only Codex carries an account id, in its mandatory id_token; xAI needs no JWT.
    if provider.kind == .Codex {
        if !id_token_ok || id_token == "" {
            err = .Invalid_Response

            return
        }

        account_id, account_err := codex_account_id(id_token, allocator)
        if account_err != .None {
            err = account_err

            return
        }
        credentials.account_id = account_id
    }

    if jwt_expires_at, jwt_ok := jwt_expiration_ms(access, allocator); jwt_ok {
        credentials.expires_at_ms = jwt_expires_at
    } else if expires_present {
        if expires_in > (max(u64) - now_ms) / 1000 {
            err = .Invalid_Response

            return
        }

        credentials.expires_at_ms = now_ms + expires_in * 1000
    } else {
        credentials.expires_at_ms = now_ms + min(max(u64) - now_ms, provider.refresh_fallback_ms)
    }

    credentials.access_token = strings.clone(access, allocator)
    credentials.refresh_token = strings.clone(refresh, allocator)

    return credentials, .None
}

// Build a provider's refresh grant. Codex sends JSON; standard OAuth uses form encoding.
refresh_request_body :: proc(
    provider: ^Provider,
    refresh_token: string,
    allocator := context.allocator,
) -> (
    body: string,
    content_type: string,
    err: OAuth_Error,
) {
    assert(provider != nil, "refresh body needs a provider")

    if refresh_token == "" do return "", "", .Invalid_Input

    if provider.kind == .Codex {
        Payload :: struct {
            client_id:     string `json:"client_id"`,
            grant_type:    string `json:"grant_type"`,
            refresh_token: string `json:"refresh_token"`,
        }
        bytes, _ := json.marshal(
            Payload{client_id = provider.client_id, grant_type = "refresh_token", refresh_token = refresh_token},
            allocator = allocator,
        )

        return transmute(string)bytes, "application/json", .None
    }

    encoded_token := url_encode(refresh_token, allocator)
    defer delete(encoded_token, allocator)

    value := strings.concatenate(
        {"grant_type=refresh_token&client_id=", provider.client_id, "&refresh_token=", encoded_token},
        allocator,
    )

    return value, "application/x-www-form-urlencoded", .None
}

// Merge a successful refresh response into an existing credential set. Codex may
// omit rotated fields; a standard response must carry a fresh access token.
refresh_response_parse :: proc(
    provider: ^Provider,
    data: string,
    existing: OAuth_Credentials,
    now_ms: u64,
    allocator := context.allocator,
) -> (
    credentials: OAuth_Credentials,
    err: OAuth_Error,
) {
    assert(provider != nil, "refresh parse needs a provider")

    if !credentials_valid_for(provider, existing) do return {}, .Invalid_Input

    credentials = credentials_clone(existing, allocator)
    defer if err != .None do credentials_destroy(&credentials, allocator)

    value, object, parse_err := json_object(data, allocator)
    if parse_err != .None {
        err = parse_err

        return
    }
    defer secret_json_destroy(value, allocator)

    id_token, id_present, id_valid := json_optional_string_member(object, "id_token")
    access, access_present, access_valid := json_optional_string_member(object, "access_token")
    refresh, refresh_present, refresh_valid := json_optional_string_member(object, "refresh_token")
    expires_in, expires_present, expires_valid := json_optional_positive_u64_member(object, "expires_in")
    if !id_valid || !access_valid || !refresh_valid || !expires_valid {
        err = .Invalid_Response

        return
    }

    if provider.kind == .Xai && !access_present {
        err = .Invalid_Response

        return
    }

    // Re-project the Codex account id when its id_token rotates; xAI has none.
    if provider.kind == .Codex && id_present {
        account_id, account_err := codex_account_id(id_token, allocator)
        if account_err != .None {
            err = account_err

            return
        }

        delete(credentials.account_id, allocator)
        credentials.account_id = account_id
    }

    expires_at_ms := now_ms + min(max(u64) - now_ms, provider.refresh_fallback_ms)
    if expires_present {
        if expires_in > (max(u64) - now_ms) / 1000 {
            err = .Invalid_Response

            return
        }

        expires_at_ms = now_ms + expires_in * 1000
    }

    if access_present {
        delete(credentials.access_token, allocator)
        credentials.access_token = strings.clone(access, allocator)

        if jwt_expires_at, jwt_ok := jwt_expiration_ms(access, allocator); jwt_ok do expires_at_ms = jwt_expires_at
    } else {
        assert(provider.kind == .Codex, "only Codex may omit a refreshed access token")
    }
    credentials.expires_at_ms = expires_at_ms

    if refresh_present {
        delete(credentials.refresh_token, allocator)
        credentials.refresh_token = strings.clone(refresh, allocator)
    }

    assert(credentials_valid_for(provider, credentials), "refresh merge preserves complete credentials")

    return credentials, .None
}

// Whether a failed refresh says the rotating credential is permanently dead. Reads
// a nested `error.code` (Codex) or top-level `error` (OAuth) vs the terminal set.
refresh_failure_permanent :: proc(provider: ^Provider, data: string, allocator := context.allocator) -> bool {
    assert(provider != nil, "refresh classification needs a provider")

    value, object, parse_err := json_object(data, allocator)
    if parse_err != .None do return false
    defer secret_json_destroy(value, allocator)

    error_value, error_found := object["error"]
    if !error_found do return false

    code: string
    #partial switch shape in error_value {
    case json.Object:
        member, ok := json_string_member(shape, "code")
        if !ok do return false
        code = member

    case json.String:
        code = shape

    case:
        return false
    }

    for permanent in provider.refresh_permanent_codes {
        if code == permanent do return true
    }

    return false
}

// Proactive refresh window (`refresh_lead_ms` before expiry), saturating at the epoch.
oauth_needs_refresh :: proc(provider: ^Provider, expires_at_ms, now_ms: u64) -> bool {
    assert(provider != nil, "refresh window needs a provider")
    threshold := expires_at_ms - min(expires_at_ms, provider.refresh_lead_ms)

    return now_ms >= threshold
}

// Decode a JWT payload segment to its JSON object; signature is not verified.
// Payload bytes are wiped here; the caller releases `value` with `secret_json_destroy`.
@(private)
jwt_payload_object :: proc(
    token: string,
    allocator: mem.Allocator,
) -> (
    value: json.Value,
    object: json.Object,
    err: OAuth_Error,
) {
    first := strings.index_byte(token, '.')
    if first <= 0 || first + 1 >= len(token) do return {}, nil, .Invalid_Response

    rest := token[first + 1:]
    second := strings.index_byte(rest, '.')
    if second <= 0 do return {}, nil, .Invalid_Response

    decoded, decode_err := base64url_decode(rest[:second], allocator)
    if decode_err != .None do return {}, nil, decode_err
    defer {
        if len(decoded) > 0 do crypto.zero_explicit(raw_data(decoded), len(decoded))
        delete(decoded, allocator)
    }

    return json_object(string(decoded), allocator)
}

@(private)
jwt_expiration_ms :: proc(token: string, allocator: mem.Allocator) -> (u64, bool) {
    value, object, parse_err := jwt_payload_object(token, allocator)
    if parse_err != .None do return 0, false
    defer secret_json_destroy(value, allocator)

    seconds, seconds_present, seconds_valid := json_optional_positive_u64_member(object, "exp")
    if !seconds_present || !seconds_valid || seconds > max(u64) / 1000 do return 0, false

    return seconds * 1000, true
}

@(private)
pkce_challenge :: proc(verifier: string, allocator: mem.Allocator) -> (string, OAuth_Error) {
    if len(verifier) < 43 || len(verifier) > 128 do return "", .Invalid_Input

    hash: [sha2.DIGEST_SIZE_256]byte
    ctx: sha2.Context_256
    sha2.init_256(&ctx)
    sha2.update(&ctx, transmute([]byte)verifier)
    sha2.final(&ctx, hash[:])

    return base64url_encode(hash[:], allocator), .None
}

@(private)
base64url_encode :: proc(data: []byte, allocator: mem.Allocator) -> string {
    padded, _ := base64.encode(data, base64.ENC_URL_TABLE, allocator)
    defer delete(padded, allocator)

    end := len(padded)
    for end > 0 && padded[end - 1] == '=' {
        end -= 1
    }

    return strings.clone(padded[:end], allocator)
}

@(private)
base64url_decode :: proc(data: string, allocator: mem.Allocator) -> ([]byte, OAuth_Error) {
    if len(data) == 0 || len(data) % 4 == 1 do return nil, .Invalid_Response

    padded_len := (len(data) + 3) &~ 3
    padded := make([]byte, padded_len, allocator)
    defer {
        crypto.zero_explicit(raw_data(padded), len(padded))
        delete(padded, allocator)
    }

    copy(padded, transmute([]byte)data)
    for i in len(data) ..< len(padded) {
        padded[i] = '='
    }

    decoded, decode_err := base64.decode(string(padded), base64.DEC_URL_TABLE, allocator = allocator)
    if decode_err != nil do return nil, .Invalid_Response

    return decoded, .None
}

@(private)
url_encode :: proc(input: string, allocator: mem.Allocator) -> string {
    encoded_len := 0
    for c in transmute([]byte)input {
        encoded_len += 1 if url_unreserved(c) else 3
    }

    bytes := make([]byte, encoded_len, allocator)

    upper_hex := "0123456789ABCDEF"
    at := 0
    for c in transmute([]byte)input {
        if url_unreserved(c) {
            bytes[at] = c
            at += 1
        } else {
            bytes[at] = '%'
            bytes[at + 1] = upper_hex[c >> 4]
            bytes[at + 2] = upper_hex[c & 0x0f]
            at += 3
        }
    }
    assert(at == len(bytes), "percent encoder filled its exact allocation")

    return transmute(string)bytes
}

@(private)
url_unreserved :: proc(c: byte) -> bool {
    switch c {
    case 'A' ..= 'Z', 'a' ..= 'z', '0' ..= '9', '-', '.', '_', '~':
        return true
    }

    return false
}

@(private)
json_object :: proc(
    data: string,
    allocator: mem.Allocator,
) -> (
    value: json.Value,
    object: json.Object,
    err: OAuth_Error,
) {
    parser := json.make_parser_from_string(data, .JSON, false, allocator)
    parse_error: json.Error
    value, parse_error = json.parse_value(&parser)
    if parse_error != nil do return {}, nil, .Invalid_Response

    object_ok: bool
    object, object_ok = value.(json.Object)
    if !object_ok || parser.curr_token.kind != .EOF {
        json.destroy_value(value, allocator)
        return {}, nil, .Invalid_Response
    }

    return value, object, .None
}

@(private)
json_string_member :: proc(object: json.Object, name: string) -> (string, bool) {
    value, found := object[name]
    if !found do return "", false

    text, ok := value.(json.String)
    return text, ok
}

@(private)
json_optional_string_member :: proc(object: json.Object, name: string) -> (value: string, present, valid: bool) {
    member, found := object[name]
    if !found do return "", false, true

    if _, is_null := member.(json.Null); is_null do return "", false, true

    text, ok := member.(json.String)
    if !ok || text == "" do return "", true, false

    return text, true, true
}

@(private)
json_optional_positive_u64_member :: proc(
    object: json.Object,
    name: string,
) -> (
    number: u64,
    present: bool,
    valid: bool,
) {
    value, found := object[name]
    if !found do return 0, false, true
    present = true

    #partial switch candidate in value {
    case json.Integer:
        if candidate > 0 do return u64(candidate), true, true

    case json.Float:
        if candidate > 0 && candidate < f64(max(u64)) && math.floor(candidate) == candidate do return u64(candidate), true, true
    }

    return 0, true, false
}

@(private)
hex_digit_value :: proc(value: byte) -> (byte, bool) {
    switch value {
    case '0' ..= '9':
        return value - '0', true

    case 'a' ..= 'f':
        return value - 'a' + 10, true

    case 'A' ..= 'F':
        return value - 'A' + 10, true
    }

    return 0, false
}

@(private)
secret_json_destroy :: proc(value: json.Value, allocator: mem.Allocator) {
    secret_json_zero(value)
    json.destroy_value(value, allocator)
}

@(private)
secret_json_zero :: proc(value: json.Value) {
    #partial switch item in value {
    case json.Object:
        for object_key, child in item {
            if len(object_key) > 0 do crypto.zero_explicit(raw_data(transmute([]byte)object_key), len(object_key))
            secret_json_zero(child)
        }

    case json.Array:
        for child in item {
            secret_json_zero(child)
        }

    case json.String:
        if len(item) > 0 do crypto.zero_explicit(raw_data(transmute([]byte)item), len(item))
    }
}
