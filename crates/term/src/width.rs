//! The width of text in terminal cells. The grid uses this rule, and a measure of text must use it too, so text
//! never drifts from the cells that it fills.

use unicode_width::UnicodeWidthStr;

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
