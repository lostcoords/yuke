//! The fake authorization server of the tests, on the port of the MCP endpoint `/mcp`.
//!
//! `MCP_TEST_OAUTH` turns it on. It holds a list of options, separated by commas:
//!
//! - `cimd` accepts the client id document of yuke as a client, and says so in its metadata.
//! - `dcr` registers clients at `/register`, and says so in its metadata.
//! - `iss` adds the issuer to each redirect, and says so in its metadata.
//! - `bare` leaves the metadata URL and the scope out of the `401` challenge.
//! - `oidc` serves its metadata only at the OIDC path.
//! - `nopkce` leaves the PKCE methods out of its metadata.
//! - `norotate` keeps a refresh token valid after its use, and gives no new one.
//!
//! The client id `preregistered` is always a client. `MCP_TEST_EXPIRES_IN` sets the seconds of an access token. Each
//! authorization server event goes to the log of the server: `authorize`, `register`, and `token`. Each request to
//! `/mcp` logs `bearer <token>` or `refused <token>`.
//!
//! The control requests `POST /test/expire` and `POST /test/revoke` end each access token, and each token, in turn.
//! `POST /test/token-down` makes `/token` answer `503`.

use std::collections::{HashMap, HashSet};
use std::sync::{LazyLock, Mutex, OnceLock};

use base64::Engine as _;
use base64::engine::general_purpose::URL_SAFE_NO_PAD;
use serde_json::{Value, json};
use sha2::{Digest as _, Sha256};

use crate::log;

/// The client id of the client id document of yuke.
const CLIENT_METADATA: &str = "https://yuke.sh/oauth/client.json";

/// The port of the server.
static PORT: OnceLock<u16> = OnceLock::new();

static STATE: LazyLock<Mutex<State>> = LazyLock::new(Mutex::default);

struct Code {
    client_id: String,
    redirect_uri: String,
    challenge: String,
}

#[derive(Default)]
struct State {
    /// The number of ids that the server gave, by prefix.
    counters: HashMap<String, u32>,
    codes: HashMap<String, Code>,
    /// The redirect of each registered client.
    clients: HashMap<String, String>,
    access: HashSet<String>,
    refresh: HashSet<String>,
    /// Whether `/token` answers `503`.
    token_down: bool,
}

impl State {
    fn next(&mut self, prefix: &str) -> String {
        let counter = self.counters.entry(prefix.to_owned()).or_default();
        *counter += 1;
        format!("{prefix}-{counter}")
    }
}

pub(crate) fn set_port(port: u16) {
    _ = PORT.set(port);
}

fn issuer() -> String {
    format!("http://127.0.0.1:{}", PORT.get().copied().unwrap_or_default())
}

fn option(name: &str) -> bool {
    std::env::var("MCP_TEST_OAUTH").is_ok_and(|options| options.split(',').any(|option| option == name))
}

/// Whether the fake server is on.
pub(crate) fn enabled() -> bool {
    std::env::var("MCP_TEST_OAUTH").is_ok()
}

fn answer(status: &str, headers: &str, body: &Value) -> String {
    let body = body.to_string();
    format!(
        "HTTP/1.1 {status}\r\ncontent-type: application/json\r\n{headers}content-length: {}\r\n\r\n{body}",
        body.len()
    )
}

/// The answer to a request of the authorization server, or `None` for a request to the MCP endpoint.
pub(crate) fn route(method: &str, target: &str, body: &[u8]) -> Option<String> {
    if !enabled() || target.split('?').next() == Some("/mcp") {
        return None;
    }
    let (path, query) = target.split_once('?').unwrap_or((target, ""));
    let issuer = issuer();
    let mut state = STATE.lock().unwrap_or_else(std::sync::PoisonError::into_inner);
    let state = &mut *state;
    Some(match (method, path) {
        ("GET", "/.well-known/oauth-protected-resource/mcp") => answer(
            "200 OK",
            "",
            &json!({
                "resource": format!("{issuer}/mcp"),
                "authorization_servers": [issuer],
                "scopes_supported": ["a", "b"],
            }),
        ),
        ("GET", "/.well-known/oauth-authorization-server") if !option("oidc") => {
            answer("200 OK", "", &metadata(&issuer))
        }
        ("GET", "/.well-known/openid-configuration") if option("oidc") => answer("200 OK", "", &metadata(&issuer)),
        ("GET", "/authorize") => authorize(state, &issuer, &parse(query)),
        ("POST", "/token") => token(state, &issuer, &parse(&String::from_utf8_lossy(body))),
        ("POST", "/register") if option("dcr") => {
            let request: Value = serde_json::from_slice(body).unwrap_or_default();
            let redirect = request["redirect_uris"][0].as_str().unwrap_or_default().to_owned();
            let id = state.next("client");
            _ = log(&format!("register {redirect}"));
            state.clients.insert(id.clone(), redirect);
            answer("201 Created", "", &json!({ "client_id": id }))
        }
        ("POST", "/test/expire") => {
            state.access.clear();
            answer("200 OK", "", &json!({}))
        }
        ("POST", "/test/token-down") => {
            state.token_down = true;
            answer("200 OK", "", &json!({}))
        }
        ("POST", "/test/revoke") => {
            state.access.clear();
            state.refresh.clear();
            answer("200 OK", "", &json!({}))
        }
        _ => answer("404 Not Found", "", &json!({ "error": "not_found" })),
    })
}

