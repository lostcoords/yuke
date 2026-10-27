//! The TypeScript tests of `crates/js/tests`: each test of a `*.test.ts` file runs in its own runtime through
//! `yuke:test`.

use std::fmt::Write as _;
use std::path::{Path, PathBuf};
use std::sync::Arc;

use super::{folder, options};
use crate::{Options, Processes, Report, Runtime, TestFileError, TestOutcome, TestStatus, run_test_file};

/// Run each test of `file` in its own bare runtime, in folders below `folder`. The runtimes share the TypeScript cache
/// `cache`.
async fn run_file(file: &Path, folder: &Path, cache: &Path) -> Result<Vec<TestOutcome>, TestFileError> {
    run_test_file(file.to_str().unwrap(), folder, async |place: &Path| {
        let options = Options {
            cache: cache.to_owned(),
            internal_imports: true,
            ..options(place, Arc::new(Processes::new(place.join("processes"))))
        };
        Ok(Runtime::start(options).await?)
    })
    .await
}

/// Add each `*.test.ts` file below `root` to `files`.
fn collect(root: &Path, files: &mut Vec<PathBuf>) {
    for entry in std::fs::read_dir(root).unwrap() {
        let path = entry.unwrap().path();
        if path.is_dir() {
            collect(&path, files);
        } else if path.to_string_lossy().ends_with(".test.ts") {
            files.push(path);
        }
    }
}

#[tokio::test]
async fn the_typescript_tests_pass() {
    let root = Path::new(env!("CARGO_MANIFEST_DIR")).join("tests");
    let mut files = Vec::new();
    collect(&root, &mut files);
    files.sort();
    assert!(!files.is_empty(), "no test file below {}", root.display());

    let cache = folder("typescript/cache");
    let mut failures = String::new();
    for file in files {
        let relative = file.strip_prefix(&root).unwrap().to_string_lossy().into_owned();
        match run_file(&file, &folder(&format!("typescript/{relative}")), &cache).await {
            Err(error) => writeln!(failures, "{relative}: {error}").unwrap(),
            Ok(outcomes) => {
                for outcome in outcomes {
                    let failure = match outcome.status {
                        TestStatus::Passed => continue,
                        TestStatus::Failed(error) => error.to_string(),
                        TestStatus::TimedOut => "timed out".to_owned(),
                    };
                    writeln!(
                        failures,
                        "{relative}: {}\n  {}",
                        outcome.name,
                        failure.replace('\n', "\n  ")
                    )
                    .unwrap();
                    for report in outcome.reports {
                        let line = match report {
                            Report::Console { text, .. } => text,
                            Report::Notice(notice) => notice.message,
                            Report::Fault(error) => error.to_string(),
                            Report::Event(event) => event.event,
                        };
                        writeln!(failures, "  | {}", line.replace('\n', "\n  | ")).unwrap();
                    }
                }
            }
        }
    }
    assert!(failures.is_empty(), "\n{failures}");
}

/// Run the test file `file` with `source` in a new folder for the test `name`.
async fn ran(name: &str, source: &str) -> Result<Vec<TestOutcome>, TestFileError> {
    let place = folder(&format!("runner/{name}"));
    let file = place.join("a.test.ts");
    std::fs::write(&file, source).unwrap();
    run_file(&file, &place.join("tests"), &place.join("cache")).await
}

/// The name and a short form of the status of each outcome.
fn statuses(outcomes: &[TestOutcome]) -> Vec<(String, String)> {
    outcomes
        .iter()
        .map(|outcome| {
            let status = match &outcome.status {
                TestStatus::Passed => "passed".to_owned(),
                TestStatus::Failed(error) => format!("failed: {}", error.message),
                TestStatus::TimedOut => "timed out".to_owned(),
            };
            (outcome.name.clone(), status)
        })
        .collect()
}

