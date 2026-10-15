//! The child processes of the tools: the commands of `exec` and the background jobs. They run on the tokio runtime of
//! the consumer, so a job outlives a reload of the JavaScript.

use std::collections::VecDeque;
use std::ffi::OsStr;
use std::fmt;
use std::fs::File;
use std::hash::{BuildHasher, RandomState};
use std::io::{self, Read, Seek, SeekFrom, Write};
use std::path::{Path, PathBuf};
use std::process::{ExitStatus, Stdio};
use std::sync::atomic::{AtomicU32, AtomicU64, Ordering};
use std::sync::{Arc, Mutex};
use std::time::Duration;

use rustix::process::{Pid, Signal, kill_process_group};
use tokio::process::{Child, Command};
use tokio::runtime::Handle;
use tokio::sync::{mpsc, oneshot, watch};
use yuke_engine::CancellationToken;

use crate::tools::SessionHost;

/// The job numbers with four base-36 digits: from `1000` to `zzzz`.
const FIRST_JOB_NUMBER: u32 = 36 * 36 * 36;
const JOB_NUMBERS: u32 = 36 * 36 * 36 * 36 - FIRST_JOB_NUMBER;

/// The answer to a job start after the shutdown.
const SHUTTING_DOWN: &str = "the job did not start: yuke is shutting down";

/// The time between SIGTERM and SIGKILL when a process group stops.
const GRACE: Duration = Duration::from_secs(2);

/// The wait between two checks for a process that remains in a stopping group.
const GROUP_POLL: Duration = Duration::from_millis(20);

/// The bytes that one read of the output takes.
const CHUNK: usize = 64 * 1024;

/// The lines of the log that the end message of a job shows.
const TAIL_LINES: usize = 20;

/// The parameters for one command call.
pub(crate) struct Request {
    pub(crate) command: String,
    pub(crate) folder: PathBuf,
    pub(crate) timeout: Duration,
    pub(crate) max_bytes: usize,
    /// The token that stops the command.
    pub(crate) stop: CancellationToken,
}

/// The child processes of the tools. The consumer creates one for the process inside its tokio runtime, which must
/// enable I/O and time. It gives the same value to every JavaScript runtime of the process. The full outputs of the
/// commands and the logs of the jobs go to `folder`. [`Processes::shutdown`] removes the folder.
pub struct Processes {
    folder: PathBuf,
    handle: Handle,
    last_number: AtomicU64,
    /// The counter of the job ids. It starts at a random number, so an id in the transcript of an earlier process
    /// rarely names a job of this one.
    last_job: AtomicU32,
    /// The running jobs. The task of a job removes it at its end.
    jobs: Arc<Mutex<Jobs>>,
    /// Whether a job can start. A process that ends with its turn has no one to receive the end of a job.
    starts_jobs: bool,
}

impl fmt::Debug for Processes {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.debug_struct("Processes")
            .field("folder", &self.folder)
            .finish_non_exhaustive()
    }
}

/// The running jobs, and whether the list still takes a job.
#[derive(Default)]
struct Jobs {
    running: Vec<Job>,
    /// The consumer shut the processes down, so a job that starts now stops at once.
    closed: bool,
}

/// A running background job.
struct Job {
    id: String,
    owner: Arc<dyn SessionHost>,
    log: PathBuf,
    group: Pid,
    stop: CancellationToken,
    /// The label of the end, for example `exited 0`, when the job has ended.
    end: watch::Receiver<Option<String>>,
}

/// A background job that ended by itself. The consumer gives [`JobEnded::text`] to the session as an input that is not
/// from the user.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct JobEnded {
    /// The id of the job, for example `job-3`.
    pub id: String,
    /// The text for the model: the end, the log file, and the last lines of the log.
    pub text: String,
}

