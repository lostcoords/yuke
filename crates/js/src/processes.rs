//! The child processes of the tools: the commands of `exec` and the process jobs. Their tasks run on the host runtime,
//! and every JavaScript runtime shares one `Processes`, so a process job outlives a reload of the JavaScript.

use std::collections::{BTreeMap, VecDeque};
use std::ffi::OsStr;
use std::fmt;
use std::fs::File;
use std::hash::{BuildHasher, RandomState};
use std::io::{self, Read, Seek, SeekFrom, Write};
use std::os::fd::OwnedFd;
use std::path::{Path, PathBuf};
use std::process::{ExitStatus, Stdio};
use std::sync::atomic::{AtomicU32, AtomicU64, Ordering};
use std::sync::{Arc, Mutex};
use std::time::Duration;

use rquickjs::{FromJs, IntoJs};
use rustix::process::{Pid, Signal, kill_process_group};
use tokio::io::AsyncReadExt;
use tokio::net::unix::pipe::Receiver;
use tokio::process::{Child, Command};
use tokio::sync::{mpsc, oneshot};
use tokio::task::JoinHandle;
use yuke_engine::CancellationToken;
use yuke_protocol::{JobKind, JobState};

use crate::jobs::{Jobs, RunningJob, report_input};
use crate::tools::SessionHost;

/// The plugin name of the input that a background job sends when it ends.
const JOBS_SOURCE: &str = "host:jobs";

/// The job numbers with four base-36 digits: from `1000` to `zzzz`.
const FIRST_JOB_NUMBER: u32 = 36 * 36 * 36;
const JOB_NUMBERS: u32 = 36 * 36 * 36 * 36 - FIRST_JOB_NUMBER;

/// The answer to a call whose task ended without an answer.
const ENDED: &str = "the command did not start: the runtime of yuke ended";

/// The time between SIGTERM and SIGKILL when a process group stops.
const GRACE: Duration = Duration::from_secs(2);

/// The wait between two checks for a process that remains in a stopping group.
const GROUP_POLL: Duration = Duration::from_millis(20);

/// The bytes that one read of the output takes.
const CHUNK: usize = 64 * 1024;

/// The lines of the log that the report of a job shows.
const TAIL_LINES: usize = 20;

/// The parameters for one command call.
pub(crate) struct Request {
    pub(crate) command: String,
    pub(crate) folder: PathBuf,
    pub(crate) timeout: Duration,
    pub(crate) max_bytes: usize,
    /// The token that stops the command.
    pub(crate) stop: CancellationToken,
    /// The session of the command. Its background request moves the command to a job.
    pub(crate) owner: Arc<dyn SessionHost>,
}

/// The child processes of the tools. Run commands on a local tokio runtime with I/O and time. Give the same value to
/// every JavaScript runtime of the process. The full outputs of the commands and the logs of the jobs go to `folder`.
/// [`Processes::shutdown`] removes the folder.
pub struct Processes {
    folder: PathBuf,
    last_number: AtomicU64,
    /// The counter of the job ids. It starts at a random number, so an id in the transcript of an earlier process
    /// rarely names a job of this one.
    last_job: AtomicU32,
    jobs: Jobs,
}

impl fmt::Debug for Processes {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.debug_struct("Processes")
            .field("folder", &self.folder)
            .finish_non_exhaustive()
    }
}

/// How a command ended.
#[derive(Debug)]
pub(crate) struct CommandEnd {
    /// The output: stdout and stderr in the order of their writes. A cut keeps a head and a tail around a marker.
    pub(crate) output: String,
    /// Why the command ended.
    pub(crate) cause: EndCause,
}

/// Why a command ended. A stop by yuke wins over the exit status that the stop caused.
#[derive(Debug)]
pub(crate) enum EndCause {
    /// The command exited with this code.
    Exit(i32),
    /// This signal ended the command.
    Signal(i32),
    /// The deadline stopped the command.
    Timeout,
    /// The cancel of the call stopped the command.
    Cancelled,
    /// A background request moved the running command to the job `id`, with its output in the file `log`.
    Moved { id: String, log: PathBuf },
}