// The rejection settles after the test ends, so only the fence before the drain gives it to its own test.
#[tokio::test]
async fn a_failure_and_a_stray_rejection_fail_only_their_own_tests() {
    let outcomes = ran(
        "a_failure_and_a_stray_rejection_fail_only_their_own_tests",
        r#"import { equal, test } from "yuke:test";
           test("first", () => equal(1, 2));
           test("second", () => { void Promise.reject(new Error("nobody awaits it")); });
           test("third", () => {});"#,
    )
    .await
    .unwrap();

    assert_eq!(
        statuses(&outcomes),
        [
            (
                "first".to_owned(),
                "failed: equal: at the value: expected 2, got 1".to_owned()
            ),
            ("second".to_owned(), "failed: nobody awaits it".to_owned()),
            ("third".to_owned(), "passed".to_owned()),
        ]
    );
    assert!(outcomes[0].reports.is_empty(), "{:?}", outcomes[0].reports);
}

#[tokio::test]
async fn a_test_past_the_time_limit_stops_its_runtime_and_the_later_tests_still_run() {
    let outcomes = ran(
        "a_test_past_the_time_limit_stops_its_runtime_and_the_later_tests_still_run",
        r#"import { test } from "yuke:test";
           test("first", () => {});
           test("loops", () => { for (;;) {} });
           test("later", () => {});"#,
    )
    .await
    .unwrap();

    assert_eq!(
        statuses(&outcomes),
        [
            ("first".to_owned(), "passed".to_owned()),
            ("loops".to_owned(), "timed out".to_owned()),
            ("later".to_owned(), "passed".to_owned()),
        ]
    );
}

#[tokio::test]
async fn a_file_that_fails_before_its_tests_runs_no_test() {
    let thrown = ran(
        "a_file_that_fails_before_its_tests_runs_no_test/thrown",
        r#"import { test } from "yuke:test"; test("never", () => {}); throw new Error("broken");"#,
    )
    .await
    .unwrap_err();
    let fault = ran(
        "a_file_that_fails_before_its_tests_runs_no_test/fault",
        r#"import { test } from "yuke:test"; test("never", () => {}); void Promise.reject(new Error("stray"));"#,
    )
    .await
    .unwrap_err();
    let empty = ran(
        "a_file_that_fails_before_its_tests_runs_no_test/empty",
        r#"import "yuke:test";"#,
    )
    .await
    .unwrap_err();
    let hung = ran(
        "a_file_that_fails_before_its_tests_runs_no_test/hung",
        r#"import { test } from "yuke:test"; test("never", () => {}); await new Promise(() => {});"#,
    )
    .await
    .unwrap_err();

    assert_eq!(
        [thrown, fault, empty, hung].map(|error| error.to_string().lines().next().unwrap().to_owned()),
        [
            "Error: broken",
            "the import made a fault: Error: stray",
            "the file registers no test",
            "the import ran longer than 5 seconds",
        ]
    );
}

// The second runtime registers other tests, so the name guard fails the test that it no longer has.
#[tokio::test]
async fn a_test_that_a_later_import_does_not_register_fails() {
    let outcomes = ran(
        "a_test_that_a_later_import_does_not_register_fails",
        r#"import { folder, test } from "yuke:test";
           if (folder().includes("/0/")) test("first", () => {});
           test("second", () => {});"#,
    )
    .await
    .unwrap();

    assert_eq!(
        statuses(&outcomes),
        [
            ("first".to_owned(), "passed".to_owned()),
            (
                "second".to_owned(),
                "failed: the file registers no test \"second\" at position 1 in this runtime".to_owned()
            ),
        ]
    );
}

#[tokio::test]
async fn a_run_into_a_used_folder_fails_before_its_tests() {
    let place = folder("runner/a_run_into_a_used_folder_fails_before_its_tests");
    let file = place.join("a.test.ts");
    std::fs::write(&file, r#"import { test } from "yuke:test"; test("only", () => {});"#).unwrap();

    let first = run_file(&file, &place.join("tests"), &place.join("cache")).await;
    let second = run_file(&file, &place.join("tests"), &place.join("cache")).await;

    assert_eq!(statuses(&first.unwrap()), [("only".to_owned(), "passed".to_owned())]);
    assert!(matches!(second, Err(TestFileError::Runtime(_))), "{second:?}");
}