/// How a command ended.
#[derive(Debug, Default)]
pub(crate) struct CommandEnd {
    /// The output: stdout and stderr in the order of their writes. A cut keeps a head and a tail around a marker.
    pub(crate) output: String,
    /// The exit code, when the command exited.
    pub(crate) code: Option<i32>,
    /// The signal that ended the command, when a signal ended it.
    pub(crate) signal: Option<i32>,
    /// The deadline stopped the command.
    pub(crate) timed_out: bool,
    /// The cancel of the call stopped the command.
    pub(crate) stopped: bool,
}

/// A command in flight. A drop stops its process group.
pub(crate) struct RunningCommand {
    /// Each chunk of output, on whole UTF-8 characters.
    pub(crate) output: mpsc::UnboundedReceiver<String>,
    /// The end of the command, or the text of a failure.
    pub(crate) end: oneshot::Receiver<Result<CommandEnd, String>>,
    /// Stops the command when it drops, so a dropped call ends its command.
    #[expect(dead_code, reason = "only the drop of the guard matters: it stops the command")]
    pub(crate) stop: StopOnDrop,
}

/// Cancels its token when it drops.
pub(crate) struct StopOnDrop(pub(crate) CancellationToken);

impl Drop for StopOnDrop {
    fn drop(&mut self) {
        self.0.cancel();
    }
}

impl Processes {
    /// The processes of this tokio runtime. The full outputs and the logs go to `folder`.
    ///
    /// # Panics
    ///
    /// Panics when the caller runs outside a tokio runtime.
    pub fn new(folder: PathBuf) -> Self {
        Self::with_jobs(folder, true)
    }

    /// The processes of this tokio runtime, for a process that ends with its turn: a job start fails. The full outputs
    /// go to `folder`.
    ///
    /// # Panics
    ///
    /// Panics when the caller runs outside a tokio runtime.
    pub fn without_jobs(folder: PathBuf) -> Self {
        Self::with_jobs(folder, false)
    }

    fn with_jobs(folder: PathBuf, starts_jobs: bool) -> Self {
        Self {
            folder,
            handle: Handle::current(),
            last_number: AtomicU64::new(0),
            // A fresh `RandomState` has random keys, so its hash is a random number.
            last_job: AtomicU32::new(
                u32::try_from(RandomState::new().hash_one(0_u8) % u64::from(JOB_NUMBERS)).unwrap_or(0),
            ),
            jobs: Arc::new(Mutex::new(Jobs::default())),
            starts_jobs,
        }
    }

    /// Stop each running job: SIGTERM to its process group, then SIGKILL after a grace. Wait for the ends. Then remove
    /// the folder of the full outputs and the logs.
    ///
    /// # Errors
    ///
    /// Returns the error of the removal of the folder. A missing folder is no error.
    pub async fn shutdown(&self) -> io::Result<()> {
        let ends: Vec<_> = {
            let mut jobs = lock(&self.jobs);
            jobs.closed = true;
            jobs.running
                .iter()
                .map(|job| {
                    job.stop.cancel();
                    job.end.clone()
                })
                .collect()
        };
        for mut end in ends {
            if end.wait_for(Option::is_some).await.is_err() {
                // The task of the job has ended, so the job has ended too.
            }
        }
        match std::fs::remove_dir_all(&self.folder) {
            Err(error) if error.kind() == io::ErrorKind::NotFound => Ok(()),
            result => result,
        }
    }

    /// The next number of a full output file.
    fn next_output_number(&self) -> u64 {
        self.last_number.fetch_add(1, Ordering::Relaxed) + 1
    }

    /// A new job id: `job-` and four base-36 digits. The counter gives each id once, until it wraps after every
    /// four-digit number.
    pub(crate) fn next_job_id(&self) -> String {
        let next = self.last_job.fetch_add(1, Ordering::Relaxed).wrapping_add(1);
        format!("job-{}", base36(FIRST_JOB_NUMBER + next % JOB_NUMBERS))
    }

