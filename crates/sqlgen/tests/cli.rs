//! The command writes the generated file, reports when it is up to date, and checks it without a write.
#![expect(clippy::unwrap_used, reason = "a test fails by panicking")]

use std::path::{Path, PathBuf};
use std::process::{Command, Output};

/// A crate folder with the migrations and the queries of the fixture, and an empty `src`.
fn crate_folder(test: &str) -> PathBuf {
    // Two runs of the tests at one time get their own folders.
    let folder = std::env::temp_dir().join(format!("yuke-sqlgen-cli-{test}-{}", std::process::id()));
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

// A format step can fail with a cause, and the error keeps that cause.
#[test]
fn a_rustfmt_that_does_not_start_names_its_cause() {
    let folder = crate_folder("no-rustfmt");

    let output = Command::new(env!("CARGO_BIN_EXE_yuke-sqlgen"))
        .args(["--crate", folder.to_str().unwrap()])
        .env("RUSTFMT", folder.join("missing-rustfmt"))
        .output()
        .unwrap();

    assert_eq!(output.status.code(), Some(1));
    let stderr = text(&output.stderr);
    assert!(stderr.contains("rustfmt does not start: "), "{stderr}");
    assert!(stderr.contains("No such file or directory"), "{stderr}");
    std::fs::remove_dir_all(&folder).unwrap();
}

#[test]
fn help_prints_usage_and_exits_successfully() {
    let output = run(&["--help"]);

    assert!(output.status.success());
    let stdout = text(&output.stdout);
    assert!(stdout.contains("Usage: cargo run -p yuke-sqlgen"), "{stdout}");
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
fn generation_creates_updates_and_checks_output() {
    let folder = crate_folder("lifecycle");
    let crate_argument = folder.to_str().unwrap();
    let output = folder.join("src/queries.rs");

    let created = run(&["--crate", crate_argument]);
    assert!(created.status.success(), "{}", text(&created.stderr));
    assert!(
        text(&created.stdout).starts_with("updated "),
        "{}",
        text(&created.stdout)
    );
    let written = std::fs::read_to_string(&output).unwrap();

    let repeated = run(&["--crate", crate_argument]);
    assert!(repeated.status.success(), "{}", text(&repeated.stderr));
    let stdout = text(&repeated.stdout);
    assert!(stdout.contains("is up to date\nquery files: 1\nqueries: 9"), "{stdout}");
    assert_eq!(std::fs::read_to_string(&output).unwrap(), written);

    std::fs::write(&output, "stale").unwrap();
    let stale = run(&["--check", "--crate", crate_argument]);
    assert_eq!(stale.status.code(), Some(1));
    let stderr = text(&stale.stderr);
    assert!(stderr.contains("is out of date"), "{stderr}");
    assert!(
        stderr.contains(&format!("cargo run -p yuke-sqlgen -- --crate {crate_argument}")),
        "{stderr}"
    );
    assert_eq!(std::fs::read_to_string(&output).unwrap(), "stale");

    let updated = run(&["--crate", crate_argument]);
    assert!(updated.status.success(), "{}", text(&updated.stderr));
    let current = run(&["--check", "--crate", crate_argument]);
    assert!(current.status.success(), "{}", text(&current.stderr));
    std::fs::remove_dir_all(&folder).unwrap();
}

#[test]
fn a_failed_migration_reports_its_file_and_the_sqlite_reason() {
    let folder = crate_folder("failed_migration");
    std::fs::write(folder.join("migrations/0003_broken.sql"), "CREATE TABLE;").unwrap();

    let output = run(&["--crate", folder.to_str().unwrap()]);

    assert_eq!(output.status.code(), Some(1));
    let stderr = text(&output.stderr);
    assert!(stderr.contains("0003_broken.sql: the migration failed: "), "{stderr}");
    assert!(stderr.contains("syntax error"), "{stderr}");
    std::fs::remove_dir_all(&folder).unwrap();
}