impl Processes {
    /// Create process state. The full outputs and the logs go to `folder`.
    pub fn new(folder: PathBuf) -> Self {
        Self::with_jobs(folder, true)
    }

    /// Create process state for a process that ends with its turn: a background job start fails. The full outputs go to `folder`.
    pub fn without_jobs(folder: PathBuf) -> Self {
        Self::with_jobs(folder, false)
    }

    fn with_jobs(folder: PathBuf, starts_jobs: bool) -> Self {
        Self {
            folder,
            last_number: AtomicU64::new(0),
            // A fresh `RandomState` has random keys, so its hash is a random number.
            last_job: AtomicU32::new(
                u32::try_from(RandomState::new().hash_one(0_u8) % u64::from(JOB_NUMBERS)).unwrap_or(0),
            ),
            jobs: Jobs::new(starts_jobs),
        }
    }

    /// Stop each running job, and wait for the ends. A process group gets SIGTERM, then SIGKILL after a grace. Then remove
    /// the folder of the full outputs and the logs.
    ///
    /// # Errors
    ///
    /// Returns the error of the removal of the folder. A missing folder is no error.
    pub async fn shutdown(&self) -> io::Result<()> {
        self.jobs.shutdown().await;
        match std::fs::remove_dir_all(&self.folder) {
            Err(error) if error.kind() == io::ErrorKind::NotFound => Ok(()),
            result => result,
        }
    }

    /// The jobs of each session.
    pub fn jobs(&self) -> &Jobs {
        &self.jobs
    }

    /// A new job id: `job-` and four base-36 digits. The counter gives each id once, until it wraps after every
    /// four-digit number.
    pub(crate) fn next_job_id(&self) -> String {
        let next = self.last_job.fetch_add(1, Ordering::Relaxed).wrapping_add(1);
        format!("job-{}", base36(FIRST_JOB_NUMBER + next % JOB_NUMBERS))
    }

    /// Run `request.command` until it ends, `request.timeout` expires, the caller cancels `request.stop`, or a background
    /// request moves it to a job. Each chunk in `chunks` holds whole UTF-8 characters. The answer keeps at most
    /// `request.max_bytes` output bytes. A dropped wait stops a command that has not moved.
    pub(crate) async fn run(
        &self,
        request: Request,
        chunks: mpsc::UnboundedSender<String>,
    ) -> Result<CommandEnd, String> {
        let Request {
            command,
            folder,
            timeout,
            max_bytes,
            stop,
            owner,
        } = request;
        let number = self.last_number.fetch_add(1, Ordering::Relaxed) + 1;
        let log = self.folder.join(format!("exec-{number}.log"));
        let id = self.next_job_id();
        let label = short_command(&command);
        let job = self.jobs.add_process(
            owner.as_ref(),
            id.clone(),
            label.clone(),
            command.clone(),
            log.clone(),
            true,
        )?;
        // A dropped call stops a command that it waits for.
        let _guard = stop.clone().drop_guard();
        let (answer, answered) = oneshot::channel();
        let task = CommandTask {
            job,
            label,
            command,
            log: log.clone(),
            folder,
            owner,
        };
        let mode = Mode::InCall {
            max_bytes,
            chunks,
            deadline: tokio::time::Instant::now() + timeout,
            stop,
        };
        tokio::task::spawn_local(task.run(mode, answer));
        match answered.await.map_err(|_| ENDED.to_owned())?? {
            Answer::Ended(end) => Ok(end),
            Answer::Running => Ok(CommandEnd {
                output: String::new(),
                cause: EndCause::Moved { id, log },
            }),
        }
    }

    /// Run `program` until it ends, and answer its end and its output. A cancel of `stop` stops its process group:
    /// SIGTERM, then SIGKILL after a grace. A dropped wait stops it too.
    pub(crate) async fn output(&self, program: Program, stop: CancellationToken) -> Result<ProgramEnd, String> {
        // The runtime of the processes drives the pipes of the child. A dropped wait cancels `stop`.
        let _guard = stop.clone().drop_guard();
        tokio::task::spawn_local(run_program(program, stop))
            .await
            .map_err(|error| error.to_string())?
    }

