//! The login of a server: the authorization code flow with PKCE (OAuth 2.1), with a redirect to a listener on
//! 127.0.0.1.

use std::fmt;
use std::net::Ipv4Addr;

use base64::Engine as _;
use base64::engine::general_purpose::URL_SAFE_NO_PAD;
use futures_util::FutureExt as _;
use futures_util::future::LocalBoxFuture;
use serde_json::{Value, json};
use sha2::{Digest as _, Sha256};
use tokio::io::{AsyncBufReadExt as _, AsyncWriteExt as _, BufReader};
use tokio::net::{TcpListener, TcpStream};
use tokio::sync::mpsc;
use tokio::task::JoinSet;
use yuke_ai::oauth::form;
use yuke_http::http::HeaderMap;

use super::store::StoredLogin;
use super::{Auth, CLIENT_METADATA, blocking, discover, exchange, post, request_tokens, server_metadata};

/// Why a login or a logout did not happen.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum LoginError {
    /// The request does not fit: the server does not exist, needs no login, or is not a remote server, or an address
    /// is not the redirect of the login.
    Refused(String),
    /// The login or the stored logins failed: the metadata of the server, its authorization server, or a file.
    Failed(String),
    /// A cancel ended the login before its redirect came.
    Cancelled,
}

impl fmt::Display for LoginError {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            Self::Refused(text) | Self::Failed(text) => f.write_str(text),
            Self::Cancelled => f.write_str("the login was cancelled"),
        }
    }
}

impl std::error::Error for LoginError {}

/// A login that waits for the user. The user opens [`PendingLogin::url`], and the browser redirects to the listener of
/// the login. A client that cannot reach the listener gives the address of the redirect to [`PendingLogin::complete`].
pub struct PendingLogin {
    url: String,
    expect: Expect,
    events: mpsc::UnboundedSender<Event>,
}

impl fmt::Debug for PendingLogin {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.debug_struct("PendingLogin")
            .field("url", &self.url)
            .finish_non_exhaustive()
    }
}

impl PendingLogin {
    /// The page where the user approves the login.
    pub fn url(&self) -> &str {
        &self.url
    }

    /// Finish the login with `redirect_url`, the address that the browser ended on.
    ///
    /// # Errors
    ///
    /// Returns [`LoginError::Refused`] when the address is not the redirect of this login. The login then keeps its
    /// wait. The call also returns it when the login ended.
    pub fn complete(&self, redirect_url: &str) -> Result<(), LoginError> {
        let query = redirect_url
            .split('#')
            .next()
            .and_then(|url| url.split_once('?'))
            .map_or("", |(_, query)| query);
        let event = self.expect.check(query).map_err(LoginError::Refused)?;
        self.events
            .send(event)
            .map_err(|_| LoginError::Refused("the login ended".to_owned()))
    }

    /// End the login while it waits for the redirect. Its outcome is [`LoginError::Cancelled`]. After the redirect
    /// came, a cancel does nothing: the login stores the tokens, and the server connects.
    pub fn cancel(&self) {
        // The send fails only for an ended login, which has nothing to cancel.
        _ = self.events.send(Event::Cancelled);
    }
}

/// What a login waits for.
enum Event {
    Code(String),
    /// The authorization server ended the login, for example because the user refused.
    Failed(String),
    Cancelled,
}

/// What a redirect must hold to belong to its login.
#[derive(Clone)]
struct Expect {
    state: String,
    /// The issuer that the redirect names, for an authorization server that names it (RFC 9207).
    issuer: Option<String>,
}

impl Expect {
    /// What the redirect with `query` means for the login.
    ///
    /// # Errors
    ///
    /// Returns why the redirect is not for this login.
    fn check(&self, query: &str) -> Result<Event, String> {
        let parameter = |name: &str| {
            query
                .split('&')
                .filter_map(|pair| pair.split_once('='))
                .find(|(key, _)| *key == name)
                .map(|(_, value)| decode(value))
        };
        if parameter("state").as_deref() != Some(&self.state) {
            return Err("the state of the redirect is not the state of this login".to_owned());
        }
        if let Some(issuer) = &self.issuer
            && parameter("iss").as_ref() != Some(issuer)
        {
            return Err("the issuer of the redirect is not the issuer of the server".to_owned());
        }
        if let Some(error) = parameter("error") {
            return Ok(Event::Failed(format!(
                "the authorization server refused the login: {error}"
            )));
        }
        parameter("code")
            .map(Event::Code)
            .ok_or_else(|| "the redirect holds no code".to_owned())
    }
}

