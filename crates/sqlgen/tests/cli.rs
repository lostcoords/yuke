//! The command writes the generated file, reports when it is up to date, and checks it without a write.
#![expect(clippy::unwrap_used, reason = "a test fails by panicking")]

use std::path::{Path, PathBuf};
use std::process::{Command, Output};

/// A crate folder with the migrations and the queries of the fixture, and an empty `src`.
fn crate_folder(test: &str) -> PathBuf {
    let folder = std::env::temp_dir().join(format!("yuke-sqlgen-cli-{test}"));
    // A panic in an earlier run can leave the folder, so its old files go first.
    match std::fs::remove_dir_all(&folder) {
        Ok(()) => {}
        Err(error) => assert_eq!(error.kind(), std::io::ErrorKind::NotFound, "{error}"),
    }
    let fixture = Path::new(env!("CARGO_MANIFEST_DIR")).join("tests/fixture");
    for part in ["migrations", "queries"] {
        std::fs::create_dir_all(folder.join(part)).unwrap();
        for entry in std::fs::read_dir(fixture.join(part)).unwrap() {
            let path = entry.unwrap().path();
            std::fs::copy(&path, folder.join(part).join(path.file_name().unwrap())).unwrap();
        }
    }
    std::fs::create_dir_all(folder.join("src")).unwrap();
    folder
}

fn run(arguments: &[&str]) -> Output {
    Command::new(env!("CARGO_BIN_EXE_yuke-sqlgen"))
        .args(arguments)
        .output()
        .unwrap()
}

fn text(bytes: &[u8]) -> String {
    String::from_utf8_lossy(bytes).into_owned()
}

#[test]
fn help_shows_the_options_and_examples() {
    let output = run(&["--help"]);

    assert!(output.status.success());
    let stdout = text(&output.stdout);
    for part in [
        "Usage:",
        "--check",
        "--crate <dir>",
        "Examples:",
        "cargo run -p yuke-sqlgen -- --check",
    ] {
        assert!(stdout.contains(part), "{stdout}");
    }
}

#[test]
fn an_unknown_argument_exits_with_status_2_and_the_usage() {
    let output = run(&["--bogus"]);

    assert_eq!(output.status.code(), Some(2));
    let stderr = text(&output.stderr);
    assert!(stderr.contains("unknown argument `--bogus`"), "{stderr}");
    assert!(stderr.contains("Usage: cargo run -p yuke-sqlgen"), "{stderr}");
}

#[test]
fn a_second_run_reports_the_file_up_to_date() {
    let folder = crate_folder("twice");
    let crate_argument = folder.to_str().unwrap();

    let first = run(&["--crate", crate_argument]);
    let written = std::fs::read_to_string(folder.join("src/queries.rs")).unwrap();
    let second = run(&["--crate", crate_argument]);

    assert!(first.status.success(), "{}", text(&first.stderr));
    assert!(text(&first.stdout).starts_with("updated "), "{}", text(&first.stdout));
    assert!(second.status.success(), "{}", text(&second.stderr));
    let stdout = text(&second.stdout);
    assert!(stdout.contains("is up to date\nquery files: 1\nqueries: 8"), "{stdout}");
    assert_eq!(std::fs::read_to_string(folder.join("src/queries.rs")).unwrap(), written);
    std::fs::remove_dir_all(&folder).unwrap();
}

#[test]
fn check_writes_nothing_and_fails_when_the_file_is_out_of_date() {
    let folder = crate_folder("check");
    let crate_argument = folder.to_str().unwrap();
    std::fs::write(folder.join("src/queries.rs"), "stale").unwrap();

    let stale = run(&["--check", "--crate", crate_argument]);
    let content = std::fs::read_to_string(folder.join("src/queries.rs")).unwrap();
    let updated = run(&["--crate", crate_argument]);
    let current = run(&["--check", "--crate", crate_argument]);

    assert_eq!(stale.status.code(), Some(1));
    let stderr = text(&stale.stderr);
    assert!(stderr.contains("is out of date"), "{stderr}");
    assert!(
        stderr.contains(&format!("cargo run -p yuke-sqlgen -- --crate {crate_argument}")),
        "{stderr}"
    );
    assert_eq!(content, "stale");
    assert!(updated.status.success(), "{}", text(&updated.stderr));
    assert!(current.status.success(), "{}", text(&current.stderr));
    std::fs::remove_dir_all(&folder).unwrap();
}
