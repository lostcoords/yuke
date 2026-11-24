//! OAuth for the remote servers (the MCP authorization spec of 2025-11-25). [`Auth`] gives the bearer token of one
//! server, and it refreshes the token. [`PendingLogin`] gets the first token in a browser.

mod login;
mod store;

use std::sync::Arc;
use std::time::{Duration, SystemTime, UNIX_EPOCH};

use serde::Deserialize;
use serde::de::DeserializeOwned;
use serde_json::Value;
use tokio::sync::{Mutex, watch};
use yuke_ai::oauth::form;
use yuke_http::http::header::{ACCEPT, CONTENT_TYPE, WWW_AUTHENTICATE};
use yuke_http::http::{HeaderMap, HeaderValue, Method, StatusCode, Uri};
use yuke_http::{Client, Error, Request};

pub use login::PendingLogin;
use store::{Store, StoredLogin};

use crate::config::{OAuthConfig, Remote};

/// A token that ends within this margin refreshes before the request.
const MARGIN: Duration = Duration::from_mins(1);

/// The idle time and the whole time of one OAuth request.
const TIMEOUT: Duration = Duration::from_secs(30);

/// An answer of an OAuth server is small, so a larger one is cut and then fails to read.
const MAX_ANSWER: usize = 256 * 1024;

/// The client of yuke for the authorization servers that read a client id document.
const CLIENT_METADATA: &str = "https://yuke.sh/oauth/client.json";

/// The login of one remote server.
pub(crate) struct Auth {
    client: Arc<Client>,
    store: Store,
    /// The canonical URL of the server, the `resource` of each request (RFC 8707).
    resource: String,
    config: OAuthConfig,
    /// What the last refused request taught about the authorization of the server.
    discovery: Mutex<Option<Discovery>>,
    /// Whether the server needs a login: it refused a request without a token, or its login ended.
    needs_login: watch::Sender<bool>,
}

impl Auth {
    pub(crate) fn new(client: Arc<Client>, data: &std::path::Path, remote: &Remote) -> Auth {
        Auth {
            client,
            store: Store::new(data, &remote.url),
            resource: remote.resource.clone(),
            config: remote.oauth.clone(),
            discovery: Mutex::default(),
            needs_login: watch::channel(false).0,
        }
    }

    pub(crate) fn needs_login(&self) -> bool {
        *self.needs_login.borrow()
    }

    pub(crate) fn set_needs_login(&self, needed: bool) {
        self.needs_login.send_replace(needed);
    }

    /// Wait until the server needs a login.
    pub(crate) async fn wait_for_needs_login(&self) {
        _ = self.needs_login.subscribe().wait_for(|needed| *needed).await;
    }

    /// The access token for the next request, refreshed when it ends soon. `None` when the server has no login.
    ///
    /// # Errors
    ///
    /// Returns why a refresh failed for now, when the token does not serve any more. The login stays.
    pub(crate) async fn token(&self) -> Result<Option<String>, String> {
        let store = self.store.clone();
        let Some(stored) = blocking(move || store.login()).await? else {
            return Ok(None);
        };
        if stored.valid(MARGIN) {
            return Ok(Some(stored.access_token));
        }
        match self.refresh(None).await {
            // A token that still lives serves the request when the refresh fails for now.
            Err(_) if stored.valid(Duration::ZERO) => Ok(Some(stored.access_token)),
            refreshed => refreshed,
        }
    }

    /// Change the login for a new access token. The refresh skips the request when another process already renewed the
    /// token, that is, when the stored token is valid and is not `rejected`. `None` when the login ended.
    ///
    /// # Errors
    ///
    /// Returns why the refresh failed for now. The login stays.
    pub(crate) async fn refresh(&self, rejected: Option<&str>) -> Result<Option<String>, String> {
        let store = self.store.clone();
        let (locked, stored) = blocking(move || {
            let locked = store.lock()?;
            let stored = locked.login()?;
            Ok((locked, stored))
        })
        .await?;
        let renewed = match stored {
            Some(stored) if stored.valid(MARGIN) && rejected != Some(&stored.access_token) => {
                return Ok(Some(stored.access_token));
            }
            Some(stored) => self.renew(stored).await?,
            None => None,
        };
        let token = renewed.as_ref().map(|renewed| renewed.access_token.clone());
        if token.is_none() {
            self.set_needs_login(true);
        }
        // The new token serves this request, even when the save fails.
        _ = blocking(move || locked.set_login(renewed)).await;
        Ok(token)
    }