    /// Start `command` in the folder of `owner` as a job, which ends after `timeout` when it has one. A job that ends by
    /// itself reports to `owner`. Without jobs, the start fails with a text for the model.
    pub(crate) async fn start_job(
        &self,
        command: String,
        timeout: Option<Duration>,
        owner: Arc<dyn SessionHost>,
    ) -> Result<StartedJob, String> {
        let id = self.next_job_id();
        let log = self.folder.join(format!("{id}.log"));
        let label = short_command(&command);
        let job = self.jobs.add_process(
            owner.as_ref(),
            id.clone(),
            label.clone(),
            command.clone(),
            log.clone(),
            false,
        )?;
        let (answer, answered) = oneshot::channel();
        let task = CommandTask {
            job,
            label: label.clone(),
            command,
            log: log.clone(),
            folder: owner.folder(),
            owner,
        };
        tokio::task::spawn_local(task.run(Mode::Job { timeout }, answer));
        answered.await.map_err(|_| ENDED.to_owned())??;
        Ok(StartedJob {
            id,
            label,
            log: log.to_string_lossy().into_owned(),
        })
    }
}

/// How a command starts.
enum Mode {
    /// A call waits for the command, until a background request moves it.
    InCall {
        max_bytes: usize,
        chunks: mpsc::UnboundedSender<String>,
        deadline: tokio::time::Instant,
        stop: CancellationToken,
    },
    /// The command runs as a job from its start. It keeps no output in memory.
    Job { timeout: Option<Duration> },
}

/// What the task of a command answers its call.
enum Answer {
    /// The command ended in its call.
    Ended(CommandEnd),
    /// The command runs on as a job.
    Running,
}

/// The task of one command. It owns the process and its entry in the job list from the spawn to the delivery of the end,
/// so a close and a shutdown wait for the whole command, and a dropped call loses no child.
struct CommandTask {
    job: RunningJob,
    label: String,
    command: String,
    log: PathBuf,
    folder: PathBuf,
    owner: Arc<dyn SessionHost>,
}

impl CommandTask {
    async fn run(self, mode: Mode, answer: oneshot::Sender<Result<Answer, String>>) {
        let (max_bytes, chunks) = match &mode {
            Mode::InCall { max_bytes, chunks, .. } => (*max_bytes, chunks.clone()),
            Mode::Job { .. } => (0, mpsc::unbounded_channel().0),
        };
        let spawned = start_command(
            self.command.clone(),
            self.folder.clone(),
            self.log.clone(),
            max_bytes,
            chunks,
        )
        .await;
        let mut running = match spawned {
            Ok(running) => running,
            Err(error) => {
                let text = match mode {
                    Mode::InCall { .. } => format!("the command did not start: {error}"),
                    Mode::Job { .. } => format!("the job did not start: {error}"),
                };
                reply(answer, Err(text));
                return;
            }
        };
        // Before the first wait, so a drop of the job list kills each process.
        self.job.set_group(Some(running.group));
        let timeout = match mode {
            Mode::Job { timeout } => timeout,
            Mode::InCall { deadline, stop, .. } => {
                let (status, stopped) = tokio::select! {
                    // The job list accepted a move, so the entry already counts as a job. Nothing else can win.
                    biased;
                    () = self.job.moved.cancelled() => {
                        self.show_running(&running);
                        reply(answer, Ok(Answer::Running));
                        // A person moved this command because it runs long, so its timeout ends here.
                        return self.wait(running, None).await;
                    }
                    status = running.child.wait() => (status, None),
                    () = tokio::time::sleep_until(deadline) => {
                        (stop_group(running.group, &mut running.child).await, Some(EndCause::Timeout))
                    }
                    () = stop.cancelled() => {
                        (stop_group(running.group, &mut running.child).await, Some(EndCause::Cancelled))
                    }
                    () = self.job.stop.cancelled() => {
                        (stop_group(running.group, &mut running.child).await, Some(EndCause::Cancelled))
                    }
                };
                reply(
                    answer,
                    finish_in_call(running, status, stopped).await.map(Answer::Ended),
                );
                return;
            }
        };
        self.show_running(&running);
        reply(answer, Ok(Answer::Running));
        self.wait(running, timeout).await;
    }

