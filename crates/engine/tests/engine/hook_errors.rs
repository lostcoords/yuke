use std::error::Error;
use std::fmt;
use std::sync::atomic::{AtomicUsize, Ordering};

use async_trait::async_trait;
use yuke_ai::{Block, FinishReason};
use yuke_engine::{Driver, Hooks, RoundDecision, RoundError, RoundPlan, RoundStart, TurnEnd, TurnError, chain_text};
use yuke_testing::{NoWait, ScriptedTransport, failed_reply, model, text_reply};

use crate::support::{Queue, Replay, block_on};

/// A hook error. Its text names no cause, so only `source` gives the cause.
#[derive(Debug)]
struct HookFailed(std::io::Error);

impl fmt::Display for HookFailed {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.write_str("the test hook failed")
    }
}

impl Error for HookFailed {
    fn source(&self) -> Option<&(dyn Error + 'static)> {
        Some(&self.0)
    }
}

/// The round hook that fails.
#[derive(Clone, Copy, PartialEq, Eq)]
enum RoundHook {
    Before,
    Retry,
    After,
}

/// Hooks that fail at one point, and count the `retry_round` calls.
struct Failing {
    point: RoundHook,
    retries: AtomicUsize,
}

impl Failing {
    fn at(point: RoundHook) -> Self {
        Failing {
            point,
            retries: AtomicUsize::new(0),
        }
    }

    fn fail_at<T>(&self, point: RoundHook, answer: T) -> Result<T, Box<dyn Error + Send + Sync>> {
        if self.point == point {
            return Err(Box::new(HookFailed(std::io::Error::other("the cause"))));
        }
        Ok(answer)
    }
}

#[async_trait]
impl Hooks for Failing {
    async fn before_round(&self, _: &RoundStart<'_>) -> Result<RoundPlan, Box<dyn Error + Send + Sync>> {
        self.fail_at(RoundHook::Before, RoundPlan::default())
    }

    async fn retry_round(
        &self,
        _: &RoundStart<'_>,
        _: &RoundError,
    ) -> Result<Option<RoundPlan>, Box<dyn Error + Send + Sync>> {
        self.retries.fetch_add(1, Ordering::Relaxed);
        self.fail_at(RoundHook::Retry, None)
    }

    async fn after_round(
        &self,
        _: &[Block],
        _: Option<FinishReason>,
    ) -> Result<RoundDecision, Box<dyn Error + Send + Sync>> {
        self.fail_at(RoundHook::After, RoundDecision::Proceed)
    }
}

#[test]
fn a_failed_before_round_hook_ends_the_turn_before_any_request() {
    let transport = ScriptedTransport::new([text_reply("unused")]);
    let model = model();
    let hooks = Failing::at(RoundHook::Before);
    let journal = Replay::default();
    let driver = Driver::new(&transport, &model, &NoWait).hooks(&hooks).journal(&journal);
    let mut context = Vec::new();

    let outcome = block_on(driver.turn(&mut context, vec![Block::user_text("go")]).run());

    let Err(TurnError::Round(error)) = outcome else {
        panic!("expected a round error, got {outcome:?}");
    };

    assert!(matches!(error, RoundError::Hook { after: None, .. }), "{error:?}");
    assert_eq!(chain_text(&error), "the test hook failed: the cause");
    assert_eq!(transport.requests(), Vec::<String>::new());
    assert_eq!(hooks.retries.load(Ordering::Relaxed), 0);
    assert_eq!(context, [Block::user_text("go")]);
    assert_eq!(
        journal.shapes(),
        [
            (vec![Block::user_text("go")], None),
            (
                vec![],
                Some(TurnEnd::Failed("the test hook failed: the cause".to_owned()))
            )
        ]
    );
}

#[test]
fn a_failed_retry_round_hook_ends_the_turn_and_names_the_round_failure_after_its_text() {
    let transport = ScriptedTransport::new([failed_reply("cut"), text_reply("unused")]);
    let model = model();
    let hooks = Failing::at(RoundHook::Retry);
    let driver = Driver::new(&transport, &model, &NoWait).hooks(&hooks);
    let mut context = Vec::new();

    let outcome = block_on(driver.turn(&mut context, vec![Block::user_text("go")]).run());

    let Err(TurnError::Round(error)) = outcome else {
        panic!("expected a round error, got {outcome:?}");
    };

    assert!(matches!(error, RoundError::Hook { after: Some(_), .. }), "{error:?}");
    assert_eq!(
        chain_text(&error),
        "the test hook failed (after: the provider returned a server error: overloaded_error: Overloaded): the cause"
    );
    assert_eq!(transport.requests().len(), 1);
    assert_eq!(hooks.retries.load(Ordering::Relaxed), 1);
    assert_eq!(context, [Block::user_text("go")]);
}

#[test]
fn a_failed_after_round_hook_ends_the_turn_and_keeps_the_answer_and_the_input() {
    let transport = ScriptedTransport::new([text_reply("done"), text_reply("unused")]);
    let model = model();
    let hooks = Failing::at(RoundHook::After);
    let inbox = Queue::new(vec![Block::user_text("steer")]);
    let journal = Replay::default();
    let driver = Driver::new(&transport, &model, &NoWait)
        .hooks(&hooks)
        .inbox(&inbox)
        .journal(&journal);
    let mut context = Vec::new();

    let outcome = block_on(driver.turn(&mut context, vec![Block::user_text("go")]).run());

    let Err(TurnError::Round(error)) = outcome else {
        panic!("expected a round error, got {outcome:?}");
    };

    assert!(matches!(error, RoundError::Hook { after: None, .. }), "{error:?}");
    assert_eq!(chain_text(&error), "the test hook failed: the cause");
    assert_eq!(transport.requests().len(), 1);
    assert_eq!(context, [Block::user_text("go"), Block::assistant_text("done")]);
    assert_eq!(inbox.held(), [Block::user_text("steer")]);
    // The answer commit comes before the hook, so the failed end holds no block.
    assert_eq!(
        journal.shapes(),
        [
            (vec![Block::user_text("go")], None),
            (vec![Block::assistant_text("done")], None),
            (
                vec![],
                Some(TurnEnd::Failed("the test hook failed: the cause".to_owned()))
            )
        ]
    );
}
