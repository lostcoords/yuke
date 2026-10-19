//! The stateless OAuth flows of the catalog providers: a device login and a refresh. The caller keeps the grant, its
//! lock, and the poll loop.

mod codex;
mod xai;

use std::borrow::Cow;
use std::fmt;
use std::time::{Duration, Instant, SystemTime};

use serde::{Deserialize, Serialize};
use serde_json::Value;

use crate::route::{Credential, OAuth};
use crate::transport::{Answer, Exchange, ExchangeRequest, Fault, Header};

/// The interval of a device login whose start names none. RFC 8628 section 3.2 gives this default.
const DEFAULT_INTERVAL: Duration = Duration::from_secs(5);

/// No device login polls slower than this, so a larger interval is garbage.
const MAX_INTERVAL: Duration = Duration::from_hours(1);

/// The lifetime of a grant whose answer names none. A short guess would rotate a long grant for nothing.
const DEFAULT_LIFETIME: Duration = Duration::from_hours(5);

/// A token answer is small, so a larger one is a fault.
const MAX_ANSWER: usize = 256 * 1024;

/// The time limit of one exchange.
const EXCHANGE_TIMEOUT: Duration = Duration::from_secs(30);

/// The media types of the OAuth request bodies.
const FORM: &str = "application/x-www-form-urlencoded";
const JSON: &str = "application/json";

/// An OAuth flow of the catalog.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash)]
pub enum Flow {
    /// The xAI device login.
    Xai,
    /// The OpenAI Codex device login of a ChatGPT account.
    Codex,
}

impl Flow {
    /// The flow of `name`, the name in [`crate::catalog::Auth::OAuth`].
    pub fn named(name: &str) -> Option<Flow> {
        match name {
            "xai" => Some(Flow::Xai),
            "codex" => Some(Flow::Codex),
            _ => None,
        }
    }

    /// Start a device login: the provider gives a code that the user approves on a page.
    ///
    /// # Errors
    ///
    /// Returns [`OAuthError::Transient`] when the provider is not reachable or refuses for now, and
    /// [`OAuthError::BadResponse`] for an answer the flow cannot read.
    pub async fn start(self, exchange: &dyn Exchange) -> Result<PendingLogin, OAuthError> {
        match self {
            Flow::Xai => xai::start(exchange).await,
            Flow::Codex => codex::start(exchange).await,
        }
    }

    /// Change `refresh_token` for a new grant. A grant without a new refresh token has none, and the caller keeps the
    /// old one.
    ///
    /// # Errors
    ///
    /// Returns [`OAuthError::Transient`] when a repeat with the same token is safe, [`OAuthError::Ambiguous`] when
    /// the provider can hold the request (the token can be spent), and [`OAuthError::Permanent`] when the grant is gone.
    pub async fn refresh(
        self,
        exchange: &dyn Exchange,
        refresh_token: &str,
        now: SystemTime,
    ) -> Result<Grant, OAuthError> {
        // An empty token cannot refresh, so no request goes out.
        if refresh_token.is_empty() {
            return Err(OAuthError::Permanent);
        }
        match self {
            Flow::Xai => xai::refresh(exchange, refresh_token, now).await,
            Flow::Codex => codex::refresh(exchange, refresh_token, now).await,
        }
    }

    /// The header that names the account of a grant in each model request, or `None` for a flow without accounts.
    pub fn account_header(self) -> Option<&'static str> {
        match self {
            Flow::Xai => None,
            Flow::Codex => Some(codex::ACCOUNT_HEADER),
        }
    }

    /// The credential of a model request with `access_token` of the account `account_id` ([`Grant::account_id`]).
    /// A flow without accounts drops the account.
    pub fn credential(self, access_token: String, account_id: Option<String>) -> Credential {
        let headers = match (self.account_header(), account_id) {
            (Some(name), Some(account_id)) => Cow::Owned(vec![Header::new(name, account_id)]),
            _ => Cow::Borrowed(&[][..]),
        };
        Credential::OAuth(OAuth {
            access_token: access_token.into(),
            headers,
        })
    }
}

/// A device login that waits for the approval of the user. `Debug` writes no secret of the flow.
#[derive(Clone)]
pub struct PendingLogin {
    /// The code that the user confirms on the page.
    pub user_code: String,
    /// The page of the approval.
    pub verification_url: String,
    /// The wait between two polls.
    pub interval: Duration,
    /// What each poll of the flow sends.
    flow: FlowLogin,
}

/// The state of a pending login that only its flow reads.
#[derive(Clone)]
enum FlowLogin {
    /// After the approval, the device code gets the grant, so it is secret (RFC 8628, section 5.1).
    Xai { device_code: String },
    /// The id of the device login. Each poll sends it with the user code.
    Codex { device_auth_id: String },
}