    /// Show the job with its process. The log gets its file, so its path is valid before the first output.
    fn show_running(&self, running: &Running) {
        running
            .capture
            .lock()
            .unwrap_or_else(std::sync::PoisonError::into_inner)
            .write_file(&[]);
        self.owner.job_changed(self.protocol_job(JobState::Running, None));
    }

    /// Wait for the end of the process, a stop, or `timeout`, and deliver the end.
    async fn wait(self, mut running: Running, timeout: Option<Duration>) {
        let deadline = tokio::time::Instant::now() + timeout.unwrap_or_default();
        let (status, stopped, timed_out) = tokio::select! {
            // A stop can end the process at once, so both can be ready, and the stop must win.
            biased;
            () = self.job.stop.cancelled() => (stop_group(running.group, &mut running.child).await, true, false),
            () = tokio::time::sleep_until(deadline), if timeout.is_some() => {
                (stop_group(running.group, &mut running.child).await, false, true)
            }
            status = running.child.wait() => (status, false, false),
        };
        running.finish_read().await;
        let status = status.ok();
        let exit_code = status.and_then(|status| status.code());
        // A process that ended by itself sends its report, also when a close came after the end. A stop of this one
        // job sends none.
        let silenced = self.job.set_group(None);
        let state = if stopped { JobState::Stopped } else { JobState::Ended };
        self.owner.job_changed(self.protocol_job(state, exit_code));
        if !stopped && !silenced {
            let signal = status.and_then(|status| std::os::unix::process::ExitStatusExt::signal(&status));
            let end = match (exit_code, signal, timeout.filter(|_| timed_out)) {
                (_, _, Some(timeout)) => format!("timed out after {} ms", timeout.as_millis()),
                (Some(code), _, None) => format!("exited {code}"),
                (None, Some(signal), None) => format!("signal {signal}"),
                (None, None, None) => "failed".to_owned(),
            };
            let text = end_text(self.log.clone()).await;
            let input = report_input(JOBS_SOURCE, &self.job.id, &end, &text);
            self.owner.accept_input(input).await;
        }
    }

    /// The job in `state`, for its owner.
    fn protocol_job(&self, state: JobState, exit_code: Option<i32>) -> yuke_protocol::Job {
        yuke_protocol::Job {
            id: self.job.id.clone(),
            label: self.label.clone(),
            state,
            kind: JobKind::Process {
                command: self.command.clone(),
                log: self.log.clone(),
                exit_code,
            },
        }
    }
}

/// Give a call its answer. A dropped call gets no answer, and the task still owns the command.
fn reply(answer: oneshot::Sender<Result<Answer, String>>, value: Result<Answer, String>) {
    if answer.send(value).is_err() {
        // The call has left.
    }
}

/// What a job start gives: the id of the job, its label, and its log file.
#[derive(IntoJs)]
pub(crate) struct StartedJob {
    id: String,
    label: String,
    log: String,
}

/// The first line of `command`, at most 60 characters.
fn short_command(command: &str) -> String {
    let text = command.trim();
    let (line, more) = text.split_once('\n').map_or((text, false), |(line, _)| (line, true));
    if more || line.chars().count() > 60 {
        format!("{}...", line.chars().take(57).collect::<String>())
    } else {
        line.to_owned()
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

/// The shell command for `command` in `folder`: the [`shell`] in a new session. The child reads no input.
fn shell_command(command: &str, folder: &Path) -> Command {
    let mut shell_command = Command::new(shell());
    shell_command
        .arg("-c")
        .arg(command)
        .current_dir(folder)
        .stdin(Stdio::null());
    new_session(&mut shell_command);
    if let Some(home) = recovered_home(std::env::var_os("HOME").as_deref()) {
        shell_command.env("HOME", home);
    }
    shell_command
}

/// Make the child of `command` lead a new session with no controlling terminal, so a prompt such as the password of
/// `ssh` fails at once instead of a read of the terminal of yuke. The new session is a new process group too.
#[expect(
    unsafe_code,
    reason = "the hook runs between fork and exec, where only async-signal-safe calls are sound"
)]
fn new_session(command: &mut Command) {
    // SAFETY: the hook makes one system call, `setsid`, which POSIX lists as async-signal-safe, and it allocates nothing.
    unsafe {
        command.pre_exec(|| match rustix::process::setsid() {
            Ok(_) => Ok(()),
            Err(error) => Err(error.into()),
        });
    }
}

