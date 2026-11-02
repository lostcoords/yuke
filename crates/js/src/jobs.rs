//! The jobs: background work of one session that outlives the tool call that starts it. A job is a process or the work
//! of a plugin. When a job ends by itself, its session gets one report. A stop ends it without a report. The list
//! outlives a reload of the JavaScript.

use std::fmt;
use std::path::PathBuf;
use std::sync::{Arc, Mutex};

use rustix::process::{Pid, Signal};
use tokio::runtime::Handle;
use yuke_engine::CancellationToken;
use yuke_protocol::{Input, JobKind, JobState, SessionId};

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
    handle: Handle,
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
    label: String,
    session: SessionId,
    work: Work,
    stop: CancellationToken,
    /// A stop of this one job came, so the job sends no report.
    silenced: bool,
    /// Cancelled after the job left the list.
    ended: CancellationToken,
}

/// What a job runs.
enum Work {
    Process {
        command: String,
        log: PathBuf,
        /// The process group while the process runs. `None` before the spawn and after the end of the process.
        group: Option<Pid>,
    },
    Plugin {
        plugin: String,
        /// Whether the plugin has not ended the job yet.
        running: bool,
    },
}

impl Job {
    /// Whether the job counts as running: a stop finds it, and a list shows it.
    fn runs(&self) -> bool {
        match self.work {
            Work::Process { group, .. } => group.is_some(),
            Work::Plugin { running, .. } => running,
        }
    }
}

impl Jobs {
    /// The jobs on the tokio runtime of `handle`.
    pub(crate) fn new(starts: bool, handle: Handle) -> Self {
        Self {
            list: Arc::new(Mutex::new(List::default())),
            starts,
            handle,
        }
    }

    /// Add a process job of `owner` to the list, so a close or a shutdown finds it in each state. The caller runs the job,
    /// and the drop of the answer ends it. An error is a text for the model.
    pub(crate) fn add_process(
        &self,
        owner: &dyn SessionHost,
        id: String,
        label: String,
        command: String,
        log: PathBuf,
    ) -> Result<RunningJob, String> {
        let work = Work::Process {
            command,
            log,
            group: None,
        };
        self.add(owner, id, label, work)
    }

    /// Start a job of the plugin `plugin` for `owner`. An error is a text for the plugin.
    pub(crate) fn start_plugin(
        &self,
        owner: Arc<dyn SessionHost>,
        plugin: String,
        id: String,
        label: String,
    ) -> Result<PluginJob, String> {
        let work = Work::Plugin {
            plugin: plugin.clone(),
            running: true,
        };
        let job = self.add(owner.as_ref(), id, label.clone(), work)?;
        let job = PluginJob {
            job,
            plugin,
            label,
            owner,
            handle: self.handle.clone(),
        };
        job.owner.job_changed(job.protocol_job(JobState::Running));
        Ok(job)
    }

    fn add(&self, owner: &dyn SessionHost, id: String, label: String, work: Work) -> Result<RunningJob, String> {
        if !self.starts {
            return Err(NO_JOBS.to_owned());
        }
        let session = owner.session_id();
        let (stop, ended) = (CancellationToken::new(), CancellationToken::new());
        let mut list = lock(&self.list);
        if list.closed {
            return Err(SHUTTING_DOWN.to_owned());
        }
        // A close marks the host before it takes this lock. So a job either sees the close here, or the close finds it.
        if owner.is_closed() {
            return Err(SESSION_CLOSED.to_owned());
        }
        if list.running.iter().any(|job| job.session == session && job.id == id) {
            return Err(format!("the job did not start: the job {id} still runs"));
        }
        list.running.push(Job {
            id: id.clone(),
            label,
            session,
            work,
            stop: stop.clone(),
            silenced: false,
            ended: ended.clone(),
        });
        Ok(RunningJob {
            id,
            session,
            list: Arc::clone(&self.list),
            stop,
            ended,
        })
    }

    /// Stop the running job `id` of `session`, and wait for its end. Answer `false` when `session` runs no such job.
    /// [`SessionHost::job_changed`] gets the end before the answer. A stopped job sends no report. A plugin that ignores
    /// the stop makes this wait, so a caller that must not block drops the wait.
    pub async fn stop(&self, session: SessionId, id: &str) -> bool {
        let ended = {
            let mut list = lock(&self.list);
            let found = list
                .running
                .iter_mut()
                .find(|job| job.id == id && job.runs() && job.session == session);
            let Some(job) = found else {
                return false;
            };
            job.silenced = true;
            job.stop.cancel();
            job.ended.clone()
        };
        ended.cancelled().await;
        true
    }

    /// Stop each job of `session`, and wait until each job has ended and delivered its end. A stopped job sends no report,
    /// and a process that ended by itself before the stop still delivers its end.
    pub async fn close_session(&self, session: SessionId) {
        let ends: Vec<_> = lock(&self.list)
            .running
            .iter()
            .filter(|job| job.session == session)
            .map(|job| {
                job.stop.cancel();
                job.ended.clone()
            })
            .collect();
        for ended in ends {
            ended.cancelled().await;
        }
    }

