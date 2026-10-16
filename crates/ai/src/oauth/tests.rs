//! The OAuth flows against scripted exchanges.

use std::time::{Duration, SystemTime, UNIX_EPOCH};

use serde_json::json;

use super::*;
use crate::testing::{ScriptedExchanges, block_on};

fn now() -> SystemTime {
    UNIX_EPOCH + Duration::from_secs(1_000_000)
}

fn start_of(body: &'static str) -> Result<PendingLogin, OAuthError> {
    block_on(Flow::Xai.start(&ScriptedExchanges::new([Ok((200, body))])))
}

/// The default interval and lifetime, written apart from the constants of the module.
const FIVE_SECONDS: Duration = Duration::from_secs(5);
const FIVE_HOURS: Duration = Duration::from_hours(5);

/// A pending login of the device code `dc`.
fn pending() -> PendingLogin {
    start_of(r#"{"device_code":"dc","user_code":"UC","verification_uri":"https://x.ai/d"}"#).unwrap()
}

fn poll_of(answer: Result<(u16, &'static str), Fault>) -> Result<Poll, OAuthError> {
    let transport = ScriptedExchanges::new([answer]);
    block_on(pending().poll(&transport, now()))
}

fn xai_refresh_of(answer: Result<(u16, &'static str), Fault>) -> Result<Grant, OAuthError> {
    let transport = ScriptedExchanges::new([answer]);
    block_on(Flow::Xai.refresh(&transport, "old-refresh", now()))
}

#[test]
fn a_start_sends_the_client_and_reads_the_code_and_the_complete_page() {
    let transport = ScriptedExchanges::new([Ok((
        200,
        r#"{"device_code":"dc","user_code":"UC","verification_uri":"https://x.ai/d",
            "verification_uri_complete":"https://x.ai/d?code=UC","interval":7}"#,
    ))]);

    let login = block_on(Flow::Xai.start(&transport)).unwrap();

    assert_eq!(login.user_code, "UC");
    assert_eq!(login.verification_url, "https://x.ai/d?code=UC");
    assert_eq!(login.interval, Duration::from_secs(7));
    let sent = transport.sent();
    assert_eq!(sent.len(), 1);
    assert_eq!(sent[0].url, "https://auth.x.ai/oauth2/device/code");
    assert_eq!(sent[0].content_type, "application/x-www-form-urlencoded");
    assert_eq!(
        sent[0].body,
        "client_id=b1a00492-073a-47ea-816f-4c329264a828\
         &scope=openid+profile+email+offline_access+grok-cli%3Aaccess+api%3Aaccess&referrer=yuke"
    );
    assert!(sent[0].has_deadline);
}

#[test]
fn a_start_takes_the_other_spellings_and_fails_without_a_code() {
    let other = start_of(r#"{"device_code":"dc","usercode":"UC","verification_uri":"https://x.ai/d"}"#).unwrap();
    let blank = start_of(r#"{"device_code":"dc","user_code":" ","verification_uri":"u"}"#);
    let refused = block_on(Flow::Xai.start(&ScriptedExchanges::new([Ok((503, "{}"))])));
    let unreachable = block_on(Flow::Xai.start(&ScriptedExchanges::new([Err(Fault::DnsFailed)])));

    assert_eq!(other.user_code, "UC");
    assert_eq!(other.verification_url, "https://x.ai/d");
    assert_eq!(blank.err(), Some(OAuthError::BadResponse));
    assert_eq!(refused.err(), Some(OAuthError::Transient(None)));
    assert_eq!(unreachable.err(), Some(OAuthError::Transient(Some(Fault::DnsFailed))));
}

#[test]
fn an_interval_takes_the_default_when_it_is_absent_zero_or_absurd() {
    let interval_of = |body| start_of(body).unwrap().interval;

    assert_eq!(
        interval_of(r#"{"device_code":"d","user_code":"u","verification_uri":"v"}"#),
        FIVE_SECONDS
    );
    assert_eq!(
        interval_of(r#"{"device_code":"d","user_code":"u","verification_uri":"v","interval":0}"#),
        FIVE_SECONDS
    );
    assert_eq!(
        interval_of(r#"{"device_code":"d","user_code":"u","verification_uri":"v","interval":-3}"#),
        FIVE_SECONDS
    );
    assert_eq!(
        interval_of(r#"{"device_code":"d","user_code":"u","verification_uri":"v","interval":86400}"#),
        FIVE_SECONDS
    );
}

#[test]
fn each_poll_code_and_status_maps_to_one_outcome() {
    assert_eq!(
        poll_of(Ok((400, r#"{"error":"authorization_pending"}"#))),
        Ok(Poll::Pending)
    );
    assert_eq!(poll_of(Ok((400, r#"{"error":"slow_down"}"#))), Ok(Poll::SlowDown));
    // RFC 8628 can pair `slow_down` with a 429, so the code decides before the status.
    assert_eq!(poll_of(Ok((429, r#"{"error":"slow_down"}"#))), Ok(Poll::SlowDown));
    for status in [408, 429, 503] {
        assert_eq!(
            poll_of(Ok((status, "{}"))),
            Err(OAuthError::Transient(None)),
            "{status}"
        );
    }
    assert_eq!(
        poll_of(Ok((400, r#"{"error":"access_denied"}"#))),
        Err(OAuthError::Permanent)
    );
    assert_eq!(poll_of(Ok((400, "{}"))), Err(OAuthError::Permanent));
    assert_eq!(
        poll_of(Err(Fault::ConnectionLost)),
        Err(OAuthError::Transient(Some(Fault::ConnectionLost)))
    );
    assert_eq!(
        poll_of(Ok((200, r#"{"token_type":"Bearer"}"#))),
        Err(OAuthError::BadResponse)
    );
}

#[test]
fn an_approved_poll_gives_the_grant_with_its_end() {
    let approved = poll_of(Ok((
        200,
        r#"{"access_token":"at","refresh_token":"rt","expires_in":3600}"#,
    )));
    let lifetime_unknown = poll_of(Ok((200, r#"{"access_token":"at"}"#)));
    let lifetime_absurd = poll_of(Ok((200, r#"{"access_token":"at","expires_in":18446744073709551615}"#)));

    assert_eq!(
        approved,
        Ok(Poll::Approved(Grant {
            access_token: "at".to_owned(),
            refresh_token: Some("rt".to_owned()),
            expires_at: now() + Duration::from_secs(3600),
            account_id: None,
        }))
    );
    let Ok(Poll::Approved(unknown)) = lifetime_unknown else {
        panic!("{lifetime_unknown:?}");
    };
    assert_eq!(unknown.expires_at, now() + FIVE_HOURS);
    assert_eq!(unknown.refresh_token, None);
    let Ok(Poll::Approved(absurd)) = lifetime_absurd else {
        panic!("{lifetime_absurd:?}");
    };
    assert_eq!(absurd.expires_at, now() + FIVE_HOURS);
}

#[test]
fn a_refresh_sends_its_token_as_a_form_and_reads_the_new_grant() {
    let transport = ScriptedExchanges::new([Ok((200, r#"{"access_token":"new","expires_in":60}"#))]);

    let grant = block_on(Flow::Xai.refresh(&transport, "a b&c=/é~*-._", now())).unwrap();

    assert_eq!(grant.access_token, "new");
    // The answer has no refresh token, so the caller keeps the old one.
    assert_eq!(grant.refresh_token, None);
    assert_eq!(grant.expires_at, now() + Duration::from_secs(60));
    let sent = transport.sent();
    assert_eq!(sent[0].url, "https://auth.x.ai/oauth2/token");
    assert_eq!(
        sent[0].body,
        "grant_type=refresh_token&client_id=b1a00492-073a-47ea-816f-4c329264a828\
         &refresh_token=a+b%26c%3D%2F%C3%A9%7E*-._"
    );
}

#[test]
fn each_refresh_answer_maps_to_one_outcome() {
    let permanent = Err(OAuthError::Permanent);
    let transient = Err(OAuthError::Transient(None));
    // A success spent the token, so an unreadable answer lost the new grant.
    assert_eq!(xai_refresh_of(Ok((200, "not json"))), Err(OAuthError::Ambiguous(None)));
    assert_eq!(
        xai_refresh_of(Ok((200, r#"{"refresh_token":"rt"}"#))),
        Err(OAuthError::Ambiguous(None))
    );
    assert_eq!(xai_refresh_of(Ok((401, r#"{"error":"teapot"}"#))), permanent);
    assert_eq!(xai_refresh_of(Ok((400, r#"{"error":"invalid_grant"}"#))), permanent);
    // The code can be in each documented field, in any case. The first non-empty one decides.
    assert_eq!(
        xai_refresh_of(Ok((400, r#"{"error":{"code":"Invalid_Client"},"code":"teapot"}"#))),
        permanent
    );
    assert_eq!(
        xai_refresh_of(Ok((400, r#"{"error":"","code":"UNAUTHORIZED_CLIENT"}"#))),
        permanent
    );
    assert_eq!(
        xai_refresh_of(Ok((400, r#"{"error_code":"invalid_grant"}"#))),
        permanent
    );
    assert_eq!(xai_refresh_of(Ok((400, r#"{"error":7}"#))), transient);
    assert_eq!(xai_refresh_of(Ok((400, r#"{"error":"teapot"}"#))), transient);
    assert_eq!(xai_refresh_of(Ok((500, "{}"))), transient);
}

#[test]
fn a_refresh_repeats_only_when_its_request_never_left() {
    for fault in [Fault::DnsFailed, Fault::ConnectFailed, Fault::ConnectTimeout] {
        assert_eq!(
            xai_refresh_of(Err(fault)),
            Err(OAuthError::Transient(Some(fault))),
            "{fault:?}"
        );
    }
    for fault in [Fault::ConnectionLost, Fault::RequestTimeout, Fault::IdleTimeout] {
        assert_eq!(
            xai_refresh_of(Err(fault)),
            Err(OAuthError::Ambiguous(Some(fault))),
            "{fault:?}"
        );
    }
}

#[test]
fn an_empty_refresh_token_ends_the_grant_and_sends_nothing() {
    let transport = ScriptedExchanges::new([]);

    let refreshed = block_on(Flow::Xai.refresh(&transport, "", now()));

    assert_eq!(refreshed, Err(OAuthError::Permanent));
    assert_eq!(transport.sent(), []);
}

#[test]
fn a_grant_and_a_pending_login_write_no_secret_in_their_debug_text() {
    let grant = Grant {
        access_token: "secret-access".to_owned(),
        refresh_token: Some("secret-refresh".to_owned()),
        expires_at: now(),
        account_id: None,
    };
    let login =
        start_of(r#"{"device_code":"secret-device","user_code":"UC","verification_uri":"https://x.ai/d"}"#).unwrap();

    let text = format!("{grant:?} {login:?}");

    assert!(!text.contains("secret"), "{text}");
}

#[test]
fn a_failed_exchange_gives_its_fault_as_the_source() {
    let error = OAuthError::Transient(Some(Fault::DnsFailed));

    let source = std::error::Error::source(&error).map(ToString::to_string);

    assert_eq!(source, Some(Fault::DnsFailed.to_string()));
}

#[test]
fn an_xai_credential_is_a_bearer_with_no_identity_header_even_with_an_account() {
    let credential = Flow::Xai.credential("at".to_owned(), Some("account".to_owned()));

    assert_eq!(
        credential,
        Credential::OAuth(OAuth {
            access_token: "at".into(),
            headers: Cow::Borrowed(&[]),
        })
    );
}

#[test]
fn a_poll_sends_the_device_code_of_its_login() {
    let transport = ScriptedExchanges::new([Ok((400, r#"{"error":"authorization_pending"}"#))]);

    block_on(pending().poll(&transport, now())).unwrap();

    let sent = transport.sent();
    assert_eq!(sent[0].url, "https://auth.x.ai/oauth2/token");
    assert_eq!(
        sent[0].body,
        "grant_type=urn%3Aietf%3Aparams%3Aoauth%3Agrant-type%3Adevice_code&device_code=dc\
         &client_id=b1a00492-073a-47ea-816f-4c329264a828"
    );
}

/// The JSON Web Tokens of the tests: the payloads are the claims `{"exp":2000000}` and
/// `{"https://api.openai.com/auth":{"chatgpt_account_id":"account-1"}}` in URL-safe base64.
const ACCESS_JWT: &str = "e30.eyJleHAiOjIwMDAwMDB9.signature";
const ID_JWT: &str =
    "e30.eyJodHRwczovL2FwaS5vcGVuYWkuY29tL2F1dGgiOnsiY2hhdGdwdF9hY2NvdW50X2lkIjoiYWNjb3VudC0xIn19.signature";

fn codex_pending(transport: &ScriptedExchanges) -> PendingLogin {
    block_on(Flow::Codex.start(transport)).unwrap()
}

#[test]
fn a_codex_start_sends_json_and_points_to_the_fixed_page() {
    let transport = ScriptedExchanges::new([Ok((200, r#"{"device_auth_id":"da","usercode":"UC","interval":"7"}"#))]);

    let login = codex_pending(&transport);

    assert_eq!(login.user_code, "UC");
    assert_eq!(login.verification_url, "https://auth.openai.com/codex/device");
    assert_eq!(login.interval, Duration::from_secs(7));
    let sent = transport.sent();
    assert_eq!(sent[0].url, "https://auth.openai.com/api/accounts/deviceauth/usercode");
    assert_eq!(sent[0].content_type, "application/json");
    let body: Value = serde_json::from_str(&sent[0].body).unwrap();
    assert_eq!(body, json!({"client_id": "app_EMoamEEZ73f0CkXaXp7hrann"}));
}

#[test]
fn a_codex_poll_waits_on_403_or_404_and_fails_for_now_on_another_status() {
    let start = Ok((200, r#"{"device_auth_id":"da","user_code":"UC"}"#));
    let poll_of = |answer| {
        let transport = ScriptedExchanges::new([start, answer]);
        let login = codex_pending(&transport);
        block_on(login.poll(&transport, now()))
    };

    assert_eq!(poll_of(Ok((403, "{}"))), Ok(Poll::Pending));
    assert_eq!(poll_of(Ok((404, "{}"))), Ok(Poll::Pending));
    assert_eq!(poll_of(Ok((500, "{}"))), Err(OAuthError::Transient(None)));
    assert_eq!(
        poll_of(Ok((200, r#"{"authorization_code":"ac"}"#))),
        Err(OAuthError::BadResponse)
    );
}

#[test]
fn an_approved_codex_poll_exchanges_the_code_and_reads_the_account_and_the_end() {
    let tokens =
        format!(r#"{{"access_token":"{ACCESS_JWT}","refresh_token":"rt","id_token":"{ID_JWT}","expires_in":60}}"#);
    let transport = ScriptedExchanges::new([
        Ok((200, r#"{"device_auth_id":"da","user_code":"UC"}"#)),
        Ok((200, r#"{"authorization_code":"ac","code_verifier":"cv"}"#)),
        Ok((200, tokens.as_str())),
    ]);
    let login = codex_pending(&transport);

    let polled = block_on(login.poll(&transport, now()));

    let Ok(Poll::Approved(grant)) = polled else {
        panic!("{polled:?}");
    };
    assert_eq!(grant.access_token, ACCESS_JWT);
    assert_eq!(grant.refresh_token.as_deref(), Some("rt"));
    // The token states its end, so `expires_in` does not decide it.
    assert_eq!(grant.expires_at, UNIX_EPOCH + Duration::from_secs(2_000_000));
    assert_eq!(grant.account_id.as_deref(), Some("account-1"));
    let sent = transport.sent();
    let poll: Value = serde_json::from_str(&sent[1].body).unwrap();
    assert_eq!(poll, json!({"device_auth_id": "da", "user_code": "UC"}));
    assert_eq!(sent[2].url, "https://auth.openai.com/oauth/token");
    assert_eq!(sent[2].content_type, "application/x-www-form-urlencoded");
    assert_eq!(
        sent[2].body,
        "grant_type=authorization_code&code=ac&redirect_uri=https%3A%2F%2Fauth.openai.com%2Fdeviceauth%2Fcallback\
         &client_id=app_EMoamEEZ73f0CkXaXp7hrann&code_verifier=cv"
    );
}

#[test]
fn a_codex_token_that_is_no_jwt_takes_its_lifetime_and_no_account() {
    let transport = ScriptedExchanges::new([Ok((
        200,
        r#"{"access_token":"opaque","expires_in":60,"id_token":"x.!.y"}"#,
    ))]);

    let grant = block_on(Flow::Codex.refresh(&transport, "rt", now())).unwrap();

    assert_eq!(grant.expires_at, now() + Duration::from_secs(60));
    assert_eq!(grant.account_id, None);
}

#[test]
fn a_codex_refresh_sends_json_and_ends_the_grant_on_its_own_codes() {
    let codex_refresh_of = |answer| {
        let transport = ScriptedExchanges::new([answer]);
        let refreshed = block_on(Flow::Codex.refresh(&transport, "rt", now()));
        (refreshed, transport.sent())
    };

    let (reused, sent) = codex_refresh_of(Ok((400, r#"{"error":{"code":"refresh_token_reused"}}"#)));
    let (expired, _) = codex_refresh_of(Ok((400, r#"{"code":"refresh_token_expired"}"#)));
    let (unknown, _) = codex_refresh_of(Ok((400, r#"{"error":"teapot"}"#)));
    let (invalid_grant, _) = codex_refresh_of(Ok((400, r#"{"error":"invalid_grant"}"#)));
    let (invalidated, _) = codex_refresh_of(Ok((400, r#"{"code":"refresh_token_invalidated"}"#)));

    assert_eq!(reused, Err(OAuthError::Permanent));
    assert_eq!(expired, Err(OAuthError::Permanent));
    assert_eq!(unknown, Err(OAuthError::Transient(None)));
    assert_eq!(invalid_grant, Err(OAuthError::Permanent));
    assert_eq!(invalidated, Err(OAuthError::Permanent));
    assert_eq!(sent[0].url, "https://auth.openai.com/oauth/token");
    assert_eq!(sent[0].content_type, "application/json");
    let body: Value = serde_json::from_str(&sent[0].body).unwrap();
    assert_eq!(
        body,
        json!({"client_id": "app_EMoamEEZ73f0CkXaXp7hrann", "grant_type": "refresh_token", "refresh_token": "rt"})
    );
}

#[test]
fn a_codex_credential_names_its_account_in_a_header() {
    let with_account = Flow::Codex.credential("at".to_owned(), Some("account-1".to_owned()));
    let without = Flow::Codex.credential("at".to_owned(), None);

    let Credential::OAuth(with_account) = with_account else {
        panic!("{with_account:?}");
    };
    assert_eq!(*with_account.headers, [Header::new("ChatGPT-Account-Id", "account-1")]);
    let Credential::OAuth(without) = without else {
        panic!("{without:?}");
    };
    assert!(without.headers.is_empty());
}

#[test]
fn a_failed_exchange_after_an_approved_codex_poll_fails_for_now() {
    let exchange_of = |answer| {
        let transport = ScriptedExchanges::new([
            Ok((200, r#"{"device_auth_id":"da","user_code":"UC"}"#)),
            Ok((200, r#"{"authorization_code":"ac","code_verifier":"cv"}"#)),
            answer,
        ]);
        let login = codex_pending(&transport);
        block_on(login.poll(&transport, now()))
    };

    assert_eq!(exchange_of(Ok((500, "{}"))), Err(OAuthError::Transient(None)));
    assert_eq!(
        exchange_of(Err(Fault::ConnectionLost)),
        Err(OAuthError::Transient(Some(Fault::ConnectionLost)))
    );
}

#[test]
fn a_codex_token_whose_end_is_at_or_before_zero_has_ended() {
    // The payloads are `{"exp":0}` and `{"exp":-5}`.
    for access in ["e30.eyJleHAiOjB9.signature", "e30.eyJleHAiOi01fQ.signature"] {
        let body = format!(r#"{{"access_token":"{access}","expires_in":3600}}"#);
        let transport = ScriptedExchanges::new([Ok((200, body.as_str()))]);

        let grant = block_on(Flow::Codex.refresh(&transport, "rt", now())).unwrap();

        assert_eq!(grant.expires_at, UNIX_EPOCH, "{access}");
    }
}

#[test]
fn a_token_without_three_parts_gives_no_claims() {
    // The account claim is in the payload, but the signature part is absent or empty, so the account stays unknown.
    let payload = ID_JWT.strip_suffix(".signature").unwrap();
    for id in [payload.to_owned(), format!("{payload}.")] {
        let body = format!(r#"{{"access_token":"opaque","expires_in":60,"id_token":"{id}"}}"#);
        let transport = ScriptedExchanges::new([Ok((200, body.as_str()))]);

        let grant = block_on(Flow::Codex.refresh(&transport, "rt", now())).unwrap();

        assert_eq!(grant.account_id, None, "{id}");
    }
}