    /// Run `request.command` until it ends, `request.timeout` expires, or the caller cancels `request.stop`.
    /// The answer keeps at most `request.max_bytes` output bytes.
    pub(crate) fn run(&self, request: Request) -> RunningCommand {
        let (chunks, output) = mpsc::unbounded_channel();
        let (finish, end) = oneshot::channel();
        let file = self.folder.join(format!("exec-{}.log", self.next_output_number()));
        let stop = request.stop.clone();
        self.handle.spawn(async move {
            let answer = run(request, file, chunks).await;
            if finish.send(answer).is_err() {
                // The call has left.
            }
        });
        RunningCommand {
            output,
            end,
            stop: StopOnDrop(stop),
        }
    }

    /// Start `command` in the folder of `owner` as a job, and answer its id and log file. A job that ends by itself
    /// reports to `owner`. Without jobs, the start fails with a text for the model.
    pub(crate) async fn start_job(
        &self,
        command: String,
        owner: Arc<dyn SessionHost>,
    ) -> Result<(String, PathBuf), String> {
        if !self.starts_jobs {
            return Err(
                "This run ends with its turn, so it cannot start a background job. Run the command without background."
                    .to_owned(),
            );
        }
        if lock(&self.jobs).closed {
            return Err(SHUTTING_DOWN.to_owned());
        }
        let id = self.next_job_id();
        let log = self.folder.join(format!("{id}.log"));
        let folder = owner.folder().to_owned();
        let (task_id, task_log) = (id.clone(), log.clone());
        let jobs = Arc::clone(&self.jobs);
        let (started_sender, started) = oneshot::channel();
        // One task on the runtime of the consumer owns the job from its spawn to its end, so a dropped call loses no
        // child.
        self.handle.spawn(async move {
            let spawn_log = task_log.clone();
            // The log file is blocking work.
            let spawned = tokio::task::spawn_blocking(move || spawn_logged(&command, &folder, &spawn_log))
                .await
                .map_err(|error| error.to_string())
                .and_then(|spawned| spawned.map_err(|error| error.to_string()));
            let (mut child, group) = match spawned {
                Ok(spawned) => spawned,
                Err(error) => {
                    answer_start(started_sender, Err(format!("the job did not start: {error}")));
                    return;
                }
            };
            let stop = CancellationToken::new();
            let (finish, end) = watch::channel(None);
            let registered = {
                let mut running = lock(&jobs);
                if !running.closed {
                    running.running.push(Job {
                        id: task_id.clone(),
                        owner: Arc::clone(&owner),
                        log: task_log.clone(),
                        group,
                        stop: stop.clone(),
                        end,
                    });
                }
                !running.closed
            };
            // A shutdown that came during the spawn found no such job, so the job ends here. The spawn made the log and
            // the folder that the shutdown removed.
            if !registered {
                if signal_group(group, Signal::KILL).is_err() {
                    // A process of the group that the kill misses ends by itself.
                }
                if child.wait().await.is_err() {
                    // The child is gone either way.
                }
                if std::fs::remove_file(&task_log).is_ok()
                    && let Some(folder) = task_log.parent()
                    && std::fs::remove_dir(folder).is_err()
                {
                    // Another file keeps the folder, and the next shutdown removes it.
                }
                answer_start(started_sender, Err(SHUTTING_DOWN.to_owned()));
                return;
            }
            answer_start(started_sender, Ok(()));
            let label = wait_job(child, group, &stop).await;
            // The removal and the check of the stop share the lock, so a stop either finds the job and silences its end
            // message, or finds no job.
            let stopped = {
                let mut running = lock(&jobs);
                running.running.retain(|job| job.id != task_id);
                stop.is_cancelled()
            };
            if finish.send(Some(label.clone())).is_err() {
                // No stop waits for the end.
            }
            if !stopped {
                let text = end_message(&task_id, &label, task_log).await;
                owner.job_ended(JobEnded { id: task_id, text });
            }
        });
        started
            .await
            .map_err(|_| "the job did not start: the runtime of yuke ended".to_owned())??;
        Ok((id, log))
    }