    /// The stored login after a refresh request, or `None` when the login ended.
    async fn renew(&self, stored: StoredLogin) -> Result<Option<StoredLogin>, String> {
        let Some(refresh_token) = stored.refresh_token.clone() else {
            return Ok(None);
        };
        let fields = [
            ("grant_type", "refresh_token"),
            ("refresh_token", &refresh_token),
            ("client_id", &stored.client_id),
            ("resource", &self.resource),
        ];
        match request_tokens(&self.client, &stored.token_endpoint, &fields).await {
            Ok(tokens) => Ok(Some(StoredLogin {
                access_token: tokens.access_token,
                // An answer without a new refresh token keeps the old one.
                refresh_token: tokens.refresh_token.or(Some(refresh_token)),
                expires_at: tokens.expires_at,
                ..stored
            })),
            Err(TokenError::Permanent(_)) => Ok(None),
            Err(TokenError::Transient(text)) => Err(format!("the login of the server did not refresh: {text}")),
        }
    }

    /// Learn from a `401` answer with the headers `headers`: when they lead to OAuth metadata, the server needs a
    /// login.
    pub(crate) async fn challenged(&self, headers: &HeaderMap) {
        if let Ok(discovery) = discover(&self.client, &self.store.url, headers).await {
            *self.discovery.lock().await = Some(discovery);
            self.set_needs_login(true);
        }
    }

    /// Remove the stored login. A server that had one needs a login again.
    pub(crate) async fn logout(&self) -> Result<(), String> {
        let store = self.store.clone();
        let had = blocking(move || {
            let locked = store.lock()?;
            let had = locked.login()?.is_some();
            locked.set_login(None)?;
            Ok(had)
        })
        .await?;
        if had {
            self.set_needs_login(true);
        }
        Ok(())
    }
}

/// Run `f` on a blocking thread of tokio, because the file calls block.
async fn blocking<T: Send + 'static>(f: impl FnOnce() -> Result<T, String> + Send + 'static) -> Result<T, String> {
    tokio::task::spawn_blocking(f)
        .await
        .map_err(|error| format!("a file call of the login stopped: {error}"))?
}

/// What a server taught about its authorization.
#[derive(Clone)]
struct Discovery {
    /// The scope that its `401` answer asked for.
    scope: Option<String>,
    resource: ResourceMetadata,
}

/// The protected resource metadata of the server `url`, at the URL that the `WWW-Authenticate` headers of its `401`
/// answer give (RFC 9728, section 5.1), else at the well-known URLs, with the path of the server first.
async fn discover(client: &Client, url: &str, headers: &HeaderMap) -> Result<Discovery, String> {
    let urls = if let Some(metadata) = parameter(headers, "resource_metadata") {
        vec![metadata]
    } else {
        let (origin, path) = split(url)?;
        let root = format!("{origin}/.well-known/oauth-protected-resource");
        if path.is_empty() {
            vec![root]
        } else {
            vec![format!("{root}{path}"), root]
        }
    };
    Ok(Discovery {
        scope: parameter(headers, "scope"),
        resource: first_document(client, &urls).await?,
    })
}

/// The quoted value of the parameter `name` in the first `Bearer` challenge of the `WWW-Authenticate` headers.
fn parameter(headers: &HeaderMap, name: &str) -> Option<String> {
    let mut values = headers
        .get_all(WWW_AUTHENTICATE)
        .iter()
        .filter_map(|value| value.to_str().ok());
    let bearer = values.find(|value| value.trim_start().to_ascii_lowercase().starts_with("bearer "))?;
    let start = bearer.find(&format!("{name}=\""))? + name.len() + 2;
    let length = bearer[start..].find('"')?;
    Some(bearer[start..start + length].to_owned())
}

/// The scheme and authority of `url`, and its path without a trailing slash.
fn split(url: &str) -> Result<(String, String), String> {
    let uri: Uri = url.parse().map_err(|_| format!("{url} is not a URL"))?;
    let (Some(scheme), Some(authority)) = (uri.scheme_str(), uri.authority()) else {
        return Err(format!("{url} is not an absolute URL"));
    };
    Ok((
        format!("{scheme}://{authority}"),
        uri.path().trim_end_matches('/').to_owned(),
    ))
}

/// The canonical URL of the server, as the `resource` parameter of RFC 8707 names it: no query, no fragment, and no
/// trailing slash.
pub(crate) fn canonical(url: &str) -> Result<String, String> {
    let (origin, path) = split(url)?;
    Ok(format!("{origin}{path}"))
}