impl PendingLogin {
    /// Ask whether the user approved. Call it again after the interval.
    ///
    /// # Errors
    ///
    /// Returns [`OAuthError::Transient`] to poll again later, [`OAuthError::Permanent`] when the login ended (denied
    /// or expired), and [`OAuthError::BadResponse`] for an answer the flow cannot read.
    pub async fn poll(&self, exchange: &dyn Exchange, now: SystemTime) -> Result<Poll, OAuthError> {
        match &self.flow {
            FlowLogin::Xai { device_code } => xai::poll(exchange, device_code, now).await,
            FlowLogin::Codex { device_auth_id } => codex::poll(exchange, device_auth_id, &self.user_code, now).await,
        }
    }
}

impl fmt::Debug for PendingLogin {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.debug_struct("PendingLogin")
            .field("user_code", &self.user_code)
            .field("verification_url", &self.verification_url)
            .field("interval", &self.interval)
            .finish_non_exhaustive()
    }
}

/// The answer of one poll.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum Poll {
    /// The user did not approve yet. Poll again after the interval.
    Pending,
    /// The provider asks for slower polls. RFC 8628 section 3.5 adds 5 seconds to the interval.
    SlowDown,
    /// The user approved.
    Approved(Grant),
}

/// The tokens of one login or refresh. `Debug` writes no token.
#[derive(Clone, PartialEq, Eq)]
pub struct Grant {
    /// The token of each model request.
    pub access_token: String,
    /// The token of the next refresh. After a refresh answer without one, the caller keeps the old one.
    pub refresh_token: Option<String>,
    /// The end of the access token.
    pub expires_at: SystemTime,
    /// The account of a flow that names one in each model request. It is a label, not a secret.
    pub account_id: Option<String>,
}

impl fmt::Debug for Grant {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.debug_struct("Grant")
            .field("access_token", &"<redacted>")
            .field("refresh_token", &self.refresh_token.as_ref().map(|_| "<redacted>"))
            .field("expires_at", &self.expires_at)
            .field("account_id", &self.account_id)
            .finish()
    }
}

/// Why an OAuth step failed. A failed exchange gives its fault as the source.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash)]
pub enum OAuthError {
    /// The step failed for now. A repeat is safe, also with the same refresh token.
    Transient(Option<Fault>),
    /// A refresh can have reached the provider, so its token can be spent. Never repeat it.
    Ambiguous(Option<Fault>),
    /// The login or the grant ended. Only a new login recovers it.
    Permanent,
    /// The provider sent an answer that the flow cannot read.
    BadResponse,
}

impl fmt::Display for OAuthError {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.write_str(match self {
            Self::Transient(_) => "the login provider failed for now",
            Self::Ambiguous(_) => "the refresh of the login has an unknown result",
            Self::Permanent => "the login ended",
            Self::BadResponse => "the login provider sent an answer that yuke cannot read",
        })
    }
}

impl std::error::Error for OAuthError {
    fn source(&self) -> Option<&(dyn std::error::Error + 'static)> {
        match self {
            Self::Transient(Some(fault)) | Self::Ambiguous(Some(fault)) => Some(fault),
            _ => None,
        }
    }
}

/// Post the form `fields` to `url`, and return the whole answer.
async fn post_form(exchange: &dyn Exchange, url: &str, fields: &[(&str, &str)]) -> Result<Answer, Fault> {
    let body = form(fields);
    let request = ExchangeRequest {
        url,
        content_type: FORM,
        body: body.as_bytes(),
        max_answer: MAX_ANSWER,
    };
    exchange
        .exchange(&request, Some(Instant::now() + EXCHANGE_TIMEOUT))
        .await
}

/// Post `body` as JSON to `url`, and return the whole answer.
async fn post_json(exchange: &dyn Exchange, url: &str, body: &impl Serialize) -> Result<Answer, Fault> {
    // A struct of texts always serializes, so an error is a bug of the flow.
    let body = serde_json::to_vec(body).map_err(|_| Fault::InvalidRequest)?;
    let request = ExchangeRequest {
        url,
        content_type: JSON,
        body: &body,
        max_answer: MAX_ANSWER,
    };
    exchange
        .exchange(&request, Some(Instant::now() + EXCHANGE_TIMEOUT))
        .await
}

/// Encode `fields` as `application/x-www-form-urlencoded` (WHATWG URL, section 5.2).
fn form(fields: &[(&str, &str)]) -> String {
    let mut encoded = String::new();
    for (index, (name, value)) in fields.iter().enumerate() {
        if index > 0 {
            encoded.push('&');
        }
        encode(name, &mut encoded);
        encoded.push('=');
        encode(value, &mut encoded);
    }
    encoded
}

/// Append `text` to `out` with each byte outside `*-._` and the ASCII letters and digits escaped, and a space as `+`.
fn encode(text: &str, out: &mut String) {
    for byte in text.bytes() {
        match byte {
            b'A'..=b'Z' | b'a'..=b'z' | b'0'..=b'9' | b'*' | b'-' | b'.' | b'_' => out.push(char::from(byte)),
            b' ' => out.push('+'),
            _ => {
                const HEX: &[u8; 16] = b"0123456789ABCDEF";
                out.push('%');
                out.push(char::from(HEX[usize::from(byte >> 4)]));
                out.push(char::from(HEX[usize::from(byte & 0xf)]));
            }
        }
    }
}