    /// Stop the running job `id` of `owner` and answer how it ended and its log, or `None` when `owner` runs no such
    /// job. A stopped job sends no end message.
    pub(crate) async fn stop_job(&self, id: &str, owner: &Arc<dyn SessionHost>) -> Option<(String, PathBuf)> {
        let (mut end, log) = {
            let jobs = lock(&self.jobs);
            let job = jobs
                .running
                .iter()
                .find(|job| job.id == id && Arc::ptr_eq(&job.owner, owner))?;
            job.stop.cancel();
            (job.end.clone(), job.log.clone())
        };
        let label = match end.wait_for(Option::is_some).await {
            Ok(label) => label.clone().unwrap_or_default(),
            Err(_) => "failed".to_owned(),
        };
        Some((label, log))
    }

    /// The ids of the running jobs of `owner`.
    pub(crate) fn running_jobs(&self, owner: &Arc<dyn SessionHost>) -> Vec<String> {
        lock(&self.jobs)
            .running
            .iter()
            .filter(|job| Arc::ptr_eq(&job.owner, owner))
            .map(|job| job.id.clone())
            .collect()
    }
}

impl Drop for Processes {
    /// Kill each running job, so no job outlives the consumer. [`Processes::shutdown`] stops them with a grace first.
    /// The stop goes first, so a killed job sends no end message.
    fn drop(&mut self) {
        let mut jobs = lock(&self.jobs);
        jobs.closed = true;
        for job in &jobs.running {
            job.stop.cancel();
            if signal_group(job.group, Signal::KILL).is_err() {
                // The system refused the kill, and the consumer has nothing left to tell.
            }
        }
    }
}

/// The running jobs. A panic of another holder leaves a valid list, so a poisoned lock still serves.
fn lock(jobs: &Mutex<Jobs>) -> std::sync::MutexGuard<'_, Jobs> {
    jobs.lock().unwrap_or_else(std::sync::PoisonError::into_inner)
}

/// Answer the call that started a job. A dropped call gets no answer, and the task still owns the job.
fn answer_start(sender: oneshot::Sender<Result<(), String>>, answer: Result<(), String>) {
    if sender.send(answer).is_err() {
        // The call has left.
    }
}

/// `number` in base 36, with the digits `0-9` and `a-z`.
fn base36(mut number: u32) -> String {
    let mut digits = Vec::new();
    loop {
        digits.push(char::from_digit(number % 36, 36).unwrap_or('0'));
        number /= 36;
        if number == 0 {
            return digits.iter().rev().collect();
        }
    }
}

/// The home folder for a child when the inherited `HOME` is missing or empty: the home folder of the user in the
/// system user database. A service or a container can start yuke without `HOME`, and many tools need it.
pub(crate) fn recovered_home(inherited: Option<&OsStr>) -> Option<PathBuf> {
    match inherited {
        Some(home) if !home.is_empty() => None,
        _ => std::env::home_dir().filter(|home| home.is_absolute()),
    }
}

/// The shell that runs each command: bash when it exists, else sh.
pub fn shell() -> &'static Path {
    let bash = Path::new("/bin/bash");
    if bash.exists() { bash } else { Path::new("/bin/sh") }
}

/// The shell command for `command` in `folder`: the [`shell`]. The child leads a new session with no
/// controlling terminal, so a prompt such as the password of `ssh` fails at once instead of a read of the terminal of
/// yuke. The new session is a new process group too. The child reads no input.
#[expect(
    unsafe_code,
    reason = "the hook runs between fork and exec, where only async-signal-safe calls are sound"
)]
fn shell_command(command: &str, folder: &Path) -> Command {
    let mut shell_command = Command::new(shell());
    shell_command
        .arg("-c")
        .arg(command)
        .current_dir(folder)
        .stdin(Stdio::null());
    // SAFETY: the hook makes one system call, `setsid`, which POSIX lists as async-signal-safe, and it allocates nothing.
    unsafe {
        shell_command.pre_exec(|| match rustix::process::setsid() {
            Ok(_) => Ok(()),
            Err(error) => Err(error.into()),
        });
    }
    if let Some(home) = recovered_home(std::env::var_os("HOME").as_deref()) {
        shell_command.env("HOME", home);
    }
    shell_command
}

