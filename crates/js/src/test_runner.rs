//! The runner of the test files of `yuke:test`: each test of a file in a fresh runtime, with a time limit.

use std::fmt::{self, Write as _};
use std::io;
use std::num::NonZeroUsize;
use std::path::{Path, PathBuf};
use std::task::Poll;
use std::time::Duration;

use rquickjs::{Ctx, Function, Module, Object, Promise};
use tokio::sync::mpsc;

use crate::error::caught;
use crate::{Error, Report, Runtime, ScriptError};

/// The internal module that holds the tests of the file.
const REGISTRY: &str = "yuke:internal/test";

/// The failure of the runtime of a test that the runner only reports.
pub type TestError = Box<dyn std::error::Error + Send + Sync>;

/// The owner of the runtime of one test: a bare runtime, or an app around a runtime. The runner stops the owner after
/// the test.
pub trait TestRuntime: Sized {
    /// The runtime that imports the file and runs the test.
    fn runtime(&self) -> &Runtime;

    /// Stop the owner and its runtime. With `timed_out`, the JavaScript can still run. Then stop the JavaScript first.
    fn shutdown(self, timed_out: bool) -> impl Future<Output = Result<(), TestError>>;
}

impl TestRuntime for Runtime {
    fn runtime(&self) -> &Runtime {
        self
    }

    async fn shutdown(self, _timed_out: bool) -> Result<(), TestError> {
        Ok(Runtime::shutdown(self).await?)
    }
}

/// The result of one test of a file.
#[derive(Debug)]
pub struct TestOutcome {
    /// The name that the test registered.
    pub name: String,
    /// How the test ended.
    pub status: TestStatus,
    /// What the runtime reported from the start of the test to the end of its runtime: its faults, notices, events,
    /// and `console` entries.
    pub reports: Vec<Report>,
}

/// How a test ended.
#[derive(Debug)]
pub enum TestStatus {
    /// The test returned, or its promise fulfilled, and the runtime reported no fault.
    Passed,
    /// The test threw, its promise rejected, or the runtime reported this fault.
    Failed(ScriptError),
    /// The test ran longer than the time limit, so the runner stopped its runtime.
    TimedOut,
}

/// Why the run of a test file failed outside of its tests.
#[derive(Debug)]
pub enum TestFileError {
    /// The runtime of a test failed: it did not start, the import threw, the thread ended, or the shutdown failed.
    Runtime(TestError),
    /// The import ran longer than this time limit.
    ImportTimedOut(Duration),
    /// The runtime reported this fault during the import.
    Fault(ScriptError),
    /// The file registered no test.
    NoTests,
}

impl fmt::Display for TestFileError {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            Self::Runtime(error) => error.fmt(f),
            Self::ImportTimedOut(limit) => write!(f, "the import ran longer than {limit:?}"),
            Self::Fault(error) => write!(f, "the import made a fault: {error}"),
            Self::NoTests => f.write_str("the file registers no test"),
        }
    }
}

impl std::error::Error for TestFileError {
    fn source(&self) -> Option<&(dyn std::error::Error + 'static)> {
        match self {
            // The text is the text of the inner error, so the source is the source of the inner error.
            Self::Runtime(error) => error.source(),
            Self::ImportTimedOut(_) | Self::Fault(_) | Self::NoTests => None,
        }
    }
}

impl From<Error> for TestFileError {
    fn from(error: Error) -> Self {
        Self::Runtime(Box::new(error))
    }
}

