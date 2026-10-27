//! The runner of the test files of `yuke:test`: a fresh runtime for each file, and each test of the file in turn,
//! with a time limit.

use std::fmt;
use std::path::Path;
use std::time::Duration;

use rquickjs::{Ctx, Function, Module, Object, Promise};
use tokio::sync::mpsc;

use crate::error::caught;
use crate::{Error, Options, Report, Runtime, ScriptError};

/// The longest run of the import of a test file, and of one test. A longer run stops the runtime of the file.
const TIME_LIMIT: Duration = Duration::from_secs(5);

/// The internal module that holds the tests of the file.
const REGISTRY: &str = "yuke:internal/test";

/// The result of one test of a file.
#[derive(Debug)]
pub struct TestOutcome {
    /// The name that the test registered.
    pub name: String,
    /// How the test ended.
    pub status: TestStatus,
    /// What the runtime reported while the test ran: its faults, notices, events, and `console` entries.
    pub reports: Vec<Report>,
}

/// How a test ended.
#[derive(Debug)]
pub enum TestStatus {
    /// The test returned, or its promise fulfilled, and the runtime reported no fault.
    Passed,
    /// The test threw, its promise rejected, or the runtime reported this fault while it ran.
    Failed(ScriptError),
    /// The test ran longer than the time limit, so the runner stopped the runtime of the file.
    TimedOut,
    /// An earlier test of the file timed out, so this test did not run.
    NotRun,
}

/// Why the run of a test file failed outside of its tests.
#[derive(Debug)]
pub enum TestFileError {
    /// The runtime failed: it did not start, the import threw, or the thread ended.
    Runtime(Error),
    /// The import ran longer than the time limit.
    ImportTimedOut,
    /// The runtime reported this fault during the import.
    Fault(ScriptError),
    /// The file registered no test.
    NoTests,
}

impl fmt::Display for TestFileError {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            Self::Runtime(error) => error.fmt(f),
            Self::ImportTimedOut => write!(f, "the import ran longer than {} seconds", TIME_LIMIT.as_secs()),
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
            Self::ImportTimedOut | Self::Fault(_) | Self::NoTests => None,
        }
    }
}

impl From<Error> for TestFileError {
    fn from(error: Error) -> Self {
        Self::Runtime(error)
    }
}

/// Run the tests of the file `path`, an absolute path, in a new runtime with `options`. The tests get `folder` as their
/// scratch folder: the caller makes it, and it is empty. The runtime stops at the end, also after a failure.
///
/// # Errors
///
/// Returns why the run failed outside of the tests: the runtime failed, the import timed out or made a fault, or the
/// file registers no test.
pub async fn run_test_file(options: Options, path: &str, folder: &Path) -> Result<Vec<TestOutcome>, TestFileError> {
    let (runtime, mut reports) = Runtime::start(options).await?;
    let outcomes = run_tests(&runtime, &mut reports, path, folder).await;
    let stopped = runtime.shutdown().await;
    let outcomes = outcomes?;
    stopped?;
    Ok(outcomes)
}

async fn run_tests(
    runtime: &Runtime,
    reports: &mut mpsc::UnboundedReceiver<Report>,
    path: &str,
    folder: &Path,
) -> Result<Vec<TestOutcome>, TestFileError> {
    let folder = folder
        .to_str()
        .ok_or_else(|| Error::Folder(folder.to_owned()))?
        .to_owned();
    runtime
        .caller
        .run(async move |ctx: Ctx<'_>, _registry| {
            let set: Function<'_> = caught(&ctx, registry(&ctx).await?.get("setFolder"))?;
            caught(&ctx, set.call::<_, ()>((folder,)))
        })
        .await?;
    tokio::time::timeout(TIME_LIMIT, runtime.import(path))
        .await
        .map_err(|_| TestFileError::ImportTimedOut)??;
    fence(runtime).await.map_err(|_| TestFileError::ImportTimedOut)??;
    if let Some(fault) = drain(reports).into_iter().find_map(|report| match report {
        Report::Fault(error) => Some(error),
        _ => None,
    }) {
        return Err(TestFileError::Fault(fault));
    }
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

    let mut outcomes = Vec::with_capacity(names.len());
    let mut stopped = false;
    for (index, name) in names.into_iter().enumerate() {
        if stopped {
            outcomes.push(TestOutcome {
                name,
                status: TestStatus::NotRun,
                reports: Vec::new(),
            });
            continue;
        }
        let call = runtime.caller.run(async move |ctx: Ctx<'_>, _registry| {
            let run: Function<'_> = caught(&ctx, registry(&ctx).await?.get("run"))?;
            let promise: Promise<'_> = caught(&ctx, run.call((index,)))?;
            let failure: Option<Object<'_>> = caught(&ctx, promise.into_future().await)?;
            Ok(match failure {
                Some(failure) => Some(ScriptError::from_value(&ctx, &caught(&ctx, failure.get("failed"))?)),
                None => None,
            })
        });
        let mut status = match tokio::time::timeout(TIME_LIMIT, call).await {
            Err(_) => TestStatus::TimedOut,
            Ok(Ok(None)) => TestStatus::Passed,
            Ok(Ok(Some(error))) => TestStatus::Failed(error),
            Ok(Err(error)) => return Err(error.into()),
        };
        // A timer of the test can still block the thread, so the fence has the time limit too.
        if !matches!(status, TestStatus::TimedOut) && fence(runtime).await.is_err() {
            status = TestStatus::TimedOut;
        }
        stopped = matches!(status, TestStatus::TimedOut);
        let reports = drain(reports);
        if matches!(status, TestStatus::Passed)
            && let Some(fault) = reports.iter().find_map(|report| match report {
                Report::Fault(error) => Some(error.clone()),
                _ => None,
            })
        {
            status = TestStatus::Failed(fault);
        }
        outcomes.push(TestOutcome { name, status, reports });
    }
    Ok(outcomes)
}

/// The namespace of the internal module that holds the tests.
async fn registry<'js>(ctx: &Ctx<'js>) -> Result<Object<'js>, Error> {
    let promise = caught(ctx, Module::import(ctx, REGISTRY))?;
    caught(ctx, promise.into_future().await)
}

/// Wait for an empty call. The drive sends the faults of a call after the poll that answered it, so after this call
/// the receiver holds them.
async fn fence(runtime: &Runtime) -> Result<Result<(), Error>, tokio::time::error::Elapsed> {
    tokio::time::timeout(TIME_LIMIT, runtime.caller.run(async |_ctx: Ctx<'_>, _registry| Ok(()))).await
}

/// The reports that wait in `reports`.
fn drain(reports: &mut mpsc::UnboundedReceiver<Report>) -> Vec<Report> {
    std::iter::from_fn(|| reports.try_recv().ok()).collect()
}
