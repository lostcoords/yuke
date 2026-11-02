//! The jobs: background work of one session that outlives the tool call that starts it. When a job ends by itself, its
//! session gets one report. A stop ends it without a report. The list outlives a reload of the JavaScript.

use std::fmt;
use std::path::PathBuf;
use std::sync::{Arc, Mutex};

use rustix::process::{Pid, Signal};
use tokio::sync::watch;
use yuke_engine::CancellationToken;
use yuke_protocol::{JobState, SessionId};

use crate::processes::signal_group;
use crate::tools::SessionHost;

/// The answer to a job start after the shutdown.
const SHUTTING_DOWN: &str = "the job did not start: yuke is shutting down";
/// The answer to a job start after the close of its session.
const SESSION_CLOSED: &str = "the job did not start: its session is closed";
/// The answer to a job start in a process that ends with its turn.
const NO_JOBS: &str =
    "This run ends with its turn, so it cannot start a background job. Run the command without background.";

/// The jobs of this process, of each session.
pub struct Jobs {
    list: Arc<Mutex<List>>,
    /// Whether a job can start. A process that ends with its turn has no one to receive the end of a job.
    starts: bool,
}

impl fmt::Debug for Jobs {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.debug_struct("Jobs")
            .field("starts", &self.starts)
            .finish_non_exhaustive()
    }
}

/// The jobs, and whether the list still takes a job.
#[derive(Default)]
struct List {
    /// Each job from its start to the delivery of its end, so a close and a shutdown wait for the whole job.
    running: Vec<Job>,
    /// The consumer shut the jobs down, so a job start fails.
    closed: bool,
}

/// A background job.
struct Job {
    id: String,
    command: String,
    session: SessionId,
    log: PathBuf,
    /// The process group while the process runs. `None` before the spawn and after the end of the process.
    group: Option<Pid>,
    stop: CancellationToken,
    /// A stop of this one job came, so the job sends no end message.
    silenced: bool,
    /// The end, after the job has delivered it.
    end: watch::Receiver<Option<JobEnd>>,
}

/// How a job ended.
#[derive(Debug, Clone, Copy, Default, PartialEq, Eq)]
pub(crate) struct JobEnd {
    pub(crate) exit_code: Option<i32>,
    pub(crate) signal: Option<i32>,
    /// A stop ended the job.
    pub(crate) stopped: bool,
}

impl JobEnd {
    /// The end in words, for example `exited 0`.
    pub(crate) fn label(self) -> String {
        match self {
            JobEnd { stopped: true, .. } => "stopped".to_owned(),
            JobEnd {
                exit_code: Some(code), ..
            } => format!("exited {code}"),
            JobEnd {
                signal: Some(signal), ..
            } => format!("signal {signal}"),
            JobEnd { .. } => "failed".to_owned(),
        }
    }

    pub(crate) fn state(self) -> JobState {
        JobState::Ended {
            exit_code: self.exit_code,
            signal: self.signal,
            stopped: self.stopped,
        }
    }
}

impl Jobs {
    pub(crate) fn new(starts: bool) -> Self {
        Self {
            list: Arc::new(Mutex::new(List::default())),
            starts,
        }
    }

    /// Add a job of `owner` to the list, so a close or a shutdown finds it in each state. The caller runs the job and
    /// gives its end to the answer. An error is a text for the model.
    pub(crate) fn add(
        &self,
        owner: &dyn SessionHost,
        id: String,
        command: String,
        log: PathBuf,
    ) -> Result<RunningJob, String> {
        if !self.starts {
            return Err(NO_JOBS.to_owned());
        }
        let stop = CancellationToken::new();
        let (finish, end) = watch::channel(None);
        let mut list = lock(&self.list);
        if list.closed {
            return Err(SHUTTING_DOWN.to_owned());
        }
        // A close marks the host before it takes this lock. So a job either sees the close here, or the close finds it.
        if owner.is_closed() {
            return Err(SESSION_CLOSED.to_owned());
        }
        list.running.push(Job {
            id: id.clone(),
            command,
            session: owner.session_id(),
            log,
            group: None,
            stop: stop.clone(),
            silenced: false,
            end,
        });
        Ok(RunningJob {
            id,
            list: Arc::clone(&self.list),
            stop,
            finish,
        })
    }