/// Run each test of the file `path`, an absolute path, in its own runtime from `start`. For each test, the runner makes
/// a new folder below `folder`, gives it to `start`, and gives its `scratch` subfolder to the test as `folder()`. A
/// folder of a test that exists already fails the run. The first import gives the names of the tests. The import, each
/// test, and the end of each test have the time limit `limit`. A longer run stops the runtime of the test.
///
/// # Errors
///
/// Returns why the run failed outside of the tests: a runtime failed, an import timed out or made a fault, or the file
/// registers no test.
pub async fn run_test_file<T: TestRuntime>(
    path: &str,
    folder: &Path,
    limit: Duration,
    mut start: impl AsyncFnMut(&Path) -> Result<(T, mpsc::UnboundedReceiver<Report>), TestError>,
) -> Result<Vec<TestOutcome>, TestFileError> {
    let mut names: Option<Vec<String>> = None;
    let mut outcomes = Vec::new();
    let mut index = 0;
    while names.as_ref().is_none_or(|names| index < names.len()) {
        let place = folder.join(index.to_string());
        let scratch = place.join("scratch");
        // `create_dir` fails on a folder that exists, so each test starts with an empty folder.
        // A session names its folder by its real path, so the test gets that path too.
        let scratch = std::fs::create_dir_all(folder)
            .and_then(|()| std::fs::create_dir(&place))
            .and_then(|()| std::fs::create_dir(&scratch))
            .and_then(|()| scratch.canonicalize())
            .map_err(|error| TestFileError::Runtime(Box::new(error)))?;
        let (owner, mut reports) = start(&place).await.map_err(TestFileError::Runtime)?;
        let expected = names.as_ref().and_then(|names| names.get(index)).map(String::as_str);
        let ran = run_test(owner.runtime(), &mut reports, path, &scratch, index, expected, limit).await;
        let timed_out = matches!(
            ran,
            Ok(Ran {
                status: TestStatus::TimedOut,
                ..
            }) | Err(TestFileError::ImportTimedOut(_))
        );
        // A cleanup that never settles would hold the run, so the end of a test has the time limit too.
        let stopped = tokio::time::timeout(limit, owner.shutdown(timed_out)).await;
        let mut ran = ran?;
        let ended = match stopped {
            Ok(stopped) => {
                stopped.map_err(TestFileError::Runtime)?;
                true
            }
            Err(_) => false,
        };
        // The sender ends with the runtime, so this drain also holds the reports of the shutdown.
        ran.reports.extend(drain(&mut reports));
        if matches!(ran.status, TestStatus::Passed)
            && let Some(fault) = ran.reports.iter().find_map(|report| match report {
                Report::Fault(error) => Some(error.clone()),
                _ => None,
            })
        {
            ran.status = TestStatus::Failed(fault);
        }
        if !ended && matches!(ran.status, TestStatus::Passed) {
            ran.status = TestStatus::Failed(ScriptError {
                name: Some("Error".to_owned()),
                message: format!("the end of the test ran longer than {limit:?}: a cleanup did not settle"),
                stack: None,
            });
        }
        if let Some(found) = ran.names {
            names = Some(found);
        }
        let Some(name) = names.as_ref().and_then(|names| names.get(index)) else {
            return Err(TestFileError::NoTests);
        };
        outcomes.push(TestOutcome {
            name: name.clone(),
            status: ran.status,
            reports: ran.reports,
        });
        index += 1;
    }
    Ok(outcomes)
}

/// The result of a run of test files.
#[derive(Debug, Default)]
pub struct TestSummary {
    /// The count of the tests that passed.
    pub passed: usize,
    /// The count of the tests that failed, and of the files that failed outside of their tests.
    pub failed: usize,
    /// The text of each failure, for the user. A failed test gives its file, its name, its error, and its reports. A
    /// failed file gives its file and its error.
    pub failures: String,
}

/// Each `*.test.ts` file below `folder`, in name order.
///
/// # Errors
///
/// Returns the error of a folder that cannot be read.
pub fn find_test_files(folder: &Path) -> io::Result<Vec<PathBuf>> {
    let mut files = Vec::new();
    let mut folders = vec![folder.to_owned()];
    while let Some(folder) = folders.pop() {
        for entry in std::fs::read_dir(folder)? {
            let path = entry?.path();
            if path.is_dir() {
                folders.push(path);
            } else if path.to_string_lossy().ends_with(".test.ts") {
                files.push(path);
            }
        }
    }
    files.sort();
    Ok(files)
}

