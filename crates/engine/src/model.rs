//! The model of a turn: its target and the source of its credential, and the error of a round.

use std::error::Error;
use std::fmt;
use std::sync::Arc;

use async_trait::async_trait;
use yuke_ai::Target;
use yuke_ai::route::Credential;

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

/// A target and the source of its credential. A planned model brings its own source, so it never takes the credential
/// of the driver's model.
#[derive(Clone)]
pub struct Model {
    /// Where and how the requests go.
    pub target: Target,
    /// Gives the credential of each attempt.
    pub source: Arc<dyn CredentialSource>,
}

impl fmt::Debug for Model {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.debug_struct("Model")
            .field("target", &self.target)
            .finish_non_exhaustive()
    }
}

/// Why a round failed after its retries.
#[derive(Debug, Clone)]
pub enum RoundError {
    /// The credential source gave no credential. The driver sent nothing for that attempt.
    Credential(Arc<dyn Error + Send + Sync>),
    /// The request could not be encoded, or its last attempt failed.
    Model(yuke_ai::Error),
}

impl fmt::Display for RoundError {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            Self::Credential(error) => fmt::Display::fmt(error, f),
            Self::Model(error) => fmt::Display::fmt(error, f),
        }
    }
}

impl Error for RoundError {
    // The text is the text of the inner error, so the source is the source of the inner error.
    fn source(&self) -> Option<&(dyn Error + 'static)> {
        match self {
            Self::Credential(error) => error.source(),
            Self::Model(error) => error.source(),
        }
    }
}

impl From<yuke_ai::Error> for RoundError {
    fn from(error: yuke_ai::Error) -> Self {
        RoundError::Model(error)
    }
}
