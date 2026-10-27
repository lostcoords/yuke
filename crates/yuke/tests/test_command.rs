//! The `yuke test` command: its output and its exit status.

use std::process::Command;

#[test]
fn yuke_test_prints_each_failure_and_the_counts_and_fails_when_a_test_fails() {
    let place = yuke_testing::folder("command", "yuke_test_prints_each_failure");
    std::fs::write(
        place.join("a.test.ts"),
        r#"import { equal, test } from "yuke:test";
           test("passes", () => {});
           test("fails", () => equal(1, 2));"#,
    )
    .unwrap();

    let output = Command::new(env!("CARGO_BIN_EXE_yuke"))
        .arg("test")
        .arg(&place)
        .output()
        .unwrap();

    let stdout = String::from_utf8(output.stdout).unwrap();
    assert_eq!(output.status.code(), Some(1), "{stdout}");
    assert!(stdout.contains("a.test.ts: fails\n  Error: equal: "), "{stdout}");
    assert!(stdout.ends_with("1 passed, 1 failed\n"), "{stdout}");
}

#[test]
fn yuke_test_succeeds_when_each_test_passes() {
    let place = yuke_testing::folder("command", "yuke_test_succeeds_when_each_test_passes");
    std::fs::write(
        place.join("a.test.ts"),
        r#"import { test } from "yuke:test"; test("passes", () => {});"#,
    )
    .unwrap();

    let output = Command::new(env!("CARGO_BIN_EXE_yuke"))
        .arg("test")
        .arg(&place)
        .output()
        .unwrap();

    assert!(output.status.success());
    assert_eq!(String::from_utf8(output.stdout).unwrap(), "1 passed, 0 failed\n");
}