/// Run each test of `files` in its own runtime from `start`, with folders below the folder `work` and the time limit
/// `limit`. The files run in parallel, at most as many as [`std::thread::available_parallelism`] gives. The summary
/// keeps the order of `files`. See [`run_test_file`].
pub async fn run_test_files<T: TestRuntime>(
    files: &[PathBuf],
    work: &Path,
    limit: Duration,
    start: impl AsyncFn(&Path) -> Result<(T, mpsc::UnboundedReceiver<Report>), TestError>,
) -> TestSummary {
    let parallel = std::thread::available_parallelism().map_or(1, NonZeroUsize::get);
    let run = async |index: usize, file: &PathBuf| match file.to_str() {
        Some(path) => run_test_file(path, &work.join(index.to_string()), limit, &start)
            .await
            .map_err(|error| error.to_string()),
        None => Err("the path is not UTF-8".to_owned()),
    };
    let mut waiting = files.iter().enumerate();
    let mut running = Vec::new();
    let mut ran: Vec<_> = files.iter().map(|_| None).collect();
    // Each JavaScript runtime has its own thread, so one task can drive all runs.
    std::future::poll_fn(|cx| {
        loop {
            while running.len() < parallel
                && let Some((index, file)) = waiting.next()
            {
                running.push((index, Box::pin(run(index, file))));
            }
            if running.is_empty() {
                return Poll::Ready(());
            }
            let before = running.len();
            running.retain_mut(|(index, future)| match future.as_mut().poll(cx) {
                Poll::Ready(result) => {
                    ran[*index] = Some(result);
                    false
                }
                Poll::Pending => true,
            });
            // A run that ended frees a place, so the loop starts the next file and polls it once.
            if running.len() == before {
                return Poll::Pending;
            }
        }
    })
    .await;

    let mut passed = 0;
    let (mut failed, mut failures) = (0, String::new());
    let mut fail = |text: String| {
        failed += 1;
        // A write to a `String` cannot fail.
        writeln!(failures, "{text}").unwrap_or_else(|_| unreachable!("a write to a String fails"));
    };
    for (file, ran) in files.iter().zip(ran) {
        let name = file.display();
        let outcomes = match ran.unwrap_or_else(|| unreachable!("the loop ends after the run of each file")) {
            Ok(outcomes) => outcomes,
            Err(error) => {
                fail(format!("{name}: {error}"));
                continue;
            }
        };
        for outcome in outcomes {
            let failure = match outcome.status {
                TestStatus::Passed => {
                    passed += 1;
                    continue;
                }
                TestStatus::Failed(error) => error.to_string(),
                TestStatus::TimedOut => "timed out".to_owned(),
            };
            let mut text = format!("{name}: {}\n  {}", outcome.name, failure.replace('\n', "\n  "));
            for report in outcome.reports {
                let line = match report {
                    Report::Console { text, .. } => text,
                    Report::Notice(notice) => format!("{}: {}", notice.source, notice.message),
                    Report::Fault(error) => error.to_string(),
                    Report::Event(event) => format!("event {}", event.event),
                    Report::Barrier(_) => continue,
                };
                text.push_str("\n  | ");
                text.push_str(&line.replace('\n', "\n  | "));
            }
            fail(text);
        }
    }
    TestSummary {
        passed,
        failed,
        failures,
    }
}

/// The run of one test: its status, its reports so far, and the names of the tests when the runner asked for them.
struct Ran {
    status: TestStatus,
    reports: Vec<Report>,
    names: Option<Vec<String>>,
}

