//! The model of a turn: its target, the source of its credential, and its context window, and the error of a round.

use std::error::Error;
use std::fmt;
use std::sync::Arc;

use async_trait::async_trait;
use yuke_ai::Target;
use yuke_ai::route::Credential;

use crate::turn_state::chain_text;

/// Gives the credential of each attempt. The caller supplies it, so a grant can change during a turn.
#[async_trait]
pub trait CredentialSource: Send + Sync {
    /// The credential of the next attempt. The driver asks before each attempt, a retry too. A cancel drops the call.
    ///
    /// # Errors
    ///
    /// Returns why no credential exists, for example an expired grant. The driver sends nothing for that attempt.
    async fn credential(&self) -> Result<Credential, Box<dyn Error + Send + Sync>>;
}

// A fixed credential, such as an API key, is its own source.
#[async_trait]
impl CredentialSource for Credential {
    async fn credential(&self) -> Result<Credential, Box<dyn Error + Send + Sync>> {
        Ok(self.clone())
    }
}

/// A target, the source of its credential, and its context window. A planned model brings its own source, so it never
/// takes the credential of the driver's model.
#[derive(Clone)]
pub struct Model {
    /// Where and how the requests go.
    pub target: Target,
    /// Gives the credential of each attempt.
    pub source: Arc<dyn CredentialSource>,
    /// The context window in tokens, or `None` when the caller knows none. [`crate::Hooks::before_round`] gets it.
    pub context_window: Option<u64>,
}

impl fmt::Debug for Model {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.debug_struct("Model")
            .field("target", &self.target)
            .finish_non_exhaustive()
    }
}

/// Why a round failed.
#[derive(Debug)]
pub enum RoundError {
    /// The credential source gave no credential. The driver sent nothing for that attempt.
    Credential(Box<dyn Error + Send + Sync>),
    /// The request could not be encoded, or its last attempt failed.
    Model(yuke_ai::Error),
    /// A round hook of [`crate::Hooks`] failed.
    Hook {
        /// Why the hook failed.
        error: Box<dyn Error + Send + Sync>,
        /// The round failure that [`crate::Hooks::retry_round`] received. `None` for the other hooks.
        after: Option<Box<RoundError>>,
    },
    /// The inbox of the driver failed to give its input. The input stays in the inbox.
    Inbox(Box<dyn Error + Send + Sync>),
}

impl fmt::Display for RoundError {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            Self::Credential(error) | Self::Inbox(error) => fmt::Display::fmt(error, f),
            Self::Model(error) => fmt::Display::fmt(error, f),
            Self::Hook { error, after } => {
                fmt::Display::fmt(error, f)?;
                // The source chain gives the causes of the hook error only, so the text keeps each cause of `after`.
                match after {
                    Some(after) => write!(f, " (after: {})", chain_text(after.as_ref())),
                    None => Ok(()),
                }
            }
        }
    }
}

impl Error for RoundError {
    // The text is the text of the inner error, so the source is the source of the inner error.
    fn source(&self) -> Option<&(dyn Error + 'static)> {
        match self {
            Self::Credential(error) | Self::Hook { error, .. } | Self::Inbox(error) => error.source(),
            Self::Model(error) => error.source(),
        }
    }
}

impl From<yuke_ai::Error> for RoundError {
    fn from(error: yuke_ai::Error) -> Self {
        RoundError::Model(error)
    }
}
