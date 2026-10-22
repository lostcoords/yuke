use std::error::Error;
use std::fmt;
use std::future::pending;
use std::sync::atomic::{AtomicUsize, Ordering};
use std::sync::{Arc, Mutex};

use async_trait::async_trait;
use yuke_ai::route::{Credential, CredentialHeader, Route};
use yuke_ai::{Block, Target};
use yuke_engine::{
    CancellationToken, CredentialSource, Driver, Hooks, Model, Outcome, RoundError, RoundPlan, TurnError, TurnEvent,
};
use yuke_testing::{NoWait, ScriptedTransport, failed_reply, model, overloaded_reply, target, text_reply};

use crate::support::{Script, block_on};

/// A model of the test target under the name `name`, with an `x-api-key` header and `source`.
fn keyed(name: &'static str, source: impl CredentialSource + 'static) -> Model {
    Model {
        target: Target {
            model: name.into(),
            route: Route {
                credential_header: Some(CredentialHeader::XApiKey),
                ..target().route
            },
            ..target()
        },
        source: Arc::new(source),
        context_window: None,
    }
}

/// The name of each event of a turn, in order, without the model events.
#[derive(Default)]
struct Events(Mutex<Vec<&'static str>>);

impl Events {
    fn observe(&self, event: &TurnEvent<'_>) {
        let name = match event {
            TurnEvent::ResponseStarted => "started",
            TurnEvent::ResponseFailed(_) => "response failed",
            TurnEvent::ResponseCancelled { .. } => "cancelled",
            TurnEvent::RoundFailed(_) => "round failed",
            TurnEvent::RetryScheduled { .. } => "retry",
            _ => return,
        };
        self.0.lock().unwrap().push(name);
    }

    fn names(&self) -> Vec<&'static str> {
        self.0.lock().unwrap().clone()
    }
}

/// Gives `key-1`, `key-2`, and so on: a new key at each call.
#[derive(Default)]
struct Rotating {
    calls: AtomicUsize,
}

#[async_trait]
impl CredentialSource for Rotating {
    async fn credential(&self) -> Result<Credential, Box<dyn Error + Send + Sync>> {
        let call = self.calls.fetch_add(1, Ordering::Relaxed) + 1;
        Ok(Credential::ApiKey(format!("key-{call}").into()))
    }
}

#[derive(Debug)]
struct Expired;

impl fmt::Display for Expired {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.write_str("the grant expired")
    }
}

impl Error for Expired {}

/// Has no credential.
struct Missing;

#[async_trait]
impl CredentialSource for Missing {
    async fn credential(&self) -> Result<Credential, Box<dyn Error + Send + Sync>> {
        Err(Box::new(Expired))
    }
}

/// Cancels the turn, then never gives a credential.
struct CancelOnAsk(CancellationToken);

#[async_trait]
impl CredentialSource for CancelOnAsk {
    async fn credential(&self) -> Result<Credential, Box<dyn Error + Send + Sync>> {
        self.0.cancel();
        pending().await
    }
}

#[test]
fn a_retry_presents_the_credential_of_its_own_attempt() {
    let transport = ScriptedTransport::new([overloaded_reply(), text_reply("done")]);
    let model = keyed("test-model", Rotating::default());
    let driver = Driver::new(&transport, &model, &NoWait);
    let mut context = Vec::new();

    let outcome = block_on(driver.turn(&mut context, vec![Block::user_text("go")]).run());

    assert!(matches!(outcome, Ok(Outcome::Completed { .. })), "{outcome:?}");
    assert_eq!(
        transport.header("x-api-key"),
        [Some("key-1".to_owned()), Some("key-2".to_owned())]
    );
    let requests = transport.requests();
    assert_eq!(requests[0], requests[1]);
}

