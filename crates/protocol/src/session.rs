//! The settings of a session.

use std::fmt;
use std::ops::Deref;
use std::path::PathBuf;

use serde::{Deserialize, Serialize};

/// The current choice of a session: the model, the request settings, and the working folder. It holds no credential
/// and no route.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[cfg_attr(test, derive(ts_rs::TS))]
#[serde(rename_all = "camelCase")]
pub struct SessionSettings {
    /// The model of the next turn.
    pub model: ModelReference,
    /// The request settings of the next turn.
    pub settings: yuke_ai::RequestSettings,
    /// The folder that the tools of the session work in.
    pub cwd: PathBuf,
}

/// A model of a provider, by the ids of the config.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[cfg_attr(test, derive(ts_rs::TS))]
#[serde(rename_all = "camelCase")]
pub struct ModelReference {
    /// The id of the provider.
    pub provider: String,
    /// The id of the model at the provider.
    pub model: String,
}

/// A non-empty session title with normalized whitespace and at most 200 Unicode scalar values.
#[derive(Debug, Clone, PartialEq, Eq, Hash, Serialize)]
#[cfg_attr(test, derive(ts_rs::TS))]
#[serde(transparent)]
pub struct SessionTitle(#[cfg_attr(test, ts(type = "string"))] String);

impl SessionTitle {
    /// The maximum number of Unicode scalar values in a title.
    pub const MAX_CHARACTERS: usize = 200;

    /// Normalize and validate an explicit title.
    ///
    /// # Errors
    ///
    /// Returns [`InvalidSessionTitle`] when the normalized title is empty or exceeds 200 Unicode scalar values.
    pub fn new(text: &str) -> Result<Self, InvalidSessionTitle> {
        let text = normalize_title(text);
        if text.is_empty() || text.chars().count() > Self::MAX_CHARACTERS {
            return Err(InvalidSessionTitle);
        }
        Ok(Self(text))
    }

    /// Make a title from message text. Limit it to 200 Unicode scalar values.
    pub fn from_text(text: &str) -> Option<Self> {
        let text = normalize_title(text);
        let mut text: String = text.chars().take(Self::MAX_CHARACTERS).collect();
        text.truncate(text.trim_end().len());
        (!text.is_empty()).then_some(Self(text))
    }

    /// The normalized title text.
    pub fn as_str(&self) -> &str {
        &self.0
    }
}

impl<'de> Deserialize<'de> for SessionTitle {
    fn deserialize<D: serde::Deserializer<'de>>(deserializer: D) -> Result<Self, D::Error> {
        Self::new(<String as Deserialize>::deserialize(deserializer)?.as_str()).map_err(serde::de::Error::custom)
    }
}

impl Deref for SessionTitle {
    type Target = str;

    fn deref(&self) -> &Self::Target {
        self.as_str()
    }
}

impl fmt::Display for SessionTitle {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.write_str(self.as_str())
    }
}

/// The title is empty or too long.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct InvalidSessionTitle;

impl fmt::Display for InvalidSessionTitle {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.write_str("a session title must contain 1 to 200 characters")
    }
}

impl std::error::Error for InvalidSessionTitle {}

fn normalize_title(text: &str) -> String {
    text.split_whitespace().collect::<Vec<_>>().join(" ")
}

/// The saved facts of a session, as `session/list` and `session/get` give them.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[cfg_attr(test, derive(ts_rs::TS), ts(optional_fields))]
#[serde(rename_all = "camelCase")]
pub struct SessionSummary {
    /// The session.
    pub session_id: crate::SessionId,
    /// The model of the newest settings.
    pub model: ModelReference,
    /// The working folder of the newest settings.
    pub cwd: PathBuf,
    /// The display title from a message, an explicit rename, or a fork of a titled session.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub title: Option<SessionTitle>,
    /// The creation time, in milliseconds since the Unix epoch.
    pub created_at: u64,
    /// The time of the newest event, in milliseconds since the Unix epoch. A fork starts at its creation time.
    pub updated_at: u64,
    /// The source of a fork. The source can be gone.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub fork_of: Option<crate::SessionId>,
    /// The parent session. A removal of the parent removes this session.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub parent: Option<crate::SessionId>,
}

/// A saved session with its facts and its state at the moment of the answer.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[cfg_attr(test, derive(ts_rs::TS))]
#[serde(rename_all = "camelCase")]
pub struct SessionRow {
    /// The saved facts. JSON holds them in the row itself, next to `state`.
    #[serde(flatten)]
    pub session: SessionSummary,
    /// Whether the session is open in this server, and whether a turn runs in it.
    pub state: crate::SessionState,
}

#[cfg(test)]
mod tests {
    use super::{InvalidSessionTitle, SessionTitle};

    #[test]
    fn a_session_title_normalizes_whitespace_and_counts_unicode_characters() {
        let title = SessionTitle::new("  hello\t世界  title ").unwrap();

        assert_eq!(title.as_str(), "hello 世界 title");
        assert_eq!(serde_json::to_value(&title).unwrap(), "hello 世界 title");
    }

    #[test]
    fn an_explicit_session_title_rejects_empty_or_long_text() {
        assert_eq!(SessionTitle::new(" \n\t"), Err(InvalidSessionTitle));
        assert_eq!(SessionTitle::new(&"界".repeat(201)), Err(InvalidSessionTitle));
        let error = serde_json::from_value::<SessionTitle>(serde_json::json!(" ")).unwrap_err();
        assert_eq!(error.to_string(), "a session title must contain 1 to 200 characters");
        assert_eq!(SessionTitle::new(&"界".repeat(200)).unwrap().as_str(), "界".repeat(200));
    }

    #[test]
    fn a_truncated_title_has_no_trailing_whitespace_and_round_trips_unchanged() {
        let title = SessionTitle::from_text(&format!("{} end", "é".repeat(199))).unwrap();
        assert_eq!(title.as_str(), "é".repeat(199));
        let saved = serde_json::to_string(&title).unwrap();
        assert_eq!(serde_json::from_str::<SessionTitle>(&saved).unwrap(), title);
    }

    #[test]
    fn message_text_makes_an_optional_truncated_session_title() {
        assert_eq!(SessionTitle::from_text(" \n\t"), None);
        assert_eq!(
            SessionTitle::from_text(&format!("  {}  ", "界".repeat(201)))
                .unwrap()
                .as_str(),
            "界".repeat(200)
        );
    }
}
