use super::*;

#[test]
fn graphemes_take_the_cells_that_terminals_draw() {
    let cases = [
        ("a", 1),
        ("中", 2),
        // A base letter and a combining acute accent.
        ("a\u{301}", 1),
        ("\u{5b0}", 0),
        ("\u{200b}", 0),
        ("\u{200d}", 0),
        ("👩\u{200d}🚀", 2),
        ("👋🏿", 2),
        ("\u{2764}\u{fe0f}", 2),
        ("\u{2764}\u{fe0e}", 1),
        ("1\u{fe0f}\u{20e3}", 2),
        ("🇺🇸", 2),
        // A ZWJ sequence that is no emoji sums to 4 cells. The grid caps a grapheme at 2, as libvaxis does.
        ("😀\u{200d}😀", 2),
        ("क्क्क", 2),
        ("\t", 0),
        ("\u{1b}", 0),
    ];
    for (grapheme, cells) in cases {
        assert_eq!(grapheme_width(grapheme), cells, "{grapheme:?}");
    }
}
