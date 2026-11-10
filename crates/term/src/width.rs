//! The width of text in terminal cells. The grid uses this rule, and a measure of text must use it too, so text
//! never drifts from the cells that it fills.

use unicode_segmentation::UnicodeSegmentation;
use unicode_width::UnicodeWidthStr;

/// Each grapheme of `text` with its cells, as the grid places them.
pub fn graphemes(text: &str) -> impl Iterator<Item = (&str, usize)> {
    if text.is_ascii() {
        Graphemes::Ascii(text)
    } else {
        Graphemes::Unicode(text.graphemes(true))
    }
}

/// The graphemes of a text. Most terminal text is ASCII, where each byte is a grapheme except "\r\n", so ASCII text
/// skips the Unicode segmentation and width tables.
enum Graphemes<'a> {
    /// The text that the iterator has not given yet.
    Ascii(&'a str),
    Unicode(unicode_segmentation::Graphemes<'a>),
}

impl<'a> Iterator for Graphemes<'a> {
    type Item = (&'a str, usize);

    fn next(&mut self) -> Option<Self::Item> {
        match self {
            Self::Ascii(rest) => {
                let length = if rest.starts_with("\r\n") { 2 } else { 1 };
                let (grapheme, after) = rest.split_at_checked(length)?;
                *rest = after;
                Some((
                    grapheme,
                    usize::from(!grapheme.starts_with(|c: char| c.is_ascii_control())),
                ))
            }
            Self::Unicode(inner) => inner.next().map(|grapheme| (grapheme, grapheme_width(grapheme))),
        }
    }
}

/// The cells of one grapheme: 0, 1, or 2. A control character gives 0, so the grid never stores one. An emoji
/// sequence, a flag, and an emoji presentation give 2; a text presentation of a narrow base gives 1.
pub(crate) fn grapheme_width(grapheme: &str) -> usize {
    if grapheme.chars().any(char::is_control) {
        return 0;
    }
    grapheme.width().min(2)
}

#[cfg(test)]
mod tests;