    /// The running jobs of `session`, oldest first.
    pub fn running(&self, session: SessionId) -> Vec<yuke_protocol::Job> {
        lock(&self.list)
            .running
            .iter()
            .filter(|job| job.runs() && job.session == session)
            .map(|job| yuke_protocol::Job {
                id: job.id.clone(),
                label: job.label.clone(),
                state: JobState::Running,
                kind: match &job.work {
                    Work::Process { command, log, .. } => JobKind::Process {
                        command: command.clone(),
                        log: log.clone(),
                        exit_code: None,
                    },
                    Work::Plugin { plugin, .. } => JobKind::Plugin { plugin: plugin.clone() },
                },
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
                    job.ended.clone()
                })
                .collect()
        };
        for ended in ends {
            ended.cancelled().await;
        }
    }
}

impl Drop for Jobs {
    /// Kill each running process, so no job outlives the consumer. A shutdown has already stopped them with a grace. A
    /// killed job sends no report, also when its task sees the exit of the process before the stop.
    fn drop(&mut self) {
        let mut list = lock(&self.list);
        list.closed = true;
        for job in &mut list.running {
            job.silenced = true;
            job.stop.cancel();
            if let Work::Process { group: Some(group), .. } = job.work
                && signal_group(group, Signal::KILL).is_err()
            {
                // The system refused the kill, and the consumer has nothing left to tell.
            }
        }
    }
}

/// The part of a job that its owner holds. The drop removes the job from the list, then tells each waiter, so a waiter
/// finds the list without it.
pub(crate) struct RunningJob {
    pub(crate) id: String,
    session: SessionId,
    list: Arc<Mutex<List>>,
    pub(crate) stop: CancellationToken,
    ended: CancellationToken,
}

impl RunningJob {
    /// Set the process group of a process job, and answer whether a stop of this one job came. A stop takes the same
    /// lock, so after the end of the process a stop either found the process and silences the report, or finds no
    /// process.
    pub(crate) fn set_group(&self, new: Option<Pid>) -> bool {
        let mut list = lock(&self.list);
        let job = list
            .running
            .iter_mut()
            .find(|job| job.id == self.id && job.session == self.session);
        job.is_some_and(|job| {
            if let Work::Process { group, .. } = &mut job.work {
                *group = new;
            }
            job.silenced
        })
    }
}

impl RunningJob {
    /// Mark a plugin job as no longer running, and answer whether a stop came first. A stop takes the same lock, so a
    /// later stop finds no job and the report still goes out.
    fn finish(&self) -> bool {
        let mut list = lock(&self.list);
        let job = list
            .running
            .iter_mut()
            .find(|job| job.id == self.id && job.session == self.session);
        if let Some(Job {
            work: Work::Plugin { running, .. },
            ..
        }) = job
        {
            *running = false;
        }
        self.stop.is_cancelled()
    }
}

impl Drop for RunningJob {
    fn drop(&mut self) {
        lock(&self.list)
            .running
            .retain(|job| job.id != self.id || job.session != self.session);
        self.stop.cancel();
        self.ended.cancel();
    }
}

/// A running job of a plugin.
pub(crate) struct PluginJob {
    job: RunningJob,
    plugin: String,
    label: String,
    owner: Arc<dyn SessionHost>,
    handle: Handle,
}

impl PluginJob {
    /// The token that a stop cancels.
    pub(crate) fn stop(&self) -> CancellationToken {
        self.job.stop.clone()
    }

    /// End the job, and send `report` as the status and the text of the one report. A stop drops the report. The job stays
    /// in the list until the session has the report.
    pub(crate) fn end(self, report: Option<(String, String)>) {
        let stopped = self.job.finish();
        let state = if stopped { JobState::Stopped } else { JobState::Ended };
        self.owner.job_changed(self.protocol_job(state));
        if let Some((status, text)) = report.filter(|_| !stopped) {
            self.handle.clone().spawn(async move {
                let input = report_input(&self.plugin, &self.job.id, &status, &text);
                self.owner.accept_input(input).await;
            });
        }
    }

    fn protocol_job(&self, state: JobState) -> yuke_protocol::Job {
        yuke_protocol::Job {
            id: self.job.id.clone(),
            label: self.label.clone(),
            state,
            kind: JobKind::Plugin {
                plugin: self.plugin.clone(),
            },
        }
    }
}

/// The report of the job `id` from `source`, the same frame for each job. The user reads `{id} {status}`.
pub(crate) fn report_input(source: &str, id: &str, status: &str, text: &str) -> Input {
    Input::notification(source, &format!("{id} {status}"), &format!("{id} {status}.\n{text}"))
}

/// The running jobs. A panic of another holder leaves a valid list, so a poisoned lock still serves.
fn lock(list: &Mutex<List>) -> std::sync::MutexGuard<'_, List> {
    list.lock().unwrap_or_else(std::sync::PoisonError::into_inner)
}
