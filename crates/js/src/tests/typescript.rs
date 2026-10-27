//! The TypeScript tests of `crates/js/tests`: each `*.test.ts` file runs in its own runtime through `yuke:test`.

use std::fmt::Write as _;
use std::path::{Path, PathBuf};
use std::sync::Arc;

use super::{folder, options};
use crate::{Options, Processes, Report, TestStatus, run_test_file};

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

    let mut failures = String::new();
    for file in files {
        let relative = file.strip_prefix(&root).unwrap().to_string_lossy().into_owned();
        let place = folder(&format!("typescript/{relative}"));
        let scratch = place.join("scratch");
        std::fs::create_dir_all(&scratch).unwrap();
        let options = Options {
            internal_imports: true,
            ..options(&place, Arc::new(Processes::new(place.join("processes"))))
        };
        match run_test_file(options, file.to_str().unwrap(), &scratch).await {
            Err(error) => writeln!(failures, "{relative}: {error}").unwrap(),
            Ok(outcomes) => {
                for outcome in outcomes {
                    let failure = match outcome.status {
                        TestStatus::Passed => continue,
                        TestStatus::Failed(error) => error.to_string(),
                        TestStatus::TimedOut => "timed out".to_owned(),
                        TestStatus::NotRun => "not run: an earlier test timed out".to_owned(),
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
async fn ran(name: &str, source: &str) -> Result<Vec<crate::TestOutcome>, crate::TestFileError> {
    let place = folder(&format!("runner/{name}"));
    let scratch = place.join("scratch");
    std::fs::create_dir_all(&scratch).unwrap();
    let file = place.join("a.test.ts");
    std::fs::write(&file, source).unwrap();
    let options = Options {
        internal_imports: true,
        ..options(&place, Arc::new(Processes::new(place.join("processes"))))
    };
    run_test_file(options, file.to_str().unwrap(), &scratch).await
}

/// The name and a short form of the status of each outcome.
fn statuses(outcomes: &[crate::TestOutcome]) -> Vec<(String, String)> {
    outcomes
        .iter()
        .map(|outcome| {
            let status = match &outcome.status {
                TestStatus::Passed => "passed".to_owned(),
                TestStatus::Failed(error) => format!("failed: {}", error.message),
                TestStatus::TimedOut => "timed out".to_owned(),
                TestStatus::NotRun => "not run".to_owned(),
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
async fn a_test_past_the_time_limit_stops_its_file_and_the_later_tests_do_not_run() {
    let outcomes = ran(
        "a_test_past_the_time_limit_stops_its_file_and_the_later_tests_do_not_run",
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
            ("later".to_owned(), "not run".to_owned()),
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