/// The protected resource metadata of RFC 9728.
#[derive(Clone, Deserialize)]
struct ResourceMetadata {
    #[serde(default)]
    authorization_servers: Vec<String>,
    #[serde(default)]
    scopes_supported: Vec<String>,
}

/// The authorization server metadata of RFC 8414 and OIDC Discovery.
#[derive(Deserialize)]
struct ServerMetadata {
    issuer: Option<String>,
    authorization_endpoint: String,
    token_endpoint: String,
    registration_endpoint: Option<String>,
    #[serde(default)]
    code_challenge_methods_supported: Vec<String>,
    #[serde(default)]
    client_id_metadata_document_supported: bool,
    #[serde(default)]
    authorization_response_iss_parameter_supported: bool,
}

/// The metadata of the authorization server `issuer`. Each endpoint must use HTTPS, so the code and the tokens never
/// cross the network in plain text. Only an endpoint on this computer can use HTTP.
async fn server_metadata(client: &Client, issuer: &str) -> Result<ServerMetadata, String> {
    let metadata: ServerMetadata = first_document(client, &server_metadata_urls(issuer)?).await?;
    let endpoints = [
        Some(&metadata.authorization_endpoint),
        Some(&metadata.token_endpoint),
        metadata.registration_endpoint.as_ref(),
    ];
    for endpoint in endpoints.into_iter().flatten() {
        let uri: Uri = endpoint.parse().map_err(|_| format!("{endpoint} is not a URL"))?;
        let local = matches!(uri.host(), Some("localhost" | "127.0.0.1" | "[::1]"));
        if uri.scheme_str() != Some("https") && !(local && uri.scheme_str() == Some("http")) {
            return Err(format!(
                "the authorization server {issuer} names {endpoint}, which does not use HTTPS"
            ));
        }
    }
    Ok(metadata)
}

/// The well-known URLs of the metadata of `issuer`, in the order of the MCP spec.
fn server_metadata_urls(issuer: &str) -> Result<Vec<String>, String> {
    let (origin, path) = split(issuer)?;
    Ok(if path.is_empty() {
        vec![
            format!("{origin}/.well-known/oauth-authorization-server"),
            format!("{origin}/.well-known/openid-configuration"),
        ]
    } else {
        vec![
            format!("{origin}/.well-known/oauth-authorization-server{path}"),
            format!("{origin}/.well-known/openid-configuration{path}"),
            format!("{origin}{path}/.well-known/openid-configuration"),
        ]
    })
}

/// The first of `urls` that answers with a JSON document of the type `T`.
async fn first_document<T: DeserializeOwned>(client: &Client, urls: &[String]) -> Result<T, String> {
    for url in urls {
        let mut request = Request::new(Method::GET, url);
        request
            .headers
            .insert(ACCEPT, HeaderValue::from_static("application/json"));
        if let Ok((status, body)) = exchange(client, request).await
            && status.is_success()
            && let Ok(document) = serde_json::from_slice(&body)
        {
            return Ok(document);
        }
    }
    Err(format!("found no OAuth metadata at {}", urls.join(" or ")))
}

/// Send `request` within [`TIMEOUT`], and read the whole answer.
async fn exchange(client: &Client, mut request: Request) -> Result<(StatusCode, Vec<u8>), Error> {
    request.idle_timeout = Some(TIMEOUT);
    request.deadline = Some(std::time::Instant::now() + TIMEOUT);
    let mut response = client.send(request).await?;
    let mut bytes = Vec::new();
    while bytes.len() <= MAX_ANSWER
        && let Some(chunk) = response.body.chunk().await
    {
        bytes.extend_from_slice(&chunk?);
    }
    Ok((response.status, bytes))
}

/// The tokens of a token answer (RFC 6749, section 5.1).
struct Tokens {
    access_token: String,
    refresh_token: Option<String>,
    expires_at: Option<u64>,
}

/// Why a token request failed.
enum TokenError {
    /// The grant is gone, or its token can be spent. Only a new login recovers it.
    Permanent(String),
    /// The request failed for now, and a repeat with the same token is safe.
    Transient(String),
}

impl TokenError {
    fn text(self) -> String {
        match self {
            Self::Permanent(text) | Self::Transient(text) => text,
        }
    }
}