/// The process group that a child leads.
fn group_of(child: &Child) -> io::Result<Pid> {
    child
        .id()
        .and_then(|id| i32::try_from(id).ok())
        .and_then(Pid::from_raw)
        .ok_or_else(|| io::Error::other("the child has no process id"))
}

/// Send `signal` to `group`. A group with no process left counts as done.
fn signal_group(group: Pid, signal: Signal) -> io::Result<()> {
    match kill_process_group(group, signal) {
        Ok(()) => Ok(()),
        Err(error) if error == rustix::io::Errno::SRCH => Ok(()),
        Err(error) => Err(error.into()),
    }
}

/// Stop `group`: SIGTERM, then SIGKILL to each process that remains after the grace. The grace covers every process of
/// the group, not only the leader `child`. Answer the status of the leader.
async fn stop_group(group: Pid, child: &mut Child) -> io::Result<ExitStatus> {
    signal_group(group, Signal::TERM)?;
    let deadline = tokio::time::Instant::now() + GRACE;
    let Ok(status) = tokio::time::timeout_at(deadline, child.wait()).await else {
        signal_group(group, Signal::KILL)?;
        return child.wait().await;
    };
    // The wait reaped the leader, so a check finds only the other processes. They get the rest of the grace.
    while group_has_processes(group) && tokio::time::Instant::now() < deadline {
        tokio::time::sleep(GROUP_POLL).await;
    }
    signal_group(group, Signal::KILL)?;
    status
}

/// Whether `group` still holds a process. Only `ESRCH` says that it holds none. A refused check, for example of a
/// process that changed its user, still counts as a process, so the kill after the grace comes.
fn group_has_processes(group: Pid) -> bool {
    rustix::process::test_kill_process_group(group) != Err(rustix::io::Errno::SRCH)
}

/// The run of one command: start it, read its output, and stop it at the deadline or at a stop.
async fn run(request: Request, file: PathBuf, chunks: mpsc::UnboundedSender<String>) -> Result<CommandEnd, String> {
    let Request {
        command,
        folder,
        timeout,
        max_bytes,
        stop,
    } = request;
    let (reader, writer) = io::pipe().map_err(|error| format!("the command did not start: {error}"))?;
    let mut shell_command = shell_command(&command, &folder);
    let error_writer = writer
        .try_clone()
        .map_err(|error| format!("the command did not start: {error}"))?;
    // One pipe for stdout and stderr keeps the order of their writes.
    shell_command
        .stdout(Stdio::from(writer))
        .stderr(Stdio::from(error_writer));
    let mut child = shell_command
        .spawn()
        .map_err(|error| format!("the command did not start: {error}"))?;
    // The command holds the write ends. The read sees the end of the output only after they close.
    drop(shell_command);
    let group = group_of(&child).map_err(|error| error.to_string())?;

    let capture = Arc::new(Mutex::new(Capture::new(max_bytes, file)));
    let reading = {
        let capture = Arc::clone(&capture);
        tokio::task::spawn_blocking(move || read_output(reader, &capture, &chunks))
    };

    let mut end = CommandEnd::default();
    let status = tokio::select! {
        status = child.wait() => status,
        () = tokio::time::sleep(timeout) => {
            end.timed_out = true;
            stop_group(group, &mut child).await
        }
        () = stop.cancelled() => {
            end.stopped = true;
            stop_group(group, &mut child).await
        }
    }
    .map_err(|error| error.to_string())?;
    // A process that the shell left in the group ends with the call.
    signal_group(group, Signal::KILL).map_err(|error| error.to_string())?;
    // A process that left the group can hold the pipe open, so the read gets one grace and no more.
    if tokio::time::timeout(GRACE, reading).await.is_err() {
        // The output so far stays in the capture.
    }

    end.code = status.code();
    end.signal = std::os::unix::process::ExitStatusExt::signal(&status);
    // The removal of an unneeded file is blocking work.
    end.output = tokio::task::spawn_blocking(move || {
        capture
            .lock()
            .unwrap_or_else(std::sync::PoisonError::into_inner)
            .finish()
    })
    .await
    .map_err(|error| error.to_string())?;
    Ok(end)
}