/// A program of a plugin, with its arguments and without a shell.
#[derive(Debug, FromJs)]
#[qjs(rename_all = "camelCase")]
pub(crate) struct Program {
    /// The program: a name that the `PATH` finds, or a path.
    pub(crate) command: String,
    pub(crate) args: Vec<String>,
    /// The absolute folder of the program.
    pub(crate) cwd: String,
    /// The environment variables beside the environment of yuke, or in place of it with `clear_env`.
    pub(crate) env: BTreeMap<String, String>,
    pub(crate) clear_env: bool,
    /// Whether the answer keeps stdout, and stderr. A stream that it does not keep goes to the null device.
    pub(crate) stdout: bool,
    pub(crate) stderr: bool,
}

/// How a program ended, and its output.
#[derive(Debug)]
pub(crate) struct ProgramEnd {
    /// The exit code, or 128 and the number of the signal that ended the program.
    pub(crate) code: i32,
    /// The name of the signal that ended the program, such as `SIGTERM`.
    pub(crate) signal: Option<&'static str>,
    pub(crate) stdout: Vec<u8>,
    pub(crate) stderr: Vec<u8>,
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
pub(crate) fn signal_group(group: Pid, signal: Signal) -> io::Result<()> {
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
    kill_rest_of_group(group);
    status
}

/// Kill each process that remains in `group` after the wait reaped its leader. macOS can refuse this kill with `EPERM`
/// although no process of the group remains, so a refusal is no failure: a process that the kill misses ends by itself.
fn kill_rest_of_group(group: Pid) {
    if signal_group(group, Signal::KILL).is_err() {
        // A refused kill leaves nothing that the caller can do.
    }
}

/// Whether `group` still holds a process. Only `ESRCH` says that it holds none. A refused check, for example of a
/// process that changed its user, still counts as a process, so the kill after the grace comes.
fn group_has_processes(group: Pid) -> bool {
    rustix::process::test_kill_process_group(group) != Err(rustix::io::Errno::SRCH)
}

/// The run of one program: start it, read stdout and stderr at once, and stop its group at a stop. After the exit, the
/// read waits for the end of each stream, as a process that the program left can still write.
async fn run_program(program: Program, stop: CancellationToken) -> Result<ProgramEnd, String> {
    let piped = |keep: bool| if keep { Stdio::piped() } else { Stdio::null() };
    let mut command = Command::new(&program.command);
    command
        .args(&program.args)
        .current_dir(&program.cwd)
        .stdin(Stdio::null())
        .stdout(piped(program.stdout))
        .stderr(piped(program.stderr));
    if program.clear_env {
        command.env_clear();
    } else if let Some(home) = recovered_home(std::env::var_os("HOME").as_deref()) {
        command.env("HOME", home);
    }
    command.envs(program.env);
    new_session(&mut command);
    let mut child = spawn(command)
        .await
        .map_err(|error| format!("{} did not start: {error}", program.command))?;
    let group = group_of(&child).map_err(|error| error.to_string())?;
    let (stdout, stderr) = (child.stdout.take(), child.stderr.take());
    let mut reading = tokio::spawn(async move { tokio::try_join!(read_all(stdout), read_all(stderr)) });
    let status = tokio::select! {
        status = child.wait() => status,
        () = stop.cancelled() => stop_group(group, &mut child).await,
    }
    .map_err(|error| error.to_string())?;
    // A process that the program left in its group can hold a stream open. A stop ends it, so the read ends too.
    let read = tokio::select! {
        read = &mut reading => read,
        () = stop.cancelled() => {
            kill_rest_of_group(group);
            reading.await
        }
    };
    let (stdout, stderr) = read
        .map_err(|error| error.to_string())?
        .map_err(|error| format!("the output of {} did not read: {error}", program.command))?;
    let signal = std::os::unix::process::ExitStatusExt::signal(&status);
    let code = match (status.code(), signal) {
        (Some(code), _) => code,
        (None, Some(signal)) => 128 + signal,
        (None, None) => return Err(format!("{} ended without an exit code or a signal", program.command)),
    };
    Ok(ProgramEnd {
        code,
        signal: signal.and_then(signal_name),
        stdout,
        stderr,
    })
}

/// Each byte of `pipe` until its end, or nothing without a pipe.
async fn read_all(pipe: Option<impl tokio::io::AsyncRead + Unpin>) -> io::Result<Vec<u8>> {
    let mut bytes = Vec::new();
    if let Some(mut pipe) = pipe {
        pipe.read_to_end(&mut bytes).await?;
    }
    Ok(bytes)
}

/// The name of the signal with the number `number` on this system, as Deno names it.
fn signal_name(number: i32) -> Option<&'static str> {
    const NAMES: [(Signal, &str); 29] = [
        (Signal::HUP, "SIGHUP"),
        (Signal::INT, "SIGINT"),
        (Signal::QUIT, "SIGQUIT"),
        (Signal::ILL, "SIGILL"),
        (Signal::TRAP, "SIGTRAP"),
        (Signal::ABORT, "SIGABRT"),
        (Signal::BUS, "SIGBUS"),
        (Signal::FPE, "SIGFPE"),
        (Signal::KILL, "SIGKILL"),
        (Signal::USR1, "SIGUSR1"),
        (Signal::SEGV, "SIGSEGV"),
        (Signal::USR2, "SIGUSR2"),
        (Signal::PIPE, "SIGPIPE"),
        (Signal::ALARM, "SIGALRM"),
        (Signal::TERM, "SIGTERM"),
        (Signal::CHILD, "SIGCHLD"),
        (Signal::CONT, "SIGCONT"),
        (Signal::STOP, "SIGSTOP"),
        (Signal::TSTP, "SIGTSTP"),
        (Signal::TTIN, "SIGTTIN"),
        (Signal::TTOU, "SIGTTOU"),
        (Signal::URG, "SIGURG"),
        (Signal::XCPU, "SIGXCPU"),
        (Signal::XFSZ, "SIGXFSZ"),
        (Signal::VTALARM, "SIGVTALRM"),
        (Signal::PROF, "SIGPROF"),
        (Signal::WINCH, "SIGWINCH"),
        (Signal::IO, "SIGIO"),
        (Signal::SYS, "SIGSYS"),
    ];
    NAMES
        .iter()
        .find(|(signal, _)| signal.as_raw() == number)
        .map(|(_, name)| *name)
}

