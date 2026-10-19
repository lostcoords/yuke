//! The system prompt of a session: named sections that each turn joins into one text.

use serde::{Deserialize, Serialize};

/// One named part of the system prompt.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct PromptSection {
    /// The name of the section, such as `base` or `environment`.
    pub key: String,
    /// The text that the model reads.
    pub text: String,
}

impl PromptSection {
    /// The key of a section that the model reads without a tag.
    pub const BASE: &str = "base";

    /// A section `key` with the text `text`.
    pub fn new(key: impl Into<String>, text: impl Into<String>) -> Self {
        Self {
            key: key.into(),
            text: text.into(),
        }
    }
}

/// The text of `sections` in order, with a blank line between two sections. The text of a section goes between
/// `<key>` and `</key>`, except for the key [`PromptSection::BASE`]. A section with no text adds nothing.
pub fn prompt_text(sections: &[PromptSection]) -> String {
    let texts: Vec<String> = sections
        .iter()
        .filter(|section| !section.text.is_empty())
        .map(|PromptSection { key, text }| {
            if key == PromptSection::BASE {
                text.clone()
            } else {
                format!("<{key}>\n{text}\n</{key}>")
            }
        })
        .collect();
    texts.join("\n\n")
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn the_base_is_plain_and_each_other_section_has_the_tag_of_its_key() {
        let sections = [
            PromptSection::new("first", "one"),
            PromptSection::new("base", "base\n\ntext"),
            PromptSection::new("empty", ""),
            PromptSection::new("environment", "env"),
        ];

        assert_eq!(
            prompt_text(&sections),
            "<first>\none\n</first>\n\nbase\n\ntext\n\n<environment>\nenv\n</environment>"
        );
    }

    #[test]
    fn a_section_with_no_text_adds_nothing() {
        assert_eq!(prompt_text(&[PromptSection::new("empty", "")]), "");
        assert_eq!(
            prompt_text(&[PromptSection::new("base", ""), PromptSection::new("environment", "env")]),
            "<environment>\nenv\n</environment>"
        );
    }
}
