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
    /// A section `key` with the text `text`.
    pub fn new(key: impl Into<String>, text: impl Into<String>) -> Self {
        Self {
            key: key.into(),
            text: text.into(),
        }
    }
}

/// The text of `sections` in order, with a blank line between two sections. A section with no text adds nothing.
pub fn prompt_text(sections: &[PromptSection]) -> String {
    let texts: Vec<&str> = sections
        .iter()
        .map(|section| section.text.as_str())
        .filter(|text| !text.is_empty())
        .collect();
    texts.join("\n\n")
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn the_text_joins_the_sections_in_order_and_leaves_out_empty_ones() {
        let sections = [
            PromptSection::new("first", ""),
            PromptSection::new("base", "base\n\ntext"),
            PromptSection::new("empty", ""),
            PromptSection::new("environment", "env"),
        ];

        assert_eq!(prompt_text(&sections), "base\n\ntext\n\nenv");
        assert_eq!(prompt_text(&sections[..1]), "");
    }
}
