//! The xAI device login. It is RFC 8628, so the poll returns the tokens with no exchange step.

use std::time::SystemTime;

use serde::Deserialize;
use serde_json::Value;

use super::{FlowLogin, Grant, OAuthError, PendingLogin, Poll};
use crate::transport::Exchange;

const CLIENT_ID: &str = "b1a00492-073a-47ea-816f-4c329264a828";
const SCOPE: &str = "openid profile email offline_access grok-cli:access api:access";
/// xAI reads the client name from `referrer`.
const REFERRER: &str = "yuke";
const DEVICE_GRANT: &str = "urn:ietf:params:oauth:grant-type:device_code";
const DEVICE_CODE_URL: &str = "https://auth.x.ai/oauth2/device/code";
const TOKEN_URL: &str = "https://auth.x.ai/oauth2/token";
/// The OAuth refresh codes that end a grant (RFC 6749, section 5.2). Another code is worth another try.
const PERMANENT_REFRESH: &[&str] = &["invalid_grant", "invalid_client", "unauthorized_client"];

/// The start answer (RFC 8628, section 3.2). xAI can spell the user code as `usercode`.
#[derive(Deserialize)]
struct StartAnswer {
    device_code: Option<String>,
    user_code: Option<String>,
    usercode: Option<String>,
    verification_uri: Option<String>,
    verification_uri_complete: Option<String>,
    interval: Option<Value>,
}

pub(super) async fn start(exchange: &dyn Exchange) -> Result<PendingLogin, OAuthError> {
    let fields = [("client_id", CLIENT_ID), ("scope", SCOPE), ("referrer", REFERRER)];
    let answer = super::post_form(exchange, DEVICE_CODE_URL, &fields)
        .await
        .map_err(|fault| OAuthError::Transient(Some(fault)))?;
    if !super::succeeded(answer.head.status) {
        return Err(OAuthError::Transient(None));
    }
    let start: StartAnswer = serde_json::from_slice(&answer.body).map_err(|_| OAuthError::BadResponse)?;
    let device_code = super::nonblank(start.device_code).ok_or(OAuthError::BadResponse)?;
    Ok(PendingLogin {
        user_code: super::nonblank(start.user_code)
            .or_else(|| super::nonblank(start.usercode))
            .ok_or(OAuthError::BadResponse)?,
        // The complete page holds the code, so the user types it only on the plain page.
        verification_url: super::nonblank(start.verification_uri_complete)
            .or_else(|| super::nonblank(start.verification_uri))
            .ok_or(OAuthError::BadResponse)?,
        interval: super::interval(start.interval.as_ref()),
        flow: FlowLogin::Xai { device_code },
    })
}

pub(super) async fn poll(exchange: &dyn Exchange, device_code: &str, now: SystemTime) -> Result<Poll, OAuthError> {
    let fields = [
        ("grant_type", DEVICE_GRANT),
        ("device_code", device_code),
        ("client_id", CLIENT_ID),
    ];
    let answer = super::post_form(exchange, TOKEN_URL, &fields)
        .await
        .map_err(|fault| OAuthError::Transient(Some(fault)))?;
    if super::succeeded(answer.head.status) {
        return super::grant(&answer.body, now).map(Poll::Approved);
    }
    // The code decides first: RFC 8628 can send `slow_down` with a 429, and the status alone loses the slower pace.
    match super::error_code(&answer.body).as_deref() {
        Some("authorization_pending") => return Ok(Poll::Pending),
        Some("slow_down") => return Ok(Poll::SlowDown),
        _ => {}
    }
    match answer.head.status {
        408 | 429 | 500.. => Err(OAuthError::Transient(None)),
        // `access_denied`, `expired_token`, and an unknown code end the login.
        _ => Err(OAuthError::Permanent),
    }
}

pub(super) async fn refresh(
    exchange: &dyn Exchange,
    refresh_token: &str,
    now: SystemTime,
) -> Result<Grant, OAuthError> {
    if refresh_token.is_empty() {
        return Err(OAuthError::Permanent);
    }
    let fields = [
        ("grant_type", "refresh_token"),
        ("client_id", CLIENT_ID),
        ("refresh_token", refresh_token),
    ];
    let answer = super::post_form(exchange, TOKEN_URL, &fields)
        .await
        .map_err(super::refresh_fault)?;
    super::refreshed(&answer, PERMANENT_REFRESH, now)
}
