//! The observable behavior of the shared assertions and test folders.

use yuke_testing::{assert_in_order, folder};

#[test]
fn ordered_strings_can_follow_earlier_unrelated_occurrences() {
    assert_in_order(r#"["b","a","b"]"#, &["a", "b"]);
}

#[test]
fn repeated_strings_require_separate_occurrences() {
    let accepted = [r#"["a","a"]"#, r#"["a"]"#]
        .map(|body| std::panic::catch_unwind(|| assert_in_order(body, &["a", "a"])).is_ok());
    assert_eq!(accepted, [true, false]);
}

#[test]
fn json_string_escapes_are_matched() {
    assert_in_order(
        r#"["a\"b","c\\d","line\nbreak","雪"]"#,
        &["a\"b", "c\\d", "line\nbreak", "雪"],
    );
}

#[test]
#[should_panic(expected = "expected JSON string at index 1: \"b\"")]
fn reversed_strings_are_rejected() {
    assert_in_order(r#"["b","a"]"#, &["a", "b"]);
}

#[test]
fn missing_strings_report_the_expected_string_index_and_body() {
    let failure = std::panic::catch_unwind(|| assert_in_order(r#"["a"]"#, &["a", "missing"])).unwrap_err();
    assert_eq!(
        failure.downcast_ref::<String>().unwrap(),
        "expected JSON string at index 1: \"missing\"\nbody: [\"a\"]"
    );
}

#[test]
fn a_folder_call_removes_old_contents_and_keeps_the_path() {
    let first = folder("testing", "a_folder_call_removes_old_contents_and_keeps_the_path");
    std::fs::create_dir(first.join("nested")).unwrap();
    std::fs::write(first.join("nested/old.txt"), "old contents").unwrap();
    assert_eq!(
        std::fs::read_to_string(first.join("nested/old.txt")).unwrap(),
        "old contents"
    );

    let second = folder("testing", "a_folder_call_removes_old_contents_and_keeps_the_path");

    assert_eq!(second, first);
    assert_eq!(std::fs::read_dir(&second).unwrap().count(), 0);
    std::fs::remove_dir_all(second).unwrap();
}

#[test]
fn folder_paths_are_absolute_and_canonical() {
    let path = folder("testing", "folder_paths_are_absolute_and_canonical");

    assert!(path.is_absolute());
    assert_eq!(path, path.canonicalize().unwrap());
    std::fs::write(path.join("created.txt"), "created").unwrap();
    assert_eq!(std::fs::read_to_string(path.join("created.txt")).unwrap(), "created");
    std::fs::remove_dir_all(path).unwrap();
}

#[test]
fn folder_groups_and_names_keep_contents_separate() {
    let first = folder("testing", "folder_groups_and_names_keep_contents_separate");
    std::fs::write(first.join("value.txt"), "first").unwrap();
    let other_name = folder("testing", "folder_groups_and_names_keep_contents_separate_other");
    std::fs::write(other_name.join("value.txt"), "other name").unwrap();
    let other_group = folder("testing-other", "folder_groups_and_names_keep_contents_separate");
    std::fs::write(other_group.join("value.txt"), "other group").unwrap();

    let contents =
        [&first, &other_name, &other_group].map(|path| std::fs::read_to_string(path.join("value.txt")).unwrap());
    assert_eq!(contents, ["first", "other name", "other group"]);
    for path in [first, other_name, other_group] {
        std::fs::remove_dir_all(path).unwrap();
    }
}