#[test]
fn a_missing_credential_fails_the_round_before_a_send() {
    let transport = ScriptedTransport::new([text_reply("unused")]);
    let model = keyed("test-model", Missing);
    let driver = Driver::new(&transport, &model, &NoWait);
    let mut context = Vec::new();
    let events = Events::default();

    let outcome = block_on(
        driver
            .turn(&mut context, vec![Block::user_text("go")])
            .observer(&|event: &TurnEvent<'_>| events.observe(event))
            .run(),
    );

    let Err(TurnError::Round(error @ RoundError::Credential(_))) = outcome else {
        panic!("expected a credential failure, got {outcome:?}");
    };
    assert_eq!(error.to_string(), "the grant expired");
    assert_eq!(transport.requests(), Vec::<String>::new());
    // No attempt started, so no response event comes before the failure of the round.
    assert_eq!(events.names(), ["round failed"]);
    assert_eq!(context, [Block::user_text("go")]);
}

#[test]
fn a_cancel_during_the_credential_wait_sends_nothing() {
    let transport = ScriptedTransport::new([text_reply("unused")]);
    let cancellation_token = CancellationToken::new();
    let model = keyed("test-model", CancelOnAsk(cancellation_token.clone()));
    let driver = Driver::new(&transport, &model, &NoWait);
    let mut context = Vec::new();
    let events = Events::default();

    let outcome = block_on(
        driver
            .turn(&mut context, vec![Block::user_text("go")])
            .observer(&|event: &TurnEvent<'_>| events.observe(event))
            .cancellation_token(cancellation_token)
            .run(),
    );

    assert!(matches!(outcome, Ok(Outcome::Cancelled)), "{outcome:?}");
    assert_eq!(transport.requests(), Vec::<String>::new());
    assert_eq!(events.names(), Vec::<&str>::new());
}

#[test]
fn a_plan_model_presents_its_own_credential() {
    // The failure comes after output, so the retry policy of `ai` sends it no second attempt.
    let transport = ScriptedTransport::new([failed_reply("cut"), text_reply("done")]);
    let model = keyed("test-model", Credential::ApiKey("driver-key".into()));
    let hooks = Script::default().retries([Some(RoundPlan {
        model: Some(keyed("fallback-model", Credential::ApiKey("fallback-key".into()))),
        ..RoundPlan::default()
    })]);
    let driver = Driver::new(&transport, &model, &NoWait).hooks(&hooks);
    let mut context = Vec::new();

    let outcome = block_on(driver.turn(&mut context, vec![Block::user_text("go")]).run());

    assert!(matches!(outcome, Ok(Outcome::Completed { .. })), "{outcome:?}");
    assert_eq!(
        hooks.calls(),
        [
            "retry the provider returned a server error: overloaded_error: Overloaded",
            "stop done"
        ]
    );
    assert_eq!(
        transport.header("x-api-key"),
        [Some("driver-key".to_owned()), Some("fallback-key".to_owned())]
    );
}

/// Sends a round whose credential failed again with a model that has a key.
struct Refreshed;

#[async_trait]
impl Hooks for Refreshed {
    async fn retry_round(
        &self,
        _: &[Block],
        failure: &RoundError,
    ) -> Result<Option<RoundPlan>, Box<dyn Error + Send + Sync>> {
        Ok(matches!(failure, RoundError::Credential(_)).then(|| RoundPlan {
            model: Some(keyed("test-model", Credential::ApiKey("fresh-key".into()))),
            ..RoundPlan::default()
        }))
    }
}

#[test]
fn a_hook_can_retry_a_round_whose_credential_failed() {
    let transport = ScriptedTransport::new([text_reply("done")]);
    let model = keyed("test-model", Missing);
    let driver = Driver::new(&transport, &model, &NoWait).hooks(&Refreshed);
    let mut context = Vec::new();

    let outcome = block_on(driver.turn(&mut context, vec![Block::user_text("go")]).run());

    assert!(matches!(outcome, Ok(Outcome::Completed { .. })), "{outcome:?}");
    assert_eq!(transport.header("x-api-key"), [Some("fresh-key".to_owned())]);
}

/// Cancels the turn when a round fails, then never answers.
struct CancelOnRetry(CancellationToken);

#[async_trait]
impl Hooks for CancelOnRetry {
    async fn retry_round(
        &self,
        _: &[Block],
        _: &RoundError,
    ) -> Result<Option<RoundPlan>, Box<dyn Error + Send + Sync>> {
        self.0.cancel();
        pending().await
    }
}

#[test]
fn a_cancel_during_retry_round_sends_no_other_request() {
    let transport = ScriptedTransport::new([failed_reply("cut"), text_reply("unused")]);
    let model = model();
    let cancellation_token = CancellationToken::new();
    let hooks = CancelOnRetry(cancellation_token.clone());
    let driver = Driver::new(&transport, &model, &NoWait).hooks(&hooks);
    let mut context = Vec::new();

    let outcome = block_on(
        driver
            .turn(&mut context, vec![Block::user_text("go")])
            .cancellation_token(cancellation_token)
            .run(),
    );

    assert!(matches!(outcome, Ok(Outcome::Cancelled)), "{outcome:?}");
    assert_eq!(transport.requests().len(), 1);
}