/// `text` with each `%XX` and each `+` decoded.
fn decode(text: &str) -> String {
    let mut bytes = text.bytes();
    let mut decoded = Vec::new();
    while let Some(byte) = bytes.next() {
        match byte {
            b'+' => decoded.push(b' '),
            b'%' => {
                let hex: Vec<u8> = bytes.by_ref().take(2).collect();
                // A broken escape cannot match the state of a login.
                let digit = std::str::from_utf8(&hex)
                    .ok()
                    .and_then(|hex| u8::from_str_radix(hex, 16).ok());
                decoded.push(digit.unwrap_or(b'?'));
            }
            byte => decoded.push(byte),
        }
    }
    String::from_utf8_lossy(&decoded).into_owned()
}

/// `length` random bytes as base64url text without padding.
fn random_text(length: usize) -> Result<String, String> {
    let mut bytes = vec![0; length];
    rustls::crypto::aws_lc_rs::default_provider()
        .secure_random
        .fill(&mut bytes)
        .map_err(|_| "the system gave no random bytes".to_owned())?;
    Ok(URL_SAFE_NO_PAD.encode(bytes))
}

impl Auth {
    /// Prepare a login: choose the client, and listen for the redirect. The result holds the page of the user, and the
    /// future of the end of the login. The future stores the tokens, and it needs a tokio local runtime. A drop of the
    /// future ends the login.
    ///
    /// # Errors
    ///
    /// Returns why the server cannot log in: its metadata is missing, its authorization server lacks PKCE with `S256`
    /// or a way to get a client id, or the listener does not open.
    pub(crate) async fn login(
        &self,
    ) -> Result<(PendingLogin, LocalBoxFuture<'static, Result<(), LoginError>>), String> {
        let kept = self.discovery.lock().await.clone();
        let discovery = match kept {
            Some(discovery) => discovery,
            // A server that a logout stopped has no refused request to learn from.
            None => discover(&self.client, &self.remote.url, &HeaderMap::new()).await?,
        };
        let issuer = discovery
            .resource
            .authorization_servers
            .first()
            .ok_or("the server names no authorization server")?;
        let server = server_metadata(&self.client, issuer).await?;
        if !server
            .code_challenge_methods_supported
            .iter()
            .any(|method| method == "S256")
        {
            return Err(format!(
                "the authorization server {issuer} does not support PKCE with S256"
            ));
        }

        let port = self.remote.oauth.callback_port.unwrap_or(0);
        let listener = TcpListener::bind((Ipv4Addr::LOCALHOST, port))
            .await
            .map_err(|error| format!("the login cannot listen on port {port} of 127.0.0.1: {error}"))?;
        let port = listener.local_addr().map_err(|error| error.to_string())?.port();
        let redirect_uri = format!("http://127.0.0.1:{port}/callback");

        let client_id = if let Some(client_id) = &self.remote.oauth.client_id {
            client_id.clone()
        } else if server.client_id_metadata_document_supported {
            CLIENT_METADATA.to_owned()
        } else if let Some(endpoint) = &server.registration_endpoint {
            self.register(endpoint, &redirect_uri).await?
        } else {
            return Err(format!(
                "the authorization server {issuer} gives yuke no client id: \
                 set oauth.clientId in the entry of the server"
            ));
        };

        let verifier = random_text(32)?;
        let state = random_text(16)?;
        let supported = &discovery.resource.scopes_supported;
        let scope = discovery
            .scope
            .or_else(|| (!supported.is_empty()).then(|| supported.join(" ")));
        let code_challenge = URL_SAFE_NO_PAD.encode(Sha256::digest(verifier.as_bytes()));
        let mut fields = vec![
            ("response_type", "code"),
            ("client_id", &client_id),
            ("redirect_uri", &redirect_uri),
            ("code_challenge", &code_challenge),
            ("code_challenge_method", "S256"),
            ("state", &state),
            ("resource", &self.remote.resource),
        ];
        if let Some(scope) = &scope {
            fields.push(("scope", scope));
        }
        let endpoint = &server.authorization_endpoint;
        let separator = if endpoint.contains('?') { '&' } else { '?' };
        let url = format!("{endpoint}{separator}{}", form(&fields));

        let expect = Expect {
            state,
            issuer: server
                .authorization_response_iss_parameter_supported
                .then(|| server.issuer.clone().unwrap_or_else(|| issuer.clone())),
        };
        let (events, received) = mpsc::unbounded_channel();
        let login = PendingLogin {
            url,
            expect: expect.clone(),
            events: events.clone(),
        };
        let (client, store, resource) = (self.client.clone(), self.store.clone(), self.remote.resource.clone());
        let token_endpoint = server.token_endpoint;
        let outcome = async move {
            let code = wait(listener, expect, events, received).await?;
            let fields = [
                ("grant_type", "authorization_code"),
                ("code", &code),
                ("code_verifier", &verifier),
                ("redirect_uri", &redirect_uri),
                ("client_id", &client_id),
                ("resource", &resource),
            ];
            let tokens = request_tokens(&client, &token_endpoint, &fields).await?;
            let stored = StoredLogin {
                client_id,
                token_endpoint,
                access_token: tokens.access_token,
                refresh_token: tokens.refresh_token,
                expires_at: tokens.expires_at,
            };
            blocking(&store, |store| store.lock()?.set_login(Some(stored)))
                .await
                .map_err(LoginError::Failed)
        };
        // The box keeps the future of a caller small.
        Ok((login, outcome.boxed_local()))
    }

