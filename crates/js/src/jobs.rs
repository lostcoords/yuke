//! The jobs: work of one session that can outlive the tool call that starts it. A job is a process or the work of a
//! plugin. A job in a call stays hidden until a background request moves it. When a job without a call ends by itself, its
//! session gets one report. A stop ends it without a report. The list outlives a reload of the JavaScript.

use std::cell::RefCell;
use std::fmt;
use std::path::PathBuf;
use std::rc::Rc;

use rustix::process::{Pid, Signal};
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
    list: Rc<RefCell<List>>,
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
    label: String,
    session: SessionId,
    work: Work,
    stop: CancellationToken,
    /// A stop of this one job came, so the job sends no report.
    silenced: bool,
    /// Cancelled after the job left the list.
    ended: CancellationToken,
    /// Cancelled when the job runs without a call. Until then a call waits for the job, and neither a list nor a stop
    /// finds it.
    moved: CancellationToken,
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
    /// Whether a call still waits for the job.
    fn in_call(&self) -> bool {
        !self.moved.is_cancelled()
    }

    /// Whether a background request of `session` moves the job. A stopped job ends with its call.
    fn movable(&self, session: SessionId) -> bool {
        self.session == session && self.in_call() && !self.stop.is_cancelled()
    }

    /// Whether the job counts as running: a stop finds it, and a list shows it.
    fn runs(&self) -> bool {
        if self.in_call() {
            return false;
        }
        match self.work {
            Work::Process { group, .. } => group.is_some(),
            Work::Plugin { running, .. } => running,
        }
    }
}

impl Jobs {
    /// The jobs of this process.
    pub(crate) fn new(starts: bool) -> Self {
        Self {
            list: Rc::new(RefCell::new(List::default())),
            starts,
        }
    }

    /// Add a process job of `owner` to the list, so a close or a shutdown finds it in each state. With `in_call`, a call
    /// waits for it. The caller runs the job, and the drop of the answer ends it. An error is a text for the model.
    pub(crate) fn add_process(
        &self,
        owner: &dyn SessionHost,
        id: String,
        label: String,
        command: String,
        log: PathBuf,
        in_call: bool,
    ) -> Result<RunningJob, String> {
        let work = Work::Process {
            command,
            log,
            group: None,
        };
        self.add(owner, id, label, work, in_call)
    }

    /// Start a job of the plugin `plugin` for `owner`. With `in_call`, a call waits for it. An error is a text for the
    /// plugin.
    pub(crate) fn start_plugin(
        &self,
        owner: Rc<dyn SessionHost>,
        plugin: String,
        id: String,
        label: &str,
        in_call: bool,
    ) -> Result<PluginJob, String> {
        let label = short_label(label);
        let work = Work::Plugin {
            plugin: plugin.clone(),
            running: true,
        };
        let job = self.add(owner.as_ref(), id, label.clone(), work, in_call)?;
        let job = PluginJob {
            job,
            plugin,
            label,
            owner,
        };
        if !in_call {
            job.announce();
        }
        Ok(job)
    }