/// A started command: its process, and the read of its output, which goes on when the command moves to a job.
struct Running {
    child: Child,
    group: Pid,
    reading: JoinHandle<io::Result<()>>,
    capture: Arc<Mutex<Capture>>,
}

impl Running {
    /// End each process that the shell left in the group, and wait for the read. A process that left the group can hold
    /// the pipe open, so the read gets one grace and no more. After the grace the output so far stays in the capture.
    /// Answer the read when it ended in the grace.
    async fn finish_read(&mut self) -> Option<Result<io::Result<()>, tokio::task::JoinError>> {
        kill_rest_of_group(self.group);
        let read = tokio::time::timeout(GRACE, &mut self.reading).await.ok();
        if read.is_none() {
            self.reading.abort();
        }
        read
    }
}

/// Start `command` in `folder`. Its output goes to `chunks` and to a capture of `max_bytes` with the file `file`.
async fn start_command(
    command: String,
    folder: PathBuf,
    file: PathBuf,
    max_bytes: usize,
    chunks: mpsc::UnboundedSender<String>,
) -> io::Result<Running> {
    let (reader, writer) = io::pipe()?;
    let mut shell_command = shell_command(&command, &folder);
    let error_writer = writer.try_clone()?;
    // One pipe for stdout and stderr keeps the order of their writes.
    shell_command
        .stdout(Stdio::from(writer))
        .stderr(Stdio::from(error_writer));
    let child = spawn(shell_command).await?;
    let group = group_of(&child)?;
    let capture = Arc::new(Mutex::new(Capture::new(max_bytes, file)));
    let reader = Receiver::from_owned_fd(OwnedFd::from(reader))?;
    let reading = tokio::spawn(read_output(reader, Arc::clone(&capture), chunks));
    Ok(Running {
        child,
        group,
        reading,
        capture,
    })
}