/// Import the file into `runtime`, and run the test at `index` with `scratch` as its folder. Without `expected`, the
/// name of the test, the run first reads the names of the tests.
async fn run_test(
    runtime: &Runtime,
    reports: &mut mpsc::UnboundedReceiver<Report>,
    path: &str,
    scratch: &Path,
    index: usize,
    expected: Option<&str>,
    limit: Duration,
) -> Result<Ran, TestFileError> {
    let scratch = scratch
        .to_str()
        .ok_or_else(|| Error::Folder(scratch.to_owned()))?
        .to_owned();
    runtime
        .caller
        .run(async move |ctx: Ctx<'_>, _registry| {
            let set: Function<'_> = caught(&ctx, registry(&ctx).await?.get("setFolder"))?;
            caught(&ctx, set.call::<_, ()>((scratch,)))
        })
        .await?;
    tokio::time::timeout(limit, runtime.import(path))
        .await
        .map_err(|_| TestFileError::ImportTimedOut(limit))??;
    fence(runtime, limit)
        .await
        .map_err(|_| TestFileError::ImportTimedOut(limit))??;
    if let Some(fault) = drain(reports).into_iter().find_map(|report| match report {
        Report::Fault(error) => Some(error),
        _ => None,
    }) {
        return Err(TestFileError::Fault(fault));
    }
    let names = if expected.is_none() {
        let names: Vec<String> = runtime
            .caller
            .run(async |ctx: Ctx<'_>, _registry| {
                let names: Function<'_> = caught(&ctx, registry(&ctx).await?.get("names"))?;
                caught(&ctx, names.call(()))
            })
            .await?;
        if names.is_empty() {
            return Err(TestFileError::NoTests);
        }
        Some(names)
    } else {
        None
    };

    // The name guards against an import that registers other tests than the first import.
    let name = expected
        .or_else(|| names.as_ref().and_then(|names| names.get(index)).map(String::as_str))
        .unwrap_or_default()
        .to_owned();
    let call = runtime.caller.run(async move |ctx: Ctx<'_>, _registry| {
        let run: Function<'_> = caught(&ctx, registry(&ctx).await?.get("run"))?;
        let promise: Promise<'_> = caught(&ctx, run.call((index, name)))?;
        let failure: Option<Object<'_>> = caught(&ctx, promise.into_future().await)?;
        Ok(match failure {
            Some(failure) => Some(ScriptError::from_value(&ctx, &caught(&ctx, failure.get("failed"))?)),
            None => None,
        })
    });
    let mut status = match tokio::time::timeout(limit, call).await {
        Err(_) => TestStatus::TimedOut,
        Ok(Ok(None)) => TestStatus::Passed,
        Ok(Ok(Some(error))) => TestStatus::Failed(error),
        Ok(Err(error)) => return Err(error.into()),
    };
    // A timer of the test can still block the thread, so the fence has the time limit too.
    if !matches!(status, TestStatus::TimedOut) && fence(runtime, limit).await.is_err() {
        status = TestStatus::TimedOut;
    }
    Ok(Ran {
        status,
        reports: drain(reports),
        names,
    })
}

/// The namespace of the internal module that holds the tests.
async fn registry<'js>(ctx: &Ctx<'js>) -> Result<Object<'js>, Error> {
    let promise = caught(ctx, Module::import(ctx, REGISTRY))?;
    caught(ctx, promise.into_future().await)
}

/// Wait up to `limit` for a call that ends two polls of the drive later. After this call the receiver holds the faults
/// of the earlier calls.
async fn fence(runtime: &Runtime, limit: Duration) -> Result<Result<(), Error>, tokio::time::error::Elapsed> {
    let call = runtime.caller.run(async |_ctx: Ctx<'_>, _registry| {
        // The drive reports a rejection at the end of the poll after the poll that saw it. In the runtime of the
        // thread, `yield_now` wakes the call only after the current poll of the drive ends.
        tokio::task::yield_now().await;
        tokio::task::yield_now().await;
        Ok(())
    });
    tokio::time::timeout(limit, call).await
}

/// The reports that wait in `reports`.
fn drain(reports: &mut mpsc::UnboundedReceiver<Report>) -> Vec<Report> {
    std::iter::from_fn(|| reports.try_recv().ok()).collect()
}