/// The error of a failed exchange of a refresh. Only a fault before the connection carried the request proves that the
/// request did not leave, so only then is a repeat with the same token safe.
fn refresh_fault(fault: Fault) -> OAuthError {
    match fault {
        Fault::InvalidRequest
        | Fault::BadUrl
        | Fault::DnsFailed
        | Fault::ConnectFailed
        | Fault::ConnectTimeout
        | Fault::CertificateRejected
        | Fault::TlsSetupFailed => OAuthError::Transient(Some(fault)),
        _ => OAuthError::Ambiguous(Some(fault)),
    }
}

/// Whether `status` is a success.
fn succeeded(status: u16) -> bool {
    (200..300).contains(&status)
}

/// A token answer (RFC 6749, section 5.1).
#[derive(Deserialize)]
struct TokenAnswer {
    access_token: Option<String>,
    refresh_token: Option<String>,
    expires_in: Option<Value>,
    /// The ID token of the account.
    id_token: Option<String>,
}

impl TokenAnswer {
    /// The grant of this answer at `now`.
    fn grant(self, now: SystemTime) -> Result<Grant, OAuthError> {
        let access_token = nonblank(self.access_token).ok_or(OAuthError::BadResponse)?;
        let lifetime = self.expires_in.as_ref().and_then(seconds).unwrap_or(DEFAULT_LIFETIME);
        Ok(Grant {
            access_token,
            refresh_token: nonblank(self.refresh_token),
            // A lifetime past the clock range ends at the default instead.
            expires_at: now.checked_add(lifetime).unwrap_or_else(|| now + DEFAULT_LIFETIME),
            account_id: None,
        })
    }
}

/// An error answer. The providers put the code in `error.code`, `error`, `code`, or `error_code`.
#[derive(Deserialize)]
struct ErrorAnswer {
    error: Option<Value>,
    code: Option<Value>,
    error_code: Option<Value>,
}

/// The error code of an error answer `body`, in lowercase. The first non-empty text wins.
fn error_code(body: &[u8]) -> Option<String> {
    let answer: ErrorAnswer = serde_json::from_slice(body).ok()?;
    let nested = answer.error.as_ref().and_then(|error| error.get("code"));
    [
        nested,
        answer.error.as_ref(),
        answer.code.as_ref(),
        answer.error_code.as_ref(),
    ]
    .into_iter()
    .flatten()
    .find_map(|value| value.as_str().filter(|code| !code.is_empty()))
    .map(str::to_ascii_lowercase)
}

/// `text` when it holds more than white space.
fn nonblank(text: Option<String>) -> Option<String> {
    text.filter(|text| !text.trim().is_empty())
}

/// The whole seconds of `value`, when it holds a positive count. Codex sends a number as a string.
fn seconds(value: &Value) -> Option<Duration> {
    let seconds = value
        .as_u64()
        .or_else(|| value.as_str().and_then(|text| text.parse().ok()))?;
    (seconds > 0).then(|| Duration::from_secs(seconds))
}

/// The poll interval of a start answer. An absent, zero, or absurd value takes the default.
fn interval(value: Option<&Value>) -> Duration {
    value
        .and_then(seconds)
        .filter(|interval| *interval <= MAX_INTERVAL)
        .unwrap_or(DEFAULT_INTERVAL)
}

/// The grant of a success answer `body` at `now`.
fn grant(body: &[u8], now: SystemTime) -> Result<Grant, OAuthError> {
    serde_json::from_slice::<TokenAnswer>(body)
        .map_err(|_| OAuthError::BadResponse)?
        .grant(now)
}

/// The outcome of a refresh answer. `permanent` lists the codes that end the grant in this flow, and `grant` reads
/// the token answer of the flow.
fn refreshed(
    answer: &Answer,
    permanent: &[&str],
    now: SystemTime,
    grant: fn(&[u8], SystemTime) -> Result<Grant, OAuthError>,
) -> Result<Grant, OAuthError> {
    if succeeded(answer.head.status) {
        // A success spent the token that the request sent, so an unreadable answer lost the new one.
        return grant(&answer.body, now).map_err(|_| OAuthError::Ambiguous(None));
    }
    // A 401 ends the grant, whatever the body says.
    if answer.head.status == 401 {
        return Err(OAuthError::Permanent);
    }
    match error_code(&answer.body) {
        Some(code) if permanent.contains(&code.as_str()) => Err(OAuthError::Permanent),
        // An unknown code is worth another try, because a wrong end costs the whole grant.
        _ => Err(OAuthError::Transient(None)),
    }
}

#[cfg(test)]
mod tests;