/// The end of a command that ended in its call, with the status `status` of its process.
async fn finish_in_call(
    mut running: Running,
    status: io::Result<ExitStatus>,
    stopped: Option<EndCause>,
) -> Result<CommandEnd, String> {
    let status = status.map_err(|error| error.to_string())?;
    if let Some(read) = running.finish_read().await {
        read.map_err(|error| error.to_string())?
            .map_err(|error| format!("the output of the command did not read: {error}"))?;
    }
    let cause = match (
        stopped,
        status.code(),
        std::os::unix::process::ExitStatusExt::signal(&status),
    ) {
        (Some(cause), _, _) => cause,
        (None, Some(code), _) => EndCause::Exit(code),
        (None, None, Some(signal)) => EndCause::Signal(signal),
        (None, None, None) => return Err("the command ended without an exit code or a signal".to_owned()),
    };
    let capture = running.capture;
    // The removal of an unneeded file is blocking work.
    let output = tokio::task::spawn_blocking(move || {
        capture
            .lock()
            .unwrap_or_else(std::sync::PoisonError::into_inner)
            .finish()
    })
    .await
    .map_err(|error| error.to_string())?;
    Ok(CommandEnd { output, cause })
}

/// Read the output until its end: give each chunk to `chunks` and keep it in `capture`. The wait for output uses no thread.
async fn read_output(
    mut reader: Receiver,
    capture: Arc<Mutex<Capture>>,
    chunks: mpsc::UnboundedSender<String>,
) -> io::Result<()> {
    let mut buffer = vec![0; CHUNK];
    let mut partial = Vec::new();
    loop {
        let count = reader.read(&mut buffer).await?;
        if count == 0 {
            break;
        }
        let bytes = buffer[..count].to_vec();
        let keep = Arc::clone(&capture);
        // The write of the file is blocking work.
        tokio::task::spawn_blocking(move || {
            keep.lock()
                .unwrap_or_else(std::sync::PoisonError::into_inner)
                .add(&bytes);
        })
        .await
        .map_err(io::Error::other)?;
        // A job has no reader of its chunks.
        if chunks.is_closed() {
            continue;
        }
        partial.extend_from_slice(&buffer[..count]);
        // Only an incomplete character at the end waits for the next read.
        let (text, rest) = crate::bytes::decode(&partial, false, true).unwrap_or_default();
        partial.drain(..partial.len() - rest);
        if !text.is_empty() && chunks.send(text).is_err() {
            // The call has left. The capture still keeps the output.
        }
    }
    if !partial.is_empty() && chunks.send(String::from_utf8_lossy(&partial).into_owned()).is_err() {
        // The call has left.
    }
    Ok(())
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

/// Spawn `command` on a blocking thread, because the spawn forks and waits until the child calls exec. The command
/// drops after the spawn. So its copies of the pipe write ends close, and a read of the output sees the end.
async fn spawn(mut command: Command) -> io::Result<Child> {
    tokio::task::spawn_blocking(move || command.spawn())
        .await
        .map_err(io::Error::other)?
}

/// The text of the report of a process job: the log file and the last lines of the log.
async fn end_text(log: PathBuf) -> String {
    let shown = log.display().to_string();
    let tail = tokio::task::spawn_blocking(move || last_lines(&log))
        .await
        .ok()
        .and_then(Result::ok)
        .filter(|tail| !tail.is_empty())
        .unwrap_or_else(|| "[no output]".to_owned());
    format!("Log: {shown}\n{tail}")
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