/// Read the output until its end: give each chunk to `chunks` and keep it in `capture`.
fn read_output(mut reader: io::PipeReader, capture: &Mutex<Capture>, chunks: &mpsc::UnboundedSender<String>) {
    let mut buffer = vec![0; CHUNK];
    let mut partial = Vec::new();
    loop {
        let count = match reader.read(&mut buffer) {
            Ok(0) => break,
            Ok(count) => count,
            // A signal stopped the read before any byte came, so the read goes on.
            Err(error) if error.kind() == io::ErrorKind::Interrupted => continue,
            Err(_) => break,
        };
        let bytes = &buffer[..count];
        capture
            .lock()
            .unwrap_or_else(std::sync::PoisonError::into_inner)
            .add(bytes);
        partial.extend_from_slice(bytes);
        let text = whole_characters(&mut partial);
        if !text.is_empty() && chunks.send(text).is_err() {
            // The call has left. The capture still keeps the output.
        }
    }
    if !partial.is_empty() && chunks.send(String::from_utf8_lossy(&partial).into_owned()).is_err() {
        // The call has left.
    }
}

/// The text of the whole UTF-8 characters at the start of `bytes`. The bytes of a character that a read cut stay in
/// `bytes` for the next read.
pub(crate) fn whole_characters(bytes: &mut Vec<u8>) -> String {
    // Only an incomplete character at the end waits. Each invalid sequence before it becomes U+FFFD now, so the check
    // goes on past each one.
    let mut start = 0;
    let keep = loop {
        match std::str::from_utf8(&bytes[start..]) {
            Ok(_) => break 0,
            Err(error) => match error.error_len() {
                Some(invalid) => start += error.valid_up_to() + invalid,
                None => break bytes.len() - start - error.valid_up_to(),
            },
        }
    };
    let rest = bytes.split_off(bytes.len() - keep);
    let text = String::from_utf8_lossy(bytes).into_owned();
    *bytes = rest;
    text
}

/// The kept output of a command: a head, a tail, and the full output in a file.
struct Capture {
    head: Vec<u8>,
    tail: VecDeque<u8>,
    head_room: usize,
    tail_room: usize,
    cut: u64,
    path: PathBuf,
    file: Option<File>,
    /// A create or a write of the file failed. The file then stays incomplete, so no marker names it.
    file_failed: bool,
}

impl Capture {
    fn new(max_bytes: usize, path: PathBuf) -> Self {
        let tail_room = max_bytes / 2;
        Self {
            head: Vec::new(),
            tail: VecDeque::new(),
            head_room: max_bytes - tail_room,
            tail_room,
            cut: 0,
            path,
            file: None,
            file_failed: false,
        }
    }

    /// Keep `bytes`: the head first, then a tail that drops its oldest bytes. Each byte also goes to the file, until a
    /// write of the file fails.
    fn add(&mut self, bytes: &[u8]) {
        self.write_file(bytes);
        let to_head = bytes.len().min(self.head_room - self.head.len());
        self.head.extend_from_slice(&bytes[..to_head]);
        self.tail.extend(&bytes[to_head..]);
        let over = self.tail.len().saturating_sub(self.tail_room);
        self.tail.drain(..over);
        self.cut += over as u64;
    }

    /// Write `bytes` to the full output file. A failed file costs the file, not the command.
    fn write_file(&mut self, bytes: &[u8]) {
        if self.file_failed {
            return;
        }
        if self.file.is_none() {
            let opened = self
                .path
                .parent()
                .map_or(Ok(()), std::fs::create_dir_all)
                .and_then(|()| File::create(&self.path));
            let Ok(file) = opened else {
                self.file_failed = true;
                return;
            };
            self.file = Some(file);
        }
        if let Some(file) = &mut self.file
            && file.write_all(bytes).is_err()
        {
            self.file_failed = true;
        }
    }

