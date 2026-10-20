//! The questions that a plugin or yuke puts to the user, and their answers.

use serde::{Deserialize, Serialize};

use crate::{InteractionId, SessionId};

/// One question. A client shows it in its own way.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[cfg_attr(test, derive(ts_rs::TS))]
#[serde(tag = "kind", rename_all = "snake_case")]
pub enum InteractionRequest {
    /// A yes or no question.
    Confirm {
        /// The question.
        title: String,
        /// More text about the question. It can be empty.
        message: String,
    },
    /// A choice of one option.
    Select {
        /// The question.
        title: String,
        /// The options, in display order. They are unique.
        options: Vec<String>,
    },
    /// A line of text.
    Input {
        /// The question.
        title: String,
        /// The text that an empty field shows.
        #[serde(default, skip_serializing_if = "Option::is_none")]
        placeholder: Option<String>,
        /// The field hides what the user types, as for a password.
        secret: bool,
    },
}

impl InteractionRequest {
    /// The question.
    pub fn title(&self) -> &str {
        match self {
            Self::Confirm { title, .. } | Self::Select { title, .. } | Self::Input { title, .. } => title,
        }
    }
}

/// An answer. Its kind matches the kind of the question, or the question ended without an answer.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[cfg_attr(test, derive(ts_rs::TS))]
#[serde(tag = "kind", rename_all = "snake_case")]
pub enum InteractionResponse {
    /// The answer to a confirm question.
    Confirm {
        /// `true` for yes.
        value: bool,
    },
    /// The chosen option.
    Select {
        /// One of the options of the question.
        value: String,
    },
    /// The text that the user typed.
    Input {
        /// The text.
        value: String,
    },
    /// The user closed the question without an answer.
    Canceled,
}

/// The params of `interaction/respond`: the answer of the user to an open question.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[cfg_attr(test, derive(ts_rs::TS))]
#[serde(rename_all = "camelCase")]
pub struct InteractionRespondParams {
    /// The open session of the question.
    pub session_id: SessionId,
    /// The question.
    pub interaction_id: InteractionId,
    /// The answer.
    pub response: InteractionResponse,
}
