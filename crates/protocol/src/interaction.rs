//! The questions that a plugin puts to the user, and their answers. yuke itself asks nothing.

use serde::{Deserialize, Serialize};

use crate::SessionId;

/// The id of one open question. The server gives each question a new id.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash, PartialOrd, Ord, Serialize, Deserialize)]
#[cfg_attr(test, derive(ts_rs::TS))]
#[serde(transparent)]
pub struct InteractionId(pub u64);

/// The params of `interaction/requested`: a plugin asks the user a question.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[cfg_attr(test, derive(ts_rs::TS))]
#[serde(rename_all = "camelCase")]
pub struct InteractionRequestedParams {
    /// The id that the answer names.
    pub interaction_id: InteractionId,
    /// The session of the question. The field is absent for a question of the whole process.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub session_id: Option<SessionId>,
    /// The question.
    pub request: InteractionRequest,
}

/// One question. A client shows it in its own way.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[cfg_attr(test, derive(ts_rs::TS))]
#[serde(tag = "kind", rename_all = "snake_case")]
pub enum InteractionRequest {
    /// A yes or no question.
    Confirm {
        /// The question.
        title: String,
        /// More text about the question.
        message: String,
    },
    /// A choice of one option.
    Select {
        /// The question.
        title: String,
        /// The options, in display order.
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

/// The params of `interaction/closed`: the question ended without an answer of this client, so the client removes it.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[cfg_attr(test, derive(ts_rs::TS))]
#[serde(rename_all = "camelCase")]
pub struct InteractionClosedParams {
    /// The question.
    pub interaction_id: InteractionId,
}

/// The params of `interaction/respond`: the answer of the user.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[cfg_attr(test, derive(ts_rs::TS))]
#[serde(rename_all = "camelCase")]
pub struct InteractionRespondParams {
    /// The question.
    pub interaction_id: InteractionId,
    /// The answer.
    pub response: InteractionResponse,
}

/// An answer. Its kind matches the kind of the question, or the user canceled.
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