    /// Register yuke at `endpoint` with the redirect `redirect_uri` (RFC 7591).
    async fn register(&self, endpoint: &str, redirect_uri: &str) -> Result<String, String> {
        let body = json!({
            "client_name": "yuke",
            "redirect_uris": [redirect_uri],
            "grant_types": ["authorization_code", "refresh_token"],
            "response_types": ["code"],
            "token_endpoint_auth_method": "none",
        });
        let (status, answer) = exchange(&self.client, post(endpoint, "application/json", body.to_string()))
            .await
            .map_err(|error| format!("{endpoint}: {error}"))?;
        let answer: Value = serde_json::from_slice(&answer).unwrap_or_default();
        match answer["client_id"].as_str() {
            Some(client_id) if status.is_success() => Ok(client_id.to_owned()),
            _ => Err(format!(
                "{endpoint}: the registration of yuke failed with HTTP {status}"
            )),
        }
    }
}

/// Wait for the code of the login: from the listener, or from [`PendingLogin::complete`].
async fn wait(
    listener: TcpListener,
    expect: Expect,
    events: mpsc::UnboundedSender<Event>,
    mut received: mpsc::UnboundedReceiver<Event>,
) -> Result<String, LoginError> {
    // A browser can open a connection and send nothing, so each connection has a task. A drop of the set ends them.
    let mut connections = JoinSet::new();
    loop {
        tokio::select! {
            accepted = listener.accept() => {
                if let Ok((stream, _)) = accepted {
                    connections.spawn_local(serve(stream, expect.clone(), events.clone()));
                }
            }
            event = received.recv() => {
                return match event {
                    Some(Event::Code(code)) => Ok(code),
                    Some(Event::Failed(text)) => Err(LoginError::Failed(text)),
                    Some(Event::Cancelled) | None => Err(LoginError::Cancelled),
                };
            }
        }
    }
}

/// Answer one request of the listener. The redirect of the login goes to the login. Another request gets an error.
async fn serve(mut stream: TcpStream, expect: Expect, events: mpsc::UnboundedSender<Event>) {
    let mut line = String::new();
    if BufReader::new(&mut stream).read_line(&mut line).await.is_err() {
        return;
    }
    let target = line.split(' ').nth(1).unwrap_or_default();
    let (path, query) = target.split_once('?').unwrap_or((target, ""));
    let (status, text) = if path == "/callback" {
        match expect.check(query) {
            Ok(event) => {
                let text = match event {
                    Event::Failed(_) => "The login failed. Go back to yuke.",
                    _ => "You are logged in. You can close this page.",
                };
                // The send fails when the login ended already, and then nobody needs the event.
                _ = events.send(event);
                ("200 OK", text)
            }
            Err(_) => ("400 Bad Request", "This is not the redirect of the login of yuke."),
        }
    } else {
        ("404 Not Found", "Not found.")
    };
    let page = format!("<!doctype html><meta charset=utf-8><title>yuke</title><p>{text}</p>");
    let answer = format!(
        "HTTP/1.1 {status}\r\ncontent-type: text/html\r\ncontent-length: {}\r\nconnection: close\r\n\r\n{page}",
        page.len()
    );
    // A browser that went away needs no answer.
    _ = stream.write_all(answer.as_bytes()).await;
}
