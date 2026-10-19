//! The logins against scripted exchanges, each in a folder of its own. The tests write and read `auth.json` as plain
//! JSON, so they check the file format apart from the code.

use std::path::Path;
use std::sync::mpsc;

use serde_json::{Value, json};
use yuke_ai::transport::{Answer, BoxFuture, ExchangeRequest, Fault};

use super::*;
use crate::testing::Answers;
use yuke_engine::chain_text;

const PROVIDER: &str = "xai-grok";

const START: &str =
    r#"{"device_code":"dc","user_code":"UC","verification_uri_complete":"https://x.ai/d?c=UC","interval":1}"#;

/// A new empty folder for the test `name`.
fn folder(name: &str) -> PathBuf {
    let folder = std::env::temp_dir()
        .join(format!("yuke-auth-tests-{}", std::process::id()))
        .join(name);
    match fs::remove_dir_all(&folder) {
        Ok(()) => {}
        Err(error) if error.kind() == io::ErrorKind::NotFound => {}
        Err(error) => panic!("{error}"),
    }
    fs::create_dir_all(&folder).unwrap();
    folder
}

/// The content of `auth.json`, or `{}` when it does not exist.
fn file(folder: &Path) -> Value {
    match fs::read(folder.join(FILE)) {
        Ok(bytes) => serde_json::from_slice(&bytes).unwrap(),
        Err(error) if error.kind() == io::ErrorKind::NotFound => json!({}),
        Err(error) => panic!("{error}"),
    }
}

/// Save a login of the provider that ends `ends_in` seconds from now, or that ended already for a negative count.
fn save(folder: &Path, access: &str, refresh: &str, ends_in: i64) {
    let expires_at = millis(SystemTime::now()).saturating_add_signed(ends_in * 1000);
    let mut content = file(folder);
    content[PROVIDER] = json!({"access_token": access, "refresh_token": refresh, "expires_at": expires_at});
    fs::write(folder.join(FILE), content.to_string()).unwrap();
}

/// The access and the refresh token of the login of the provider.
fn saved(folder: &Path) -> Option<(String, String)> {
    let login = file(folder).get(PROVIDER)?.clone();
    Some((
        login["access_token"].as_str().unwrap().to_owned(),
        login["refresh_token"].as_str().unwrap().to_owned(),
    ))
}

fn source(folder: &Path, exchange: impl Exchange + 'static, lock_limit: Duration) -> LoginSource {
    LoginSource::new(
        PROVIDER.to_owned(),
        Flow::Xai,
        folder.to_owned(),
        Arc::new(exchange),
        lock_limit,
    )
}

/// The access token of the next attempt, or the text of its error.
async fn token_of(source: &LoginSource) -> Result<String, String> {
    match source.credential().await {
        Ok(Credential::OAuth(oauth)) => Ok(oauth.access_token.into_owned()),
        Ok(other) => panic!("{other:?}"),
        Err(error) => Err(chain_text(&*error)),
    }
}

/// Hold the lock of `folder` on another thread until `release` gets a message. Return once the lock is held.
fn hold_lock(folder: &Path) -> (mpsc::Sender<()>, std::thread::JoinHandle<()>) {
    let (held_sender, held) = mpsc::channel();
    let (release, released) = mpsc::channel::<()>();
    let files = Files {
        folder: folder.to_owned(),
    };
    let holder = std::thread::spawn(move || {
        let locked = files.lock(Duration::ZERO).unwrap().unwrap();
        held_sender.send(()).unwrap();
        released.recv().unwrap();
        drop(locked);
    });
    held.recv().unwrap();
    (release, holder)
}

/// Answers each exchange from the script after `delay` on the clock of tokio, as a slow provider.
#[derive(Debug, Clone, Default)]
struct Slow {
    delay: Duration,
    script: Answers,
}

impl Exchange for Slow {
    fn exchange<'a>(
        &'a self,
        request: &'a ExchangeRequest<'_>,
        deadline: Option<Instant>,
    ) -> BoxFuture<'a, Result<Answer, Fault>> {
        Box::pin(async move {
            tokio::time::sleep(self.delay).await;
            self.script.exchange(request, deadline).await
        })
    }
}

/// Holds each exchange until the gate opens, then answers from the script. `arrived` tells that an exchange waits.
#[derive(Debug, Clone, Default)]
struct Gated {
    gate: Arc<tokio::sync::Notify>,
    arrived: Arc<tokio::sync::Notify>,
    script: Answers,
}