    fn add(
        &self,
        owner: &dyn SessionHost,
        id: String,
        label: String,
        work: Work,
        in_call: bool,
    ) -> Result<RunningJob, String> {
        // A job in a call ends with its call, so a process that ends with its turn can run it.
        if !self.starts && !in_call {
            return Err(NO_JOBS.to_owned());
        }
        let session = owner.session_id();
        let (stop, ended, moved) = (
            CancellationToken::new(),
            CancellationToken::new(),
            CancellationToken::new(),
        );
        if !in_call {
            moved.cancel();
        }
        let closed = owner.is_closed();
        let mut list = self.list.borrow_mut();
        if list.closed {
            return Err(SHUTTING_DOWN.to_owned());
        }
        if closed {
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
            moved: moved.clone(),
        });
        Ok(RunningJob {
            id,
            session,
            list: Rc::clone(&self.list),
            stop,
            ended,
            moved,
        })
    }

    /// Move each job of `session` that a call waits for out of its call. The call answers, and the job goes on. A process
    /// that ends with its turn has no one to receive the end of a job, so its jobs stay in their calls.
    pub fn move_to_background(&self, session: SessionId) {
        if !self.starts {
            return;
        }
        for job in &self.list.borrow().running {
            if job.movable(session) {
                job.moved.cancel();
            }
        }
    }

    /// Whether [`Jobs::move_to_background`] would move a job of `session`.
    pub fn has_movable(&self, session: SessionId) -> bool {
        self.starts && self.list.borrow().running.iter().any(|job| job.movable(session))
    }

    /// Stop the running job `id` of `session`, and wait for its end. Answer `false` when `session` runs no such job.
    /// [`SessionHost::job_changed`] gets the end before the answer. A stopped job sends no report. A plugin that ignores
    /// the stop makes this wait, so a caller that must not block drops the wait.
    pub async fn stop(&self, session: SessionId, id: &str) -> bool {
        let ended = {
            let mut list = self.list.borrow_mut();
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
        let ends: Vec<_> = self
            .list
            .borrow()
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
        self.list
            .borrow()
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
            let mut list = self.list.borrow_mut();
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
        let mut list = self.list.borrow_mut();
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
    list: Rc<RefCell<List>>,
    pub(crate) stop: CancellationToken,
    pub(crate) moved: CancellationToken,
    ended: CancellationToken,
}

impl RunningJob {
    /// Set the process group of a process job. Return whether this job received a stop.
    pub(crate) fn set_group(&self, new: Option<Pid>) -> bool {
        let mut list = self.list.borrow_mut();
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

impl Drop for RunningJob {
    fn drop(&mut self) {
        self.list
            .borrow_mut()
            .running
            .retain(|job| job.id != self.id || job.session != self.session);
        self.stop.cancel();
        self.moved.cancel();
        self.ended.cancel();
    }
}

/// A running job of a plugin.
pub(crate) struct PluginJob {
    job: RunningJob,
    plugin: String,
    label: String,
    owner: Rc<dyn SessionHost>,
}

impl PluginJob {
    /// The token that a stop cancels.
    pub(crate) fn stop(&self) -> CancellationToken {
        self.job.stop.clone()
    }

    /// The token that a move out of the call cancels.
    pub(crate) fn moved(&self) -> CancellationToken {
        self.job.moved.clone()
    }

    /// Show the job in the lists of its session.
    pub(crate) fn announce(&self) {
        self.owner.job_changed(self.protocol_job(JobState::Running));
    }

    /// End the job. Answer `true` when a call still waits for it: the call takes the answer, and the job never showed.
    /// Else `report` goes to the session as the status and the text of the one report, unless a stop came. The list keeps
    /// the job until the session receives its report. A later stop finds no job. A later move finds no job for that call.
    pub(crate) fn end(self, report: Option<(String, String)>) -> bool {
        let (in_call, stopped) = {
            let mut list = self.job.list.borrow_mut();
            let job = list
                .running
                .iter_mut()
                .find(|job| job.id == self.job.id && job.session == self.job.session);
            let in_call = job.is_some_and(|job| {
                if let Work::Plugin { running, .. } = &mut job.work {
                    *running = false;
                }
                job.in_call()
            });
            (in_call, self.job.stop.is_cancelled())
        };
        if in_call {
            return true;
        }
        let state = if stopped { JobState::Stopped } else { JobState::Ended };
        self.owner.job_changed(self.protocol_job(state));
        if let Some((status, text)) = report.filter(|_| !stopped) {
            tokio::task::spawn_local(async move {
                let input = report_input(&self.plugin, &self.job.id, &self.label, &status, &text);
                self.owner.accept_input(input).await;
            });
        }
        false
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

/// The first line of `text`, at most 60 characters, so that a report and a list show one row for a job.
pub(crate) fn short_label(text: &str) -> String {
    let text = text.trim();
    let (line, more) = text.split_once('\n').map_or((text, false), |(line, _)| (line, true));
    if more || line.chars().count() > 60 {
        format!("{}...", line.chars().take(57).collect::<String>())
    } else {
        line.to_owned()
    }
}

/// Make the report of the job `id` from `source`. Each job uses this frame. The user reads `{id} {label} · {status}`.
pub(crate) fn report_input(source: &str, id: &str, label: &str, status: &str, text: &str) -> Input {
    Input::notification(
        source,
        &format!("{id} {label} · {status}"),
        &format!("{id} {label}: {status}.\n{text}"),
    )
}
