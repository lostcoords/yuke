//! `yuke test`: run the TypeScript test files of `yuke:test`, each test in its own app with a scripted model.

use std::path::{Path, PathBuf};
use std::time::Duration;

use yuke_js::{TestSummary, find_test_files, run_test_files};

use crate::app::TestPlace;

/// The longest run of the import of a test file, of one test, and of the end of one test.
pub(crate) const TIME_LIMIT: Duration = Duration::from_secs(5);

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
            files.extend(find_test_files(&path).map_err(|error| format!("{}: {error}", path.display()))?);
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

/// Run each test of `files` in its own app, with folders below the empty folder `work` and the time limit `limit`.
/// With `internal_imports`, the tests can import the `yuke:internal/` modules, as the tests of yuke do.
pub(crate) async fn run(files: &[PathBuf], work: &Path, limit: Duration, internal_imports: bool) -> TestSummary {
    let cache = work.join("cache");
    run_test_files(files, work, limit, async |place: &Path| {
        TestPlace::start(place, &cache, internal_imports).await
    })
    .await
}

#[cfg(test)]
mod tests;