    /// Stop the running job `id` of `session`, wait for its end, and answer the end in words and the log. Answer `None`
    /// when `session` runs no such job. [`SessionHost::job_changed`] gets the end before the answer. A stopped job sends
    /// no end message.
    pub async fn stop(&self, session: SessionId, id: &str) -> Option<(String, PathBuf)> {
        let (mut end, log) = {
            let mut list = lock(&self.list);
            let job = list
                .running
                .iter_mut()
                .find(|job| job.id == id && job.group.is_some() && job.session == session)?;
            job.silenced = true;
            job.stop.cancel();
            (job.end.clone(), job.log.clone())
        };
        let label = match end.wait_for(Option::is_some).await {
            Ok(end) => end.unwrap_or_default().label(),
            Err(_) => JobEnd::default().label(),
        };
        Some((label, log))
    }

    /// Stop each job of `session`, and wait until each job has ended and delivered its end. A stopped job sends no end
    /// message, and a job that ended by itself before the stop still delivers its end.
    pub async fn close_session(&self, session: SessionId) {
        let ends: Vec<_> = lock(&self.list)
            .running
            .iter()
            .filter(|job| job.session == session)
            .map(|job| {
                job.stop.cancel();
                job.end.clone()
            })
            .collect();
        wait_for_ends(ends).await;
    }

    /// The jobs of `session` whose process runs, oldest first.
    pub fn running(&self, session: SessionId) -> Vec<yuke_protocol::Job> {
        lock(&self.list)
            .running
            .iter()
            .filter(|job| job.group.is_some() && job.session == session)
            .map(|job| yuke_protocol::Job {
                id: job.id.clone(),
                command: job.command.clone(),
                log: job.log.clone(),
                state: JobState::Running,
            })
            .collect()
    }

    /// Refuse each later job, stop each running job, and wait for the ends.
    pub(crate) async fn shutdown(&self) {
        let ends: Vec<_> = {
            let mut list = lock(&self.list);
            list.closed = true;
            list.running
                .iter()
                .map(|job| {
                    job.stop.cancel();
                    job.end.clone()
                })
                .collect()
        };
        wait_for_ends(ends).await;
    }
}

impl Drop for Jobs {
    /// Kill each running job, so no job outlives the consumer. A shutdown has already stopped them with a grace. A killed
    /// job sends no end message, also when its task sees the exit of the process before the stop.
    fn drop(&mut self) {
        let mut list = lock(&self.list);
        list.closed = true;
        for job in &mut list.running {
            job.silenced = true;
            job.stop.cancel();
            if let Some(group) = job.group
                && signal_group(group, Signal::KILL).is_err()
            {
                // The system refused the kill, and the consumer has nothing left to tell.
            }
        }
    }
}

/// The part of a job that its task holds, from the start to the delivery of the end.
pub(crate) struct RunningJob {
    pub(crate) id: String,
    list: Arc<Mutex<List>>,
    pub(crate) stop: CancellationToken,
    finish: watch::Sender<Option<JobEnd>>,
}

impl RunningJob {
    /// Set the process group of the job, and answer whether a stop of this one job came. A stop takes the same lock, so
    /// after the end of the process a stop either found the process and silences the end message, or finds no process.
    pub(crate) fn set_group(&self, group: Option<Pid>) -> bool {
        let mut list = lock(&self.list);
        let job = list.running.iter_mut().find(|job| job.id == self.id);
        job.is_some_and(|job| {
            job.group = group;
            job.silenced
        })
    }

    /// Remove the job from the list, then tell each waiter, so a waiter finds the list without it.
    pub(crate) fn end(self, end: Option<JobEnd>) {
        lock(&self.list).running.retain(|job| job.id != self.id);
        if self.finish.send(Some(end.unwrap_or_default())).is_err() {
            // No stop waits for the end.
        }
    }
}

/// Wait for the end of each job that `ends` watches.
async fn wait_for_ends(ends: Vec<watch::Receiver<Option<JobEnd>>>) {
    for mut end in ends {
        if end.wait_for(Option::is_some).await.is_err() {
            // The task of the job has ended, so the job has ended too.
        }
    }
}

/// The running jobs. A panic of another holder leaves a valid list, so a poisoned lock still serves.
fn lock(list: &Mutex<List>) -> std::sync::MutexGuard<'_, List> {
    list.lock().unwrap_or_else(std::sync::PoisonError::into_inner)
}
