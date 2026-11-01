//! The questions that a plugin or yuke puts to the user, and their answers.

use serde::{Deserialize, Serialize};

use crate::{InteractionId, SessionId};

/// A request to the user. A client shows it in its own way.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[cfg_attr(test, derive(ts_rs::TS))]
#[serde(tag = "kind", rename_all = "snake_case")]
pub enum InteractionRequest {
    /// One or more questions, which the user answers together.
    Questions {
        /// The questions, in display order. The ids are unique. The labels of a question are unique, and each question
        /// has an option or `other`.
        questions: Vec<Question>,
    },
}

/// One question of a request.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[cfg_attr(test, derive(ts_rs::TS))]
pub struct Question {
    /// The id that the answer names.
    pub id: String,
    /// A short name of the question.
    pub header: String,
    /// The question. It can have more than one line.
    pub question: String,
    /// The options, in display order. Without options and with `other`, the question is a text field.
    pub options: Vec<QuestionOption>,
    /// The user can choose more than one option. A missing flag is `false`.
    #[serde(default)]
    #[cfg_attr(test, ts(as = "Option<bool>", optional))]
    pub multiple: bool,
    /// The user can type an answer of their own. A missing flag is `false`.
    #[serde(default)]
    #[cfg_attr(test, ts(as = "Option<bool>", optional))]
    pub other: bool,
    /// The text field hides what the user types, as for a password. Only a question without options has it. A missing
    /// flag is `false`.
    #[serde(default)]
    #[cfg_attr(test, ts(as = "Option<bool>", optional))]
    pub secret: bool,
}

/// One option of a question.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[cfg_attr(test, derive(ts_rs::TS))]
pub struct QuestionOption {
    /// The text of the option, which the answer names.
    pub label: String,
    /// More text about the option.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub description: Option<String>,
}

/// The answer to one question.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[cfg_attr(test, derive(ts_rs::TS))]
pub struct QuestionAnswer {
    /// The id of the question.
    pub id: String,
    /// The labels of the chosen options. A question without `multiple` has at most one.
    pub values: Vec<String>,
    /// The text that the user typed, only for a question with `other`.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub other: Option<String>,
}

/// The response to a request. Its kind matches the kind of the request, or the user closed the request without an
/// answer.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[cfg_attr(test, derive(ts_rs::TS))]
#[serde(tag = "kind", rename_all = "snake_case")]
pub enum InteractionResponse {
    /// The answers to the questions.
    Questions {
        /// One answer per question, each with a value or `other`.
        answers: Vec<QuestionAnswer>,
    },
    /// The user closed the request without an answer.
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
