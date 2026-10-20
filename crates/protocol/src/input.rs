//! The inputs of a session: who sent each one, what the user saw, and what the model reads.

use std::fmt;

use serde::{Deserialize, Deserializer, Serialize};
use yuke_ai::Block;

use crate::InputId;

/// Who sent an input. It records the sender only. It grants no permission and sets no visibility.
#[derive(Debug, Clone, PartialEq, Eq, Hash, Serialize, Deserialize)]
#[cfg_attr(test, derive(ts_rs::TS))]
#[serde(tag = "kind", rename_all = "snake_case")]
pub enum InputSource {
    /// The user.
    User,
    /// A plugin. The host gives each plugin its name. The inputs of yuke itself use names that start with `host:`.
    Plugin {
        /// The name of the plugin.
        name: String,
    },
}

/// What an input is. A client shows a message in the conversation, and a notification as a notice.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash, Serialize, Deserialize)]
#[cfg_attr(test, derive(ts_rs::TS))]
#[serde(rename_all = "snake_case")]
pub enum InputKind {
    /// A message of a person: the text of the user, or a text that a plugin passes on from a person.
    Message,
    /// A notice that no person wrote, for example the end of a job or a request of a hook to go on.
    Notification,
}

/// An accepted input. It holds the blocks that the user saw, and other blocks for the model when they differ. An input
/// has at least one block.
#[derive(Debug, Clone, PartialEq, Serialize)]
#[cfg_attr(test, derive(ts_rs::TS))]
#[serde(rename_all = "camelCase")]
pub struct Input {
    /// Who sent the input.
    source: InputSource,
    /// What the input is.
    kind: InputKind,
    /// The blocks that the user saw.
    content: Vec<Block>,
    /// The blocks that the model reads, only when they differ from the content.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    model_content: Option<Vec<Block>>,
}

impl Input {
    /// Make an input of `source` and `kind`. The user and the model see `content`.
    ///
    /// # Errors
    ///
    /// Returns [`InputError::EmptyContent`] when `content` has no block.
    pub fn new(source: InputSource, kind: InputKind, content: Vec<Block>) -> Result<Input, InputError> {
        if content.is_empty() {
            return Err(InputError::EmptyContent);
        }
        Ok(Input {
            source,
            kind,
            content,
            model_content: None,
        })
    }

    /// Make a notification of the plugin `plugin`. The user sees `display`. The model reads `text` in a
    /// `system_notification` tag that names the plugin.
    pub fn notification(plugin: &str, display: &str, text: &str) -> Input {
        // A text can hold the closing tag, for example in a job log, and that tag would end the notice early.
        let text = text.replace("</system_notification>", "</ system_notification>");
        Input {
            source: InputSource::Plugin {
                name: plugin.to_owned(),
            },
            kind: InputKind::Notification,
            content: vec![Block::user_text(display)],
            model_content: Some(vec![Block::user_text(format!(
                "<system_notification plugin=\"{plugin}\">{text}</system_notification>"
            ))]),
        }
    }

    /// Give the model `model_content` in place of the content. The user still sees the content. The input does not
    /// keep model content that equals the content.
    ///
    /// # Errors
    ///
    /// Returns [`InputError::EmptyModelContent`] when `model_content` has no block.
    pub fn with_model_content(self, model_content: Vec<Block>) -> Result<Input, InputError> {
        if model_content.is_empty() {
            return Err(InputError::EmptyModelContent);
        }
        let model_content = (model_content != self.content).then_some(model_content);
        Ok(Input { model_content, ..self })
    }

    /// Who sent the input.
    pub fn source(&self) -> &InputSource {
        &self.source
    }

    /// What the input is.
    pub fn kind(&self) -> InputKind {
        self.kind
    }

    /// The blocks that the user saw.
    pub fn content(&self) -> &[Block] {
        &self.content
    }

    /// The blocks that the model reads.
    pub fn model_content(&self) -> &[Block] {
        self.model_content.as_deref().unwrap_or(&self.content)
    }
}

// A read applies the rules of the constructors, so a saved or received input is valid too.
impl<'de> Deserialize<'de> for Input {
    fn deserialize<D: Deserializer<'de>>(deserializer: D) -> Result<Self, D::Error> {
        #[derive(Deserialize)]
        #[serde(rename_all = "camelCase")]
        struct Fields {
            source: InputSource,
            kind: InputKind,
            content: Vec<Block>,
            #[serde(default)]
            model_content: Option<Vec<Block>>,
        }

        let fields = Fields::deserialize(deserializer)?;
        let input = Input::new(fields.source, fields.kind, fields.content);
        match fields.model_content {
            Some(model_content) => input.and_then(|input| input.with_model_content(model_content)),
            None => input,
        }
        .map_err(serde::de::Error::custom)
    }
}

/// Why an input is not valid.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum InputError {
    /// The content has no block.
    EmptyContent,
    /// The model content has no block.
    EmptyModelContent,
}

impl fmt::Display for InputError {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.write_str(match self {
            Self::EmptyContent => "the input has no content",
            Self::EmptyModelContent => "the model content of the input has no block",
        })
    }
}

impl std::error::Error for InputError {}

/// An input that no commit consumed.
#[derive(Debug, Clone, PartialEq)]
pub struct PendingInput {
    /// The id that `Store::accept_input` of `yuke-agent` gave.
    pub id: InputId,
    /// The input.
    pub input: Input,
}

impl PendingInput {
    /// Split the input into its consumed record and the blocks that the model reads.
    pub fn into_consumed(self) -> (ConsumedInput, Vec<Block>) {
        let Input {
            source,
            kind,
            content,
            model_content,
        } = self.input;
        let (display_content, blocks) = match model_content {
            Some(model_content) => (Some(content), model_content),
            None => (None, content),
        };
        let consumed = ConsumedInput {
            id: self.id,
            source,
            kind,
            display_content,
            block_count: blocks.len(),
        };
        (consumed, blocks)
    }
}

/// An input that a commit consumed. The commit starts with the model blocks of its consumed inputs, in input order.
/// This input has the next `blockCount` blocks.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[cfg_attr(test, derive(ts_rs::TS))]
#[serde(rename_all = "camelCase")]
pub struct ConsumedInput {
    /// The id that `Store::accept_input` of `yuke-agent` gave.
    pub id: InputId,
    /// Who sent the input.
    pub source: InputSource,
    /// What the input is.
    pub kind: InputKind,
    /// The blocks that the user saw, only when they differ from the blocks that the model read.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub display_content: Option<Vec<Block>>,
    /// The number of blocks of the commit that the model read for this input.
    pub block_count: usize,
}