impl Exchange for Gated {
    fn exchange<'a>(
        &'a self,
        request: &'a ExchangeRequest<'_>,
        deadline: Option<Instant>,
    ) -> BoxFuture<'a, Result<Answer, Fault>> {
        Box::pin(async move {
            self.arrived.notify_one();
            self.gate.notified().await;
            self.script.exchange(request, deadline).await
        })
    }
}

#[tokio::test(start_paused = true)]
async fn a_login_polls_until_the_approval_and_saves_the_login_for_the_user_alone() {
    let folder = folder("a_login_polls_until_the_approval_and_saves_the_login_for_the_user_alone");
    let other = json!({"other": {"access_token": "a", "refresh_token": "r", "expires_at": 1}});
    fs::write(folder.join(FILE), other.to_string()).unwrap();
    let answers = Answers::default();
    answers.push(200, START);
    answers.push(400, r#"{"error":"authorization_pending"}"#);
    answers.push(400, r#"{"error":"slow_down"}"#);
    answers.push_fault(Fault::ConnectionLost);
    answers.push(503, "{}");
    answers.push(200, r#"{"access_token":"at","refresh_token":"rt","expires_in":3600}"#);
    let started = tokio::time::Instant::now();
    let mut shown = None;

    let logged_in = login(PROVIDER, Flow::Xai, folder.clone(), &answers, |pending| {
        shown = Some((pending.user_code.clone(), pending.verification_url.clone()));
    })
    .await;

    assert!(logged_in.is_ok(), "{logged_in:?}");
    assert_eq!(shown, Some(("UC".to_owned(), "https://x.ai/d?c=UC".to_owned())));
    assert_eq!(answers.bodies().len(), 6);
    // One interval before the first poll, 5 seconds more after `slow_down`, and a doubled backoff after each failure.
    assert_eq!(started.elapsed(), Duration::from_secs(1 + 1 + 6 + 6 + 12));
    let content = file(&folder);
    assert_eq!(content["other"], other["other"]);
    assert_eq!(content[PROVIDER]["access_token"], "at");
    assert_eq!(content[PROVIDER]["refresh_token"], "rt");
    let expires_at = content[PROVIDER]["expires_at"].as_u64().unwrap();
    let hour_from_now = millis(SystemTime::now() + Duration::from_secs(3600));
    assert!(expires_at.abs_diff(hour_from_now) < 60_000, "{expires_at}");
    let mode = fs::metadata(folder.join(FILE)).unwrap().permissions().mode();
    assert_eq!(mode & 0o777, 0o600);
}

#[tokio::test(start_paused = true)]
async fn a_denied_login_or_a_grant_without_a_refresh_token_saves_nothing() {
    let folder = folder("a_denied_login_or_a_grant_without_a_refresh_token_saves_nothing");
    let answers = Answers::default();
    answers.push(200, START);
    answers.push(400, r#"{"error":"access_denied"}"#);
    answers.push(200, START);
    answers.push(200, r#"{"access_token":"at"}"#);

    let denied = login(PROVIDER, Flow::Xai, folder.clone(), &answers, |_| {}).await;
    let no_refresh = login(PROVIDER, Flow::Xai, folder.clone(), &answers, |_| {}).await;

    assert!(
        matches!(denied, Err(AuthError::Refused(OAuthError::Permanent))),
        "{denied:?}"
    );
    assert!(matches!(no_refresh, Err(AuthError::NoRefreshToken)), "{no_refresh:?}");
    assert_eq!(file(&folder), json!({}));
}

#[tokio::test(start_paused = true)]
async fn a_login_without_an_approval_ends_at_its_limit() {
    let folder = folder("a_login_without_an_approval_ends_at_its_limit");
    let answers = Answers::default();
    // Three polls at 299 seconds fit in the 15 minutes of the limit, and a fourth does not.
    answers.push(
        200,
        r#"{"device_code":"dc","user_code":"UC","verification_uri":"u","interval":299}"#,
    );
    for _ in 0..3 {
        answers.push(400, r#"{"error":"authorization_pending"}"#);
    }

    let expired = login(PROVIDER, Flow::Xai, folder, &answers, |_| {}).await;

    assert!(matches!(expired, Err(AuthError::Expired)), "{expired:?}");
    assert_eq!(answers.bodies().len(), 4);
}

#[tokio::test(start_paused = true)]
async fn the_login_limit_counts_the_time_of_the_requests() {
    let folder = folder("the_login_limit_counts_the_time_of_the_requests");
    let slow = Slow {
        delay: Duration::from_secs(10),
        script: Answers::default(),
    };
    // The waits fit three polls at 299 seconds, but the requests add 10 seconds each, so the third one is late.
    slow.script.push(
        200,
        r#"{"device_code":"dc","user_code":"UC","verification_uri":"u","interval":299}"#,
    );
    for _ in 0..2 {
        slow.script.push(400, r#"{"error":"authorization_pending"}"#);
    }

    let expired = login(PROVIDER, Flow::Xai, folder, &slow, |_| {}).await;

    assert!(matches!(expired, Err(AuthError::Expired)), "{expired:?}");
    assert_eq!(slow.script.bodies().len(), 3);
}

#[tokio::test]
async fn a_valid_login_serves_each_attempt_with_no_refresh() {
    let folder = folder("a_valid_login_serves_each_attempt_with_no_refresh");
    save(&folder, "at", "rt", 3600);
    let answers = Answers::default();

    let token = token_of(&source(&folder, answers.clone(), LOCK_LIMIT)).await;

    assert_eq!(token, Ok("at".to_owned()));
    assert_eq!(answers.bodies(), Vec::<String>::new());
}

#[tokio::test]
async fn no_login_is_an_error_that_names_the_login_command() {
    let folder = folder("no_login_is_an_error_that_names_the_login_command");

    let token = token_of(&source(&folder, Answers::default(), LOCK_LIMIT)).await;

    assert_eq!(
        token,
        Err("no login for xai-grok: run `yuke login xai-grok`".to_owned())
    );
}

#[tokio::test]
async fn a_login_near_its_end_refreshes_and_keeps_its_refresh_token_when_none_comes() {
    let folder = folder("a_login_near_its_end_refreshes_and_keeps_its_refresh_token_when_none_comes");
    save(&folder, "at", "rt", 60);
    let answers = Answers::default();
    answers.push(200, r#"{"access_token":"new","expires_in":3600}"#);
    let source = source(&folder, answers.clone(), LOCK_LIMIT);

    let first = token_of(&source).await;
    let second = token_of(&source).await;

    assert_eq!(first, Ok("new".to_owned()));
    assert_eq!(second, Ok("new".to_owned()));
    assert_eq!(saved(&folder), Some(("new".to_owned(), "rt".to_owned())));
    let exchanges = answers.bodies();
    assert_eq!(exchanges.len(), 1);
    assert!(exchanges[0].ends_with("&refresh_token=rt"), "{}", exchanges[0]);
}

// Another process can refresh while this one waits for the lock. The spent token must not go out again.
#[tokio::test]
async fn a_login_that_another_process_refreshed_during_the_wait_needs_no_refresh() {
    let folder = folder("a_login_that_another_process_refreshed_during_the_wait_needs_no_refresh");
    save(&folder, "at", "rt", 60);
    let answers = Answers::default();
    let source = source(&folder, answers.clone(), LOCK_LIMIT);
    let (release, holder) = hold_lock(&folder);

    let attempt = tokio::spawn(async move { token_of(&source).await });
    tokio::time::sleep(Duration::from_millis(250)).await;
    // The holder of the lock is the other process, so its write needs no lock of its own.
    save(&folder, "fresh", "rt2", 3600);
    release.send(()).unwrap();
    holder.join().unwrap();
    let token = attempt.await.unwrap();

    assert_eq!(token, Ok("fresh".to_owned()));
    assert_eq!(answers.bodies(), Vec::<String>::new());
}

#[tokio::test]
async fn past_the_lock_limit_only_a_valid_token_serves_and_nothing_refreshes() {
    let folder = folder("past_the_lock_limit_only_a_valid_token_serves_and_nothing_refreshes");
    let answers = Answers::default();
    let source = source(&folder, answers.clone(), Duration::from_millis(200));
    let (release, holder) = hold_lock(&folder);

    save(&folder, "at", "rt", 60);
    let valid = token_of(&source).await;
    save(&folder, "at", "rt", -1);
    let expired = token_of(&source).await;
    release.send(()).unwrap();
    holder.join().unwrap();

    assert_eq!(valid, Ok("at".to_owned()));
    assert!(
        expired
            .as_ref()
            .unwrap_err()
            .ends_with("another process holds the lock"),
        "{expired:?}"
    );
    assert_eq!(answers.bodies(), Vec::<String>::new());
}

#[tokio::test]
async fn a_refresh_that_fails_for_now_serves_a_valid_token_and_keeps_the_login() {
    let folder = folder("a_refresh_that_fails_for_now_serves_a_valid_token_and_keeps_the_login");
    let answers = Answers::default();
    answers.push(503, "{}");
    answers.push(503, "{}");
    let source = source(&folder, answers.clone(), LOCK_LIMIT);

    save(&folder, "at", "rt", 60);
    let valid = token_of(&source).await;
    save(&folder, "at", "rt", -1);
    let expired = token_of(&source).await;

    assert_eq!(valid, Ok("at".to_owned()));
    assert_eq!(
        expired,
        Err("the login for xai-grok expired and did not refresh: the login provider failed for now".to_owned())
    );
    assert_eq!(saved(&folder), Some(("at".to_owned(), "rt".to_owned())));
}

// The refresh can take long, so a token that ends during it must not serve.
#[tokio::test]
async fn a_token_that_ends_during_a_failed_refresh_does_not_serve() {
    let folder = folder("a_token_that_ends_during_a_failed_refresh_does_not_serve");
    save(&folder, "at", "rt", 1);
    let slow = Slow {
        delay: Duration::from_millis(1500),
        script: Answers::default(),
    };
    slow.script.push(503, "{}");

    let token = token_of(&source(&folder, slow, LOCK_LIMIT)).await;

    assert!(
        token.as_ref().unwrap_err().contains("expired and did not refresh"),
        "{token:?}"
    );
}

#[tokio::test]
async fn a_refused_or_unknown_refresh_removes_the_login() {
    let folder = folder("a_refused_or_unknown_refresh_removes_the_login");
    let answers = Answers::default();
    answers.push(400, r#"{"error":"invalid_grant"}"#);
    // The request can have reached the provider, so its token can be spent.
    answers.push_fault(Fault::ConnectionLost);
    let source = source(&folder, answers.clone(), LOCK_LIMIT);
    let ended = Err("the login for xai-grok ended: run `yuke login xai-grok` again".to_owned());

    save(&folder, "at", "rt", 60);
    let refused = token_of(&source).await;
    let after_refused = saved(&folder);
    save(&folder, "at", "rt", 60);
    let unknown = token_of(&source).await;
    let after_unknown = saved(&folder);

    assert_eq!(refused, ended);
    assert_eq!(after_refused, None);
    assert_eq!(unknown, ended);
    assert_eq!(after_unknown, None);
}

// A refresh that cannot save its login can have spent the old token, which the file still holds.
#[tokio::test]
async fn a_refresh_that_cannot_save_never_sends_the_old_token_again() {
    let folder = folder("a_refresh_that_cannot_save_never_sends_the_old_token_again");
    save(&folder, "at", "rt", 60);
    // The lock file exists, so the source can open it in the folder that it cannot write.
    fs::write(folder.join(LOCK), "").unwrap();
    let answers = Answers::default();
    answers.push(200, r#"{"access_token":"new","refresh_token":"rt2","expires_in":3600}"#);
    let source = source(&folder, answers.clone(), LOCK_LIMIT);
    fs::set_permissions(&folder, Permissions::from_mode(0o500)).unwrap();

    let refreshed = token_of(&source).await;
    let again = token_of(&source).await;
    fs::set_permissions(&folder, Permissions::from_mode(0o700)).unwrap();

    assert_eq!(refreshed, Ok("new".to_owned()));
    // The old access token is still valid, so it serves without a second refresh.
    assert_eq!(again, Ok("at".to_owned()));
    assert_eq!(answers.bodies().len(), 1);
}

#[tokio::test]
async fn a_cancelled_attempt_still_saves_the_login_of_its_refresh() {
    let folder = folder("a_cancelled_attempt_still_saves_the_login_of_its_refresh");
    save(&folder, "at", "rt", 60);
    let gated = Gated::default();
    gated
        .script
        .push(200, r#"{"access_token":"new","refresh_token":"rt2","expires_in":3600}"#);
    let source = source(&folder, gated.clone(), LOCK_LIMIT);

    let cancelled = tokio::time::timeout(Duration::from_millis(100), token_of(&source)).await;
    gated.gate.notify_one();
    let mut waited = Duration::ZERO;
    while saved(&folder) != Some(("new".to_owned(), "rt2".to_owned())) && waited < Duration::from_secs(5) {
        tokio::time::sleep(Duration::from_millis(10)).await;
        waited += Duration::from_millis(10);
    }

    assert!(cancelled.is_err(), "{cancelled:?}");
    assert_eq!(saved(&folder), Some(("new".to_owned(), "rt2".to_owned())));
    assert_eq!(gated.script.bodies().len(), 1);
}

// A refresh answer can omit the ID token. The account must stay, or each later request loses its account header.
#[tokio::test]
async fn a_refresh_keeps_the_account_and_each_credential_names_it() {
    let folder = folder("a_refresh_keeps_the_account_and_each_credential_names_it");
    let expires_at = millis(SystemTime::now() + Duration::from_secs(60));
    let content = json!({"openai-codex": {
        "access_token": "at", "refresh_token": "rt", "expires_at": expires_at, "account_id": "account-1"
    }});
    fs::write(folder.join(FILE), content.to_string()).unwrap();
    let answers = Answers::default();
    answers.push(200, r#"{"access_token":"new","expires_in":3600}"#);
    let source = LoginSource::new(
        "openai-codex".to_owned(),
        Flow::Codex,
        folder.clone(),
        Arc::new(answers.clone()),
        LOCK_LIMIT,
    );

    let credential = source.credential().await.unwrap();

    let Credential::OAuth(oauth) = credential else {
        panic!("{credential:?}");
    };
    assert_eq!(oauth.access_token, "new");
    assert_eq!(
        *oauth.headers,
        [yuke_ai::transport::Header::new("ChatGPT-Account-Id", "account-1")]
    );
    assert_eq!(file(&folder)["openai-codex"]["account_id"], "account-1");
}

/// A pushed token that ends `ends_in` seconds from now. The test builds it as is, so it can also be expired.
fn pushed(access_token: &str, ends_in: i64) -> Pushed {
    Pushed {
        access_token: access_token.to_owned(),
        expires_at: millis(SystemTime::now()).saturating_add_signed(ends_in * 1000),
        account_id: None,
    }
}

#[tokio::test]
async fn a_pushed_token_replaces_a_valid_login_and_the_newest_push_wins() {
    let folder = folder("pushed_replaces_login");
    save(&folder, "from-file", "refresh", 3600);
    let source = source(&folder, Answers::default(), LOCK_LIMIT);
    assert_eq!(token_of(&source).await, Ok("from-file".to_owned()));

    // A pushed token serves until its end, with no margin, because the client refreshes it.
    source.push(pushed("first", 60));
    assert_eq!(token_of(&source).await, Ok("first".to_owned()));
    source.clone().push(pushed("second", 3600));

    assert_eq!(token_of(&source).await, Ok("second".to_owned()));
    assert_eq!(saved(&folder), Some(("from-file".to_owned(), "refresh".to_owned())));
}

#[tokio::test]
async fn an_expired_push_fails_and_never_falls_back_to_the_login_or_a_refresh() {
    let folder = folder("expired_push");
    // A refresh would take an answer that the script does not have, and the test would panic.
    save(&folder, "from-file", "refresh", 3600);
    let source = source(&folder, Answers::default(), LOCK_LIMIT);

    source.push(pushed("pushed", -1));

    assert_eq!(
        token_of(&source).await,
        Err(format!(
            "the accessToken of credential/update for {PROVIDER} expired: send a new credential/update"
        ))
    );
}

#[tokio::test]
async fn a_pushed_token_of_the_codex_flow_names_its_account() {
    let source = LoginSource::new(
        "openai-codex".to_owned(),
        Flow::Codex,
        folder("pushed_account"),
        Arc::new(Answers::default()),
        LOCK_LIMIT,
    );

    source.push(Pushed {
        account_id: Some("account-1".to_owned()),
        ..pushed("pushed", 3600)
    });

    let Ok(Credential::OAuth(oauth)) = source.credential().await else {
        panic!("no OAuth credential");
    };
    assert_eq!(oauth.access_token, "pushed");
    assert_eq!(
        *oauth.headers,
        [yuke_ai::transport::Header::new("ChatGPT-Account-Id", "account-1")]
    );
}

#[tokio::test]
async fn a_push_during_the_refresh_of_the_login_serves_that_attempt() {
    let folder = folder("push_during_refresh");
    save(&folder, "old", "rt", 1);
    let gated = Gated::default();
    gated.script.push(
        200,
        r#"{"access_token":"refreshed","refresh_token":"rt2","expires_in":3600}"#,
    );
    let source = source(&folder, gated.clone(), LOCK_LIMIT);
    let attempt = tokio::spawn({
        let source = source.clone();
        async move { token_of(&source).await }
    });
    // The attempt found no push, and its refresh now waits at the gate.
    gated.arrived.notified().await;

    source.push(pushed("pushed", 3600));
    gated.gate.notify_one();

    assert_eq!(attempt.await.unwrap(), Ok("pushed".to_owned()));
    assert_eq!(saved(&folder), Some(("refreshed".to_owned(), "rt2".to_owned())));
}
