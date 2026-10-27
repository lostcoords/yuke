//! `yuke test`: run the TypeScript test files of `yuke:test`, each test in its own app with a scripted model.

use std::fmt::Write as _;
use std::path::{Path, PathBuf};

use yuke_js::{Report, TestStatus, run_test_file};

use crate::app::TestPlace;

/// The result of a run of test files.
#[derive(Debug, Default)]
pub(crate) struct Summary {
    pub(crate) passed: usize,
    pub(crate) failed: usize,
    /// The text of each failure, for the user.
    pub(crate) failures: String,
}

/// Each `*.test.ts` file at `paths`: a file as it is, or each such file below a folder, in name order.
///
/// # Errors
///
/// Returns a text for the user when a path cannot be read or names a file that is not a `*.test.ts` file.
pub(crate) fn collect(paths: &[PathBuf]) -> Result<Vec<PathBuf>, String> {
    let mut files = Vec::new();
    for path in paths {
        let path = path
            .canonicalize()
            .map_err(|error| format!("{}: {error}", path.display()))?;
        if path.is_dir() {
            below(&path, &mut files)?;
        } else if path.to_string_lossy().ends_with(".test.ts") {
            files.push(path);
        } else {
            return Err(format!("{}: the file is not a .test.ts file", path.display()));
        }
    }
    files.sort();
    files.dedup();
    Ok(files)
}

/// Add each `*.test.ts` file below `folder` to `files`.
fn below(folder: &Path, files: &mut Vec<PathBuf>) -> Result<(), String> {
    let entries = std::fs::read_dir(folder).map_err(|error| format!("{}: {error}", folder.display()))?;
    for entry in entries {
        let path = entry.map_err(|error| format!("{}: {error}", folder.display()))?.path();
        if path.is_dir() {
            below(&path, files)?;
        } else if path.to_string_lossy().ends_with(".test.ts") {
            files.push(path);
        }
    }
    Ok(())
}

/// Run each test of `files` in its own app, with folders below the empty folder `work`. With `internal_imports`, the
/// tests can import the `yuke:internal/` modules, as the tests of yuke do.
pub(crate) async fn run(files: &[PathBuf], work: &Path, internal_imports: bool) -> Summary {
    let cache = work.join("cache");
    let mut summary = Summary::default();
    for (index, file) in files.iter().enumerate() {
        let name = file.display();
        let Some(path) = file.to_str() else {
            summary.failed += 1;
            push_line(&mut summary.failures, &format!("{name}: the path is not UTF-8"));
            continue;
        };
        let folder = work.join(index.to_string());
        let ran = run_test_file(path, &folder, async |place: &Path| {
            TestPlace::start(place, &cache, internal_imports).await
        })
        .await;
        let outcomes = match ran {
            Ok(outcomes) => outcomes,
            Err(error) => {
                summary.failed += 1;
                push_line(&mut summary.failures, &format!("{name}: {error}"));
                continue;
            }
        };
        for outcome in outcomes {
            let failure = match outcome.status {
                TestStatus::Passed => {
                    summary.passed += 1;
                    continue;
                }
                TestStatus::Failed(error) => error.to_string(),
                TestStatus::TimedOut => "timed out".to_owned(),
            };
            summary.failed += 1;
            push_line(
                &mut summary.failures,
                &format!("{name}: {}\n  {}", outcome.name, failure.replace('\n', "\n  ")),
            );
            for report in outcome.reports {
                let line = match report {
                    Report::Console { text, .. } => text,
                    Report::Notice(notice) => format!("{}: {}", notice.source, notice.message),
                    Report::Fault(error) => error.to_string(),
                    Report::Event(event) => format!("event {}", event.event),
                    Report::Barrier(_) => continue,
                };
                push_line(&mut summary.failures, &format!("  | {}", line.replace('\n', "\n  | ")));
            }
        }
    }
    summary
}

/// Add `line` and a line end to `text`.
fn push_line(text: &mut String, line: &str) {
    // A write to a `String` cannot fail.
    if writeln!(text, "{line}").is_err() {
        unreachable!("a write to a String fails");
    }
}

#[cfg(test)]
mod tests;
