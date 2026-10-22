//! The OpenAI Codex device login. It is not RFC 8628. An approved poll returns an authorization code, and a third call
//! exchanges that code for the tokens. The ID token names the account of each model request.

use std::time::{Duration, SystemTime, UNIX_EPOCH};

use serde::Deserialize;
use serde_json::{Value, json};

use super::{FlowLogin, Grant, OAuthError, PendingLogin, Poll, TokenAnswer};
use crate::base64;
use crate::transport::Exchange;

const CLIENT_ID: &str = "app_EMoamEEZ73f0CkXaXp7hrann";
const USER_CODE_URL: &str = "https://auth.openai.com/api/accounts/deviceauth/usercode";
const DEVICE_TOKEN_URL: &str = "https://auth.openai.com/api/accounts/deviceauth/token";
const TOKEN_URL: &str = "https://auth.openai.com/oauth/token";
/// OpenAI owns this callback, so the login needs no listener on this machine.
const DEVICE_REDIRECT_URI: &str = "https://auth.openai.com/deviceauth/callback";
/// The page of the approval. Codex fixes it, and the user types the code there.
const VERIFICATION_URL: &str = "https://auth.openai.com/codex/device";
/// The claim of the ID token that holds the account.
const AUTH_CLAIM: &str = "https://api.openai.com/auth";
/// The header that names the ChatGPT account of a model request.
pub(super) const ACCOUNT_HEADER: &str = "ChatGPT-Account-Id";
/// The refresh codes that end a grant. Another code is worth another try.
const PERMANENT_REFRESH: &[&str] = &[
    "invalid_grant",
    "refresh_token_expired",
    "refresh_token_reused",
    "refresh_token_invalidated",
];

/// The start answer. Codex can spell the user code as `usercode`, and it can send the interval as a text.
#[derive(Deserialize)]
struct UserCodeAnswer {
    device_auth_id: Option<String>,
    #[serde(alias = "usercode")]
    user_code: Option<String>,
    interval: Option<Value>,
}

/// The answer of an approved poll. The server makes the PKCE pair, and the exchange sends its verifier.
#[derive(Deserialize)]
struct CodeAnswer {
    authorization_code: Option<String>,
    code_verifier: Option<String>,
}

pub(super) async fn start(exchange: &dyn Exchange) -> Result<PendingLogin, OAuthError> {
    let request = json!({ "client_id": CLIENT_ID });
    let answer = super::accepted(super::post_json(exchange, USER_CODE_URL, &request).await)?;
    let start: UserCodeAnswer = serde_json::from_slice(&answer.body).map_err(|_| OAuthError::BadResponse)?;
    Ok(PendingLogin {
        user_code: super::nonblank(start.user_code).ok_or(OAuthError::BadResponse)?,
        verification_url: VERIFICATION_URL.to_owned(),
        interval: super::interval(start.interval.as_ref()),
        flow: FlowLogin::Codex {
            device_auth_id: super::nonblank(start.device_auth_id).ok_or(OAuthError::BadResponse)?,
        },
    })
}

pub(super) async fn poll(
    exchange: &dyn Exchange,
    device_auth_id: &str,
    user_code: &str,
    now: SystemTime,
) -> Result<Poll, OAuthError> {
    let request = json!({ "device_auth_id": device_auth_id, "user_code": user_code });
    let answer = super::post_json(exchange, DEVICE_TOKEN_URL, &request)
        .await
        .map_err(|fault| OAuthError::Transient(Some(fault)))?;
    // Codex tells "not approved yet" with a status, not with an RFC 8628 code.
    if matches!(answer.head.status, 403 | 404) {
        return Ok(Poll::Pending);
    }
    if !super::succeeded(answer.head.status) {
        return Err(OAuthError::Transient(None));
    }
    let code: CodeAnswer = serde_json::from_slice(&answer.body).map_err(|_| OAuthError::BadResponse)?;
    let authorization_code = super::nonblank(code.authorization_code).ok_or(OAuthError::BadResponse)?;
    let code_verifier = super::nonblank(code.code_verifier).ok_or(OAuthError::BadResponse)?;
    let fields = [
        ("grant_type", "authorization_code"),
        ("code", authorization_code.as_str()),
        ("redirect_uri", DEVICE_REDIRECT_URI),
        ("client_id", CLIENT_ID),
        ("code_verifier", code_verifier.as_str()),
    ];
    let answer = super::accepted(super::post_form(exchange, TOKEN_URL, &fields).await)?;
    grant(&answer.body, now).map(Poll::Approved)
}

pub(super) async fn refresh(
    exchange: &dyn Exchange,
    refresh_token: &str,
    now: SystemTime,
) -> Result<Grant, OAuthError> {
    let request = json!({ "client_id": CLIENT_ID, "grant_type": "refresh_token", "refresh_token": refresh_token });
    let answer = super::post_json(exchange, TOKEN_URL, &request)
        .await
        .map_err(super::refresh_fault)?;
    super::refreshed(&answer, PERMANENT_REFRESH, now, grant)
}

/// The grant of a token answer `body` at `now`, with the end and the account that the tokens state.
fn grant(body: &[u8], now: SystemTime) -> Result<Grant, OAuthError> {
    let mut answer: TokenAnswer = serde_json::from_slice(body).map_err(|_| OAuthError::BadResponse)?;
    let id_token = answer.id_token.take();
    let mut grant = answer.grant(now)?;
    // The access token states its own end, and `expires_in` can disagree with it. An end at or before 0 has passed.
    if let Some(end) = claims(&grant.access_token).and_then(|claims| claims.get("exp")?.as_i64()) {
        let seconds = u64::try_from(end).unwrap_or(0);
        if let Some(expires_at) = UNIX_EPOCH.checked_add(Duration::from_secs(seconds)) {
            grant.expires_at = expires_at;
        }
    }
    grant.account_id = id_token
        .as_deref()
        .and_then(claims)
        .and_then(|claims| {
            claims
                .get(AUTH_CLAIM)?
                .get("chatgpt_account_id")?
                .as_str()
                .map(str::to_owned)
        })
        .filter(|account_id| !account_id.trim().is_empty());
    Ok(grant)
}

/// The claims of the JSON Web Token `token`. The signature stays unchecked, because the token came from the provider
/// over TLS. The claims give only the end of the token and the account that each request names.
fn claims(token: &str) -> Option<Value> {
    // A JSON Web Token has three non-empty parts: the header, the payload, and the signature.
    let mut parts = token.split('.');
    let (Some(header), Some(payload), Some(signature), None) = (parts.next(), parts.next(), parts.next(), parts.next())
    else {
        return None;
    };
    if header.is_empty() || payload.is_empty() || signature.is_empty() {
        return None;
    }
    let bytes = base64::decode_url_safe(payload.as_bytes())?;
    serde_json::from_slice(&bytes).ok()
}
