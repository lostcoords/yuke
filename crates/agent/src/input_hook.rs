//! The check of each input before a turn takes it.

use std::error::Error;

use async_trait::async_trait;
use yuke_protocol::PendingInput;

/// What a turn does with one pending input.
#[derive(Debug, Clone, PartialEq)]
pub enum InputDecision {
    /// The turn takes the input as it is.
    Keep,
    /// The model reads these blocks in place of the input. The user still sees the sent content.
    Replace(Vec<yuke_ai::Block>),
    /// The store removes the input, and the turn does not take it.
    Remove,
}

/// The check of each pending input before a turn takes it: at the start of the turn, and after each round.
#[async_trait]
pub trait InputHook: Send + Sync {
    /// The decision for `input`.
    ///
    /// # Errors
    ///
    /// Returns why the check failed. The turn then fails, and the input stays pending.
    async fn before_input(&self, input: &PendingInput) -> Result<InputDecision, Box<dyn Error + Send + Sync>>;
}

/// The check of a turn without a hook: it keeps each input.
pub(crate) struct NoInputHook;

#[async_trait]
impl InputHook for NoInputHook {
    async fn before_input(&self, _input: &PendingInput) -> Result<InputDecision, Box<dyn Error + Send + Sync>> {
        Ok(InputDecision::Keep)
    }
}