    /// The output: whole when nothing was cut, else the head, a marker, and the tail. A command without a cut keeps no
    /// file.
    fn finish(&mut self) -> String {
        let mut tail: Vec<u8> = self.tail.iter().copied().collect();
        if self.cut == 0 {
            if self.file.take().is_some() && std::fs::remove_file(&self.path).is_err() {
                // The folder of the consumer keeps the file until the consumer removes the folder.
            }
            // The head and the tail are one text, so a character across their border stays whole.
            let mut whole = std::mem::take(&mut self.head);
            whole.append(&mut tail);
            return String::from_utf8_lossy(&whole).into_owned();
        }
        // The cut drops a character that crosses an end of the cut, not its bytes one by one.
        let head_end = match std::str::from_utf8(&self.head) {
            Err(error) if error.error_len().is_none() => error.valid_up_to(),
            _ => self.head.len(),
        };
        let tail_start = tail
            .iter()
            .take_while(|byte| *byte & 0b1100_0000 == 0b1000_0000)
            .count();
        let head = String::from_utf8_lossy(&self.head[..head_end]);
        let tail = String::from_utf8_lossy(&tail[tail_start..]);
        let file = if self.file.is_some() && !self.file_failed {
            format!(
                "Full output: {}. Read it with offset and limit, or run grep with exec.",
                self.path.display()
            )
        } else {
            "yuke kept no copy of the full output.".to_owned()
        };
        format!("{head}\n[yuke cut {} bytes here. {file}]\n{tail}", self.cut)
    }
}

/// Start `command` in `folder` with its output in the file `log`, in a new process group.
fn spawn_logged(command: &str, folder: &Path, log: &Path) -> io::Result<(Child, Pid)> {
    if let Some(parent) = log.parent() {
        std::fs::create_dir_all(parent)?;
    }
    let output = File::create(log)?;
    let mut shell_command = shell_command(command, folder);
    shell_command
        .stdout(Stdio::from(output.try_clone()?))
        .stderr(Stdio::from(output));
    let child = shell_command.spawn()?;
    let group = group_of(&child)?;
    Ok((child, group))
}

/// Wait for the end of a job, or stop it. Answer the label of the end, for example `exited 0` or `stopped`.
async fn wait_job(mut child: Child, group: Pid, stop: &CancellationToken) -> String {
    let (status, stopped) = tokio::select! {
        status = child.wait() => (status, false),
        () = stop.cancelled() => (stop_group(group, &mut child).await, true),
    };
    if signal_group(group, Signal::KILL).is_err() {
        // A process of the group that the kill misses ends by itself.
    }
    match status {
        Ok(_) if stopped => "stopped".to_owned(),
        Ok(status) => match (status.code(), std::os::unix::process::ExitStatusExt::signal(&status)) {
            (Some(code), _) => format!("exited {code}"),
            (None, Some(signal)) => format!("signal {signal}"),
            (None, None) => "failed".to_owned(),
        },
        Err(_) => "failed".to_owned(),
    }
}

/// The end message of a job for the model: the end, the log file, and the last lines of the log.
async fn end_message(id: &str, label: &str, log: PathBuf) -> String {
    let shown = log.display().to_string();
    let tail = tokio::task::spawn_blocking(move || last_lines(&log))
        .await
        .ok()
        .and_then(Result::ok)
        .filter(|tail| !tail.is_empty())
        .unwrap_or_else(|| "[no output]".to_owned());
    format!("[{id} {label}. This message is not from the user.]\nLog: {shown}\n{tail}")
}

/// The last lines of the file at `path`, from its last 8 KiB.
fn last_lines(path: &Path) -> io::Result<String> {
    let mut file = File::open(path)?;
    let length = file.metadata()?.len();
    file.seek(SeekFrom::Start(length.saturating_sub(8 * 1024)))?;
    let mut bytes = Vec::new();
    file.read_to_end(&mut bytes)?;
    let text = String::from_utf8_lossy(&bytes);
    let lines: Vec<&str> = text.trim_end().lines().collect();
    Ok(lines[lines.len().saturating_sub(TAIL_LINES)..].join("\n"))
}