/// Post the form `fields` to the token endpoint `endpoint`. A refresh repeats only when the request provably never
/// left, as for the logins of the providers.
async fn request_tokens(client: &Client, endpoint: &str, fields: &[(&str, &str)]) -> Result<Tokens, TokenError> {
    let mut request = Request::new(Method::POST, endpoint);
    let form_type = HeaderValue::from_static("application/x-www-form-urlencoded");
    request.headers.insert(CONTENT_TYPE, form_type);
    request
        .headers
        .insert(ACCEPT, HeaderValue::from_static("application/json"));
    request.body = vec![form(fields).into_bytes().into()];
    let (status, body) = match exchange(client, request).await {
        Ok(answer) => answer,
        Err(error) => {
            let text = format!("{endpoint}: {error}");
            let never_left = matches!(
                error,
                Error::InvalidRequest
                    | Error::BadUrl
                    | Error::DnsFailed
                    | Error::ConnectFailed
                    | Error::ConnectTimeout
                    | Error::CertificateRejected
                    | Error::TlsSetupFailed
            );
            return Err(if never_left {
                TokenError::Transient(text)
            } else {
                TokenError::Permanent(text)
            });
        }
    };
    let answer: Value = serde_json::from_slice(&body).unwrap_or_default();
    if status.is_success() {
        // A success spent the token that the request sent, so an unreadable answer lost the new one.
        let Some(access_token) = answer["access_token"].as_str().filter(|token| !token.is_empty()) else {
            return Err(TokenError::Permanent(format!(
                "{endpoint}: the answer has no access token"
            )));
        };
        let lifetime = &answer["expires_in"];
        let seconds = lifetime.as_u64().or_else(|| lifetime.as_str()?.parse().ok());
        let now = SystemTime::now().duration_since(UNIX_EPOCH).unwrap_or_default();
        return Ok(Tokens {
            access_token: access_token.to_owned(),
            refresh_token: answer["refresh_token"].as_str().map(str::to_owned),
            expires_at: seconds.map(|seconds| now.as_secs() + seconds),
        });
    }
    let code = answer["error"].as_str().unwrap_or_default();
    let mut text = format!("{endpoint}: HTTP {status}");
    if !code.is_empty() {
        text = format!("{text}: {code}");
    }
    // An unknown code is worth another try, because a wrong end costs the whole login.
    let permanent = status == StatusCode::UNAUTHORIZED
        || matches!(code, "invalid_grant" | "invalid_client" | "unauthorized_client");
    Err(if permanent {
        TokenError::Permanent(text)
    } else {
        TokenError::Transient(text)
    })
}

#[cfg(test)]
mod tests {
    use super::*;

    fn headers(values: &[&'static str]) -> HeaderMap {
        let mut headers = HeaderMap::new();
        for value in values {
            headers.append(WWW_AUTHENTICATE, HeaderValue::from_static(value));
        }
        headers
    }

    #[test]
    fn a_challenge_gives_the_quoted_parameters_of_its_bearer_scheme() {
        let headers = headers(&[
            r#"Basic realm="x", scope="basic""#,
            r#"Bearer error="x", resource_metadata="https://a.test/.well-known/r?x=1,2", scope="files:read all""#,
        ]);

        assert_eq!(
            parameter(&headers, "resource_metadata").as_deref(),
            Some("https://a.test/.well-known/r?x=1,2")
        );
        assert_eq!(parameter(&headers, "scope").as_deref(), Some("files:read all"));
    }

    #[test]
    fn a_challenge_without_a_bearer_scheme_or_the_parameter_gives_nothing() {
        let headers = headers(&["Bearer", r#"Basic scope="a""#, r#"Bearer realm="x""#]);

        assert_eq!(parameter(&headers, "scope"), None);
    }

    #[test]
    fn the_metadata_of_an_issuer_with_a_path_is_looked_up_in_the_order_of_the_spec() {
        assert_eq!(
            server_metadata_urls("https://auth.test/tenant1/").unwrap(),
            [
                "https://auth.test/.well-known/oauth-authorization-server/tenant1",
                "https://auth.test/.well-known/openid-configuration/tenant1",
                "https://auth.test/tenant1/.well-known/openid-configuration",
            ]
        );
        assert_eq!(
            server_metadata_urls("https://auth.test").unwrap(),
            [
                "https://auth.test/.well-known/oauth-authorization-server",
                "https://auth.test/.well-known/openid-configuration",
            ]
        );
    }

    #[test]
    fn the_canonical_url_of_a_server_has_no_query_fragment_or_trailing_slash() {
        assert_eq!(
            canonical("https://mcp.test:8443/mcp/?a=1#b").unwrap(),
            "https://mcp.test:8443/mcp"
        );
        assert_eq!(canonical("https://mcp.test/").unwrap(), "https://mcp.test");
    }
}