fn metadata(issuer: &str) -> Value {
    let mut metadata = json!({
        "issuer": issuer,
        "authorization_endpoint": format!("{issuer}/authorize"),
        "token_endpoint": format!("{issuer}/token"),
    });
    if !option("nopkce") {
        metadata["code_challenge_methods_supported"] = json!(["S256"]);
    }
    if option("cimd") {
        metadata["client_id_metadata_document_supported"] = json!(true);
    }
    if option("dcr") {
        metadata["registration_endpoint"] = json!(format!("{issuer}/register"));
    }
    if option("iss") {
        metadata["authorization_response_iss_parameter_supported"] = json!(true);
    }
    metadata
}

/// What the browser does after the approval of the user: it follows the redirect to the client.
fn authorize(state: &mut State, issuer: &str, query: &HashMap<String, String>) -> String {
    let get = |name: &str| query.get(name).map_or("", String::as_str);
    let refuse = |reason: &str| {
        answer(
            "400 Bad Request",
            "",
            &json!({ "error": "invalid_request", "error_description": reason }),
        )
    };
    _ = log(&format!("authorize client={} scope={}", get("client_id"), get("scope")));
    if get("response_type") != "code" || get("code_challenge_method") != "S256" || get("code_challenge").is_empty() {
        return refuse("the request needs a code with PKCE S256");
    }
    if get("resource") != format!("{issuer}/mcp") {
        return refuse("the resource is not the MCP server");
    }
    let client_id = get("client_id");
    let redirect_uri = get("redirect_uri");
    let known = match state.clients.get(client_id) {
        Some(registered) => registered == redirect_uri,
        None => (option("cimd") && client_id == CLIENT_METADATA) || client_id == "preregistered",
    };
    if !known || !redirect_uri.starts_with("http://127.0.0.1:") {
        return refuse("the client or its redirect is not known");
    }
    let code = state.next("code");
    state.codes.insert(
        code.clone(),
        Code {
            client_id: client_id.to_owned(),
            redirect_uri: redirect_uri.to_owned(),
            challenge: get("code_challenge").to_owned(),
        },
    );
    let iss = if option("iss") {
        format!("&iss={issuer}")
    } else {
        String::new()
    };
    let location = format!("{redirect_uri}?code={code}&state={}{iss}", get("state"));
    format!("HTTP/1.1 302 Found\r\nlocation: {location}\r\ncontent-length: 0\r\n\r\n")
}

fn token(state: &mut State, issuer: &str, form: &HashMap<String, String>) -> String {
    let get = |name: &str| form.get(name).map_or("", String::as_str);
    let grant = get("grant_type");
    _ = log(&format!("token {grant}"));
    let refuse = || answer("400 Bad Request", "", &json!({ "error": "invalid_grant" }));
    if state.token_down {
        return answer("503 Service Unavailable", "", &json!({}));
    }
    if get("resource") != format!("{issuer}/mcp") {
        return refuse();
    }
    match grant {
        "authorization_code" => {
            let Some(code) = state.codes.remove(get("code")) else {
                return refuse();
            };
            let challenge = URL_SAFE_NO_PAD.encode(Sha256::digest(get("code_verifier").as_bytes()));
            if code.client_id != get("client_id")
                || code.redirect_uri != get("redirect_uri")
                || code.challenge != challenge
            {
                return refuse();
            }
        }
        "refresh_token" => {
            let known = if option("norotate") {
                state.refresh.contains(get("refresh_token"))
            } else {
                state.refresh.remove(get("refresh_token"))
            };
            if !known {
                return refuse();
            }
        }
        _ => return refuse(),
    }
    let access = state.next("access");
    state.access.insert(access.clone());
    let expires_in: u64 = std::env::var("MCP_TEST_EXPIRES_IN")
        .ok()
        .and_then(|seconds| seconds.parse().ok())
        .unwrap_or(3600);
    let mut tokens = json!({ "access_token": access, "token_type": "Bearer", "expires_in": expires_in });
    if grant == "authorization_code" || !option("norotate") {
        let refresh = state.next("refresh");
        state.refresh.insert(refresh.clone());
        tokens["refresh_token"] = json!(refresh);
    }
    answer("200 OK", "", &tokens)
}

/// `None` when the request to `/mcp` carries a valid token, else the `401` answer.
pub(crate) fn challenge(authorization: Option<&str>) -> Option<String> {
    let token = authorization
        .and_then(|value| value.strip_prefix("Bearer "))
        .unwrap_or_default();
    let valid = STATE
        .lock()
        .unwrap_or_else(std::sync::PoisonError::into_inner)
        .access
        .contains(token);
    if valid {
        _ = log(&format!("bearer {token}"));
        return None;
    }
    _ = log(&format!("refused {token}"));
    let issuer = issuer();
    let parameters = if option("bare") {
        r#"realm="test""#.to_owned()
    } else {
        format!(r#"resource_metadata="{issuer}/.well-known/oauth-protected-resource/mcp", scope="files:read""#)
    };
    Some(answer(
        "401 Unauthorized",
        &format!("www-authenticate: Bearer {parameters}\r\n"),
        &json!({ "error": "unauthorized" }),
    ))
}

/// The parameters of a query or a form, decoded.
fn parse(text: &str) -> HashMap<String, String> {
    text.split('&')
        .filter_map(|pair| pair.split_once('='))
        .map(|(name, value)| (decode(name), decode(value)))
        .collect()
}

fn decode(text: &str) -> String {
    let bytes = text.as_bytes();
    let mut decoded = Vec::new();
    let mut index = 0;
    while index < bytes.len() {
        match bytes[index] {
            b'+' => decoded.push(b' '),
            b'%' if index + 2 < bytes.len() => {
                let hex = std::str::from_utf8(&bytes[index + 1..index + 3]).unwrap_or_default();
                decoded.push(u8::from_str_radix(hex, 16).unwrap_or_default());
                index += 2;
            }
            byte => decoded.push(byte),
        }
        index += 1;
    }
    String::from_utf8_lossy(&decoded).into_owned()
}
