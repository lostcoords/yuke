use super::*;

fn rows(text: &str, width: usize) -> Vec<i32> {
    wrap(text, Some(width), 0, 0).rows
}

#[test]
fn wrap_breaks_after_the_last_space_and_keeps_utf16_offsets() {
    // These cases come from the Zig yuke.
    assert_eq!(rows("", 1), [0, 0, 0]);
    assert_eq!(rows("hello world", 5), [0, 6, 1, 6, 11, 0]);
    assert_eq!(rows("  keep   spaces", 7), [0, 9, 1, 9, 15, 0]);
    assert_eq!(rows("a\n\nb", 2), [0, 1, 0, 2, 2, 0, 3, 4, 0]);
    assert_eq!(rows("世界e\u{301}", 2), [0, 1, 1, 1, 2, 1, 2, 4, 0]);
    assert_eq!(rows("👩\u{200d}💻x", 2), [0, 5, 1, 5, 6, 0]);
}

#[test]
fn wrap_without_a_width_gives_one_row() {
    assert_eq!(wrap("a\nb", None, 0, 0).rows, [0, 3, 0]);
}

#[test]
fn wrap_keeps_the_head_and_the_tail_and_says_that_it_dropped_rows() {
    let text = format!("first\n{}last", "middle\n".repeat(1000));
    let length = small(text.len());
    let prefix = wrap(&text, Some(20), 2, 0);
    assert_eq!(
        prefix,
        Wrapped {
            rows: vec![0, 5, 0, 6, 12, 0],
            omitted: true
        }
    );
    let ends = wrap(&text, Some(20), 1, 1);
    assert_eq!(
        ends,
        Wrapped {
            rows: vec![0, 5, 0, length - 4, length, 0],
            omitted: true
        }
    );
    // Two tail rows come back in their order.
    let tail = wrap("a\nb\nc\nd\ne", Some(5), 1, 2);
    assert_eq!(
        tail,
        Wrapped {
            rows: vec![0, 1, 0, 6, 7, 0, 8, 9, 0],
            omitted: true
        }
    );
    // A head longer than the text keeps every row.
    assert_eq!(
        wrap("x", Some(80), 100, 0),
        Wrapped {
            rows: vec![0, 1, 0],
            omitted: false
        }
    );
    assert_eq!(
        wrap("x", Some(80), 100, 5),
        Wrapped {
            rows: vec![0, 1, 0],
            omitted: false
        }
    );
    let all = wrap("a\nb", Some(5), 1, 1);
    assert_eq!(
        all,
        Wrapped {
            rows: vec![0, 1, 0, 2, 3, 0],
            omitted: false
        }
    );
}

#[test]
fn fit_and_step_count_utf16_units_of_whole_graphemes() {
    let text = "a中e\u{301}\u{1d11e}";
    assert_eq!(fit(text, 0), 0);
    assert_eq!(fit(text, 2), 1);
    assert_eq!(fit(text, 3), 2);
    assert_eq!(fit(text, 4), 4);
    assert_eq!(fit(text, 9), 6);
    assert_eq!(step(text, 4, true), 2);
    assert_eq!(step(text, 2, false), 4);
    assert_eq!(step(text, 6, false), 6);
    assert_eq!(step(text, 0, true), 0);
}

#[test]
fn a_copy_is_osc_52_and_also_a_tmux_passthrough_in_tmux() {
    assert_eq!(copy_bytes("hi", false), b"\x1b]52;c;aGk=\x07");
    assert_eq!(
        copy_bytes("hi", true),
        b"\x1b]52;c;aGk=\x07\x1bPtmux;\x1b\x1b]52;c;aGk=\x07\x1b\\"
    );
}

#[test]
fn key_names_follow_the_zig_yuke() {
    assert_eq!(code_name(Code::Escape), "esc");
    assert_eq!(code_name(Code::PageDown), "page_down");
    assert_eq!(code_name(Code::F(1)), "f1");
    assert_eq!(code_name(Code::F(35)), "f35");
    assert_eq!(code_name(Code::F(0)), "unknown");
    assert_eq!(code_name(Code::CapsLock), "unknown");
}
