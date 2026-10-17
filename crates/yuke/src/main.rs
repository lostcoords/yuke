//! The `yuke` program. It has three modes: the terminal interface (no mode flag), the protocol server (`--rpc`), and
//! one task with no view (`-p`). The terminal interface does not exist yet. `--rpc` serves stdin and stdout.
//! `--rpc --listen` serves a Unix socket. `--rpc --connect` joins stdin and stdout to such a socket. `-p` writes the
//! answer to stdout, and the end of the turn picks the exit status. `yuke login` logs in to a provider.

mod app;
mod auth;
mod config;
mod paths;
mod plugins;
mod print;
mod prompt;
mod providers;
mod rpc;
#[cfg(test)]
mod testing;

use std::io::{self, Write};
use std::path::{Path, PathBuf};
use std::process::ExitCode;
use std::sync::Arc;
use std::time::Duration;

use clap::{Parser, Subcommand, ValueEnum};
use serde::Serialize;
use tokio::signal::unix::{SignalKind, signal};
use yuke_ai::Effort;
use yuke_ai::catalog::ReasoningLevel;
use yuke_ai::oauth::PendingLogin;
use yuke_engine::{CancellationToken, Outcome, TurnEnd};
use yuke_protocol::SessionId;

use crate::app::{Machine, describe, warn};
use crate::paths::Paths;
use crate::print::{Finished, ReasoningChoice, SessionChoice, Task};
use crate::providers::Providers;

/// The longest wait of `yuke --rpc` for the client to read the last messages after the end of its input.
const DRAIN_LIMIT: Duration = Duration::from_secs(5);

/// The command line of `yuke`.
#[derive(Debug, Parser)]
#[command(
    name = "yuke",
    version = env!("YUKE_VERSION"),
    about = "A coding agent. Run one task with -p or serve the protocol with --rpc.",
    args_conflicts_with_subcommands = true
)]
struct Cli {
    #[command(subcommand)]
    command: Option<Command>,

    /// Run one task with PROMPT. Print the last answer, then exit.
    #[arg(short = 'p', long = "print", value_name = "PROMPT", value_parser = clap::builder::NonEmptyStringValueParser::new())]
    prompt: Option<String>,

    /// Serve the yuke protocol on stdin and stdout.
    // Clap does not check `requires` beside a conflicting flag, so `--rpc` names each print flag.
    #[arg(long, conflicts_with_all = ["prompt", "json", "model", "reasoning", "session", "continue_newest"])]
    rpc: bool,

    /// Serve the clients of a Unix socket, one at a time. The sessions outlive each client.
    #[arg(long, value_name = "unix://PATH", value_parser = socket_path, requires = "rpc", conflicts_with = "connect")]
    listen: Option<PathBuf>,

    /// Join stdin and stdout to the server of a Unix socket.
    #[arg(long, value_name = "unix://PATH", value_parser = socket_path, requires = "rpc")]
    connect: Option<PathBuf>,

    /// Print one JSON object: the session id, the end of the turn, and the text of the last answer.
    #[arg(long, requires = "prompt")]
    json: bool,

    /// The model, as provider/model. A new session needs it.
    #[arg(long, value_name = "PROVIDER/MODEL", requires = "prompt")]
    model: Option<String>,

    /// The reasoning choice. A new session needs it, and so does --model on a continued session.
    #[arg(long, value_enum, requires = "prompt")]
    reasoning: Option<Reasoning>,

    /// Continue the session with this id.
    #[arg(long, value_name = "ID", conflicts_with = "continue_newest", requires = "prompt")]
    session: Option<SessionId>,

    /// Continue the session of the current folder with the newest event.
    #[arg(short = 'c', long = "continue", requires = "prompt")]
    continue_newest: bool,
}

/// A command of `yuke`.
#[derive(Debug, Subcommand)]
enum Command {
    /// Log in to PROVIDER, and save the grant.
    Login {
        /// The provider id, the first part of --model, such as xai-grok.
        provider: String,
    },
}

/// What the program runs.
#[derive(Debug, PartialEq)]
enum Mode {
    /// The terminal interface.
    Tui,
    /// The protocol server on the Unix socket at `listen`, or else on stdin and stdout.
    Rpc { listen: Option<PathBuf> },
    /// The bridge from stdin and stdout to the server of the Unix socket at this path.
    Connect(PathBuf),
    /// One task with no view. `json` prints the `--json` report.
    Print { task: Task, json: bool },
    /// A login to a provider.
    Login(String),
}

/// The path of a `unix://PATH` value.
fn socket_path(value: &str) -> Result<PathBuf, String> {
    match value.strip_prefix("unix://") {
        Some(path) if !path.is_empty() => Ok(PathBuf::from(path)),
        _ => Err("use unix://PATH".to_owned()),
    }
}

impl Cli {
    /// The mode that the flags name.
    fn into_mode(self) -> Mode {
        if let Some(Command::Login { provider }) = self.command {
            return Mode::Login(provider);
        }
        if self.rpc {
            return match self.connect {
                Some(path) => Mode::Connect(path),
                None => Mode::Rpc { listen: self.listen },
            };
        }

        let Some(prompt) = self.prompt else {
            return Mode::Tui;
        };

        let task = Task {
            prompt,
            model: self.model,
            reasoning: self.reasoning.map(ReasoningChoice::from),
            session: match (self.session, self.continue_newest) {
                (Some(id), _) => SessionChoice::Id(id),
                (None, true) => SessionChoice::Newest,
                (None, false) => SessionChoice::New,
            },
        };

        Mode::Print { task, json: self.json }
    }
}

/// A reasoning choice on the command line.
#[derive(Debug, Clone, Copy, ValueEnum)]
enum Reasoning {
    /// Send no reasoning control, so the endpoint chooses the level.
    Default,
    Off,
    Minimal,
    Low,
    Medium,
    High,
    Xhigh,
    Max,
}

impl From<Reasoning> for ReasoningChoice {
    fn from(reasoning: Reasoning) -> Self {
        let effort = |effort| ReasoningChoice::Level(ReasoningLevel::Effort(effort));
        match reasoning {
            Reasoning::Default => ReasoningChoice::Endpoint,
            Reasoning::Off => ReasoningChoice::Level(ReasoningLevel::Off),
            Reasoning::Minimal => effort(Effort::Minimal),
            Reasoning::Low => effort(Effort::Low),
            Reasoning::Medium => effort(Effort::Medium),
            Reasoning::High => effort(Effort::High),
            Reasoning::Xhigh => effort(Effort::Xhigh),
            Reasoning::Max => effort(Effort::Max),
        }
    }
}

/// The `--json` output.
#[derive(Debug, Serialize)]
#[serde(rename_all = "camelCase")]
struct Report<'a> {
    session_id: SessionId,
    end: &'a TurnEnd,
    text: &'a str,
}

fn main() -> ExitCode {
    let runtime = match tokio::runtime::Builder::new_current_thread().enable_all().build() {
        Ok(runtime) => runtime,
        Err(error) => {
            warn(&format!("yuke could not start its runtime: {error}"));
            return ExitCode::FAILURE;
        }
    };
    let code = runtime.block_on(async {
        match Cli::parse().into_mode() {
            Mode::Tui => not_implemented("the terminal interface"),
            Mode::Rpc { listen } => serve_rpc(listen).await,
            Mode::Connect(path) => connect(&path).await,
            Mode::Print { task, json } => print_task(&task, json).await,
            Mode::Login(provider) => login(&provider).await,
        }
    });
    // A read of stdin blocks a thread that nothing can stop, and a normal shutdown waits for that thread.
    runtime.shutdown_background();
    code
}

/// Tell the user that `mode` does not exist yet.
fn not_implemented(mode: &str) -> ExitCode {
    warn(&format!(
        "{mode} is not implemented yet. Run one task with -p <prompt>."
    ));
    ExitCode::FAILURE
}

/// Run `task`, write its answer or its `--json` report, and answer the exit status.
async fn print_task(task: &Task, json: bool) -> ExitCode {
    let cancellation_token = CancellationToken::new();
    let ran = run_until_signal(run_here(task, cancellation_token.clone()), &cancellation_token).await;
    match ran {
        Ok((Ok(finished), signal_number)) => {
            if let Err(error) = write_output(&finished, json) {
                warn(&format!("the output did not write: {error}"));
                return ExitCode::FAILURE;
            }
            if let TurnEnd::Failed(error) = &finished.end
                && !json
            {
                warn(error);
            }
            exit_code(&finished.end, signal_number)
        }
        Ok((Err(error), _)) | Err(error) => {
            warn(&error);
            ExitCode::FAILURE
        }
    }
}

/// Log in to the provider `id`.
async fn login(id: &str) -> ExitCode {
    let found = machine().and_then(|machine| {
        let providers = Providers::load(&machine.paths.config)?;
        Ok((machine, providers))
    });
    let (machine, providers) = match found {
        Ok(found) => found,
        Err(error) => {
            warn(&error);
            return ExitCode::FAILURE;
        }
    };
    let (provider, flow) = match providers.login(id) {
        Ok(found) => found,
        Err(error) => {
            warn(&error);
            return ExitCode::FAILURE;
        }
    };
    let signals = match termination_signal() {
        Ok(signals) => signals,
        Err(error) => {
            warn(&error);
            return ExitCode::FAILURE;
        }
    };
    let show = |pending: &PendingLogin| {
        warn(&format!(
            "open {} and confirm the code {} (enter it if the page asks)",
            pending.verification_url, pending.user_code
        ));
    };
    let logged_in = auth::login(id, flow, machine.paths.data.clone(), &*machine.exchange, show);
    tokio::select! {
        result = logged_in => match result {
            Ok(()) => {
                warn(&format!("logged in to {}", provider.name));
                ExitCode::SUCCESS
            }
            Err(error) => {
                warn(&describe(&error));
                ExitCode::FAILURE
            }
        },
        number = signals => ExitCode::from(128 + number),
    }
}

/// Serve the protocol on the Unix socket at `listen`, or else on stdin and stdout. A signal ends each server, and the
/// end of stdin ends the server on stdin and stdout. A signal exits with 128 plus its number.
async fn serve_rpc(listen: Option<PathBuf>) -> ExitCode {
    let shutdown = CancellationToken::new();
    let served = async {
        let machine = machine()?;
        let clients = match listen {
            Some(path) => rpc::Clients::Socket(rpc::Socket::bind(&path)?),
            None => rpc::Clients::One(rpc::Stream::new(tokio::io::stdin(), tokio::io::stdout())),
        };
        rpc::serve(machine, DRAIN_LIMIT, clients, shutdown.clone().cancelled_owned()).await
    };
    match run_until_signal(served, &shutdown).await {
        Ok((Ok(()), Some(number))) => ExitCode::from(128 + number),
        Ok((Ok(()), None)) => ExitCode::SUCCESS,
        Ok((Err(error), _)) | Err(error) => {
            warn(&error);
            ExitCode::FAILURE
        }
    }
}

/// Join stdin and stdout to the server of the Unix socket at `path`, until the server closes the connection.
async fn connect(path: &Path) -> ExitCode {
    match rpc::connect(path, tokio::io::stdin(), tokio::io::stdout()).await {
        Ok(()) => ExitCode::SUCCESS,
        Err(error) => {
            warn(&error);
            ExitCode::FAILURE
        }
    }
}

/// Run `task` on this machine, in the current folder.
async fn run_here(task: &Task, cancellation_token: CancellationToken) -> Result<Finished, String> {
    let machine = machine()?;
    let cwd = std::env::current_dir()
        .and_then(std::fs::canonicalize)
        .map_err(|error| format!("the current folder: {error}"))?;
    print::run(task, machine, &cwd, cancellation_token).await
}

/// The facts of this machine: its environment, its folders, and an HTTP transport.
fn machine() -> Result<Machine, String> {
    let home = std::env::home_dir().filter(|home| home.is_absolute());
    let paths = Paths::of(&|name| std::env::var_os(name), home.as_deref())?;
    let http = yuke_ai::HttpTransport::new(yuke_ai::HttpOptions::new(concat!("yuke/", env!("YUKE_VERSION"))))
        .map_err(|error| describe(&error))?;
    let http = Arc::new(http);
    Ok(Machine {
        paths,
        home,
        variable: Box::new(|name| std::env::var_os(name)),
        transport: Arc::clone(&http) as Arc<dyn yuke_ai::transport::Transport>,
        exchange: http,
    })
}

/// Write the answer, or the `--json` report, to stdout.
fn write_output(finished: &Finished, json: bool) -> io::Result<()> {
    let mut stdout = io::stdout().lock();
    if json {
        let report = Report {
            session_id: finished.session,
            end: &finished.end,
            text: &finished.text,
        };
        serde_json::to_writer(&mut stdout, &report)?;
        writeln!(stdout)?;
    } else if !finished.text.is_empty() {
        writeln!(stdout, "{}", finished.text)?;
    }
    stdout.flush()
}

/// The exit status of a turn that ended with `end`. A cancel by a signal exits with 128 plus its number.
fn exit_code(end: &TurnEnd, signal_number: Option<u8>) -> ExitCode {
    match (end, signal_number) {
        (TurnEnd::Outcome(Outcome::Completed { .. } | Outcome::Stopped), _) => ExitCode::SUCCESS,
        (TurnEnd::Outcome(Outcome::Cancelled), Some(number)) => ExitCode::from(128 + number),
        (TurnEnd::Outcome(Outcome::Cancelled), None) | (TurnEnd::Failed(_), _) => ExitCode::FAILURE,
    }
}

/// Wait for the first SIGINT, SIGTERM, or SIGHUP, and answer its number. The handlers start at the call.
fn termination_signal() -> Result<impl Future<Output = u8>, String> {
    let failure = |error: io::Error| format!("the signal handlers did not start: {error}");
    let mut interrupt = signal(SignalKind::interrupt()).map_err(failure)?;
    let mut terminate = signal(SignalKind::terminate()).map_err(failure)?;
    let mut hangup = signal(SignalKind::hangup()).map_err(failure)?;
    Ok(async move {
        tokio::select! {
            _ = interrupt.recv() => 2,
            _ = terminate.recv() => 15,
            _ = hangup.recv() => 1,
        }
    })
}

/// Run `operation` to its end. The first termination signal cancels `cancellation_token`, and `operation` still runs
/// to its end. Answer its output and the number of the signal.
///
/// # Errors
///
/// Returns a text for the user when the signal handlers do not start.
async fn run_until_signal<T>(
    operation: impl Future<Output = T>,
    cancellation_token: &CancellationToken,
) -> Result<(T, Option<u8>), String> {
    let signals = termination_signal()?;
    tokio::pin!(operation, signals);
    Ok(tokio::select! {
        output = &mut operation => (output, None),
        number = &mut signals => {
            cancellation_token.cancel();
            (operation.await, Some(number))
        }
    })
}

#[cfg(test)]
mod tests {
    use clap::CommandFactory;
    use clap::error::ErrorKind;

    use super::*;

    fn mode(arguments: &[&str]) -> Result<Mode, ErrorKind> {
        Cli::try_parse_from(std::iter::once("yuke").chain(arguments.iter().copied()))
            .map(Cli::into_mode)
            .map_err(|error| error.kind())
    }

    #[test]
    fn the_command_line_definition_is_consistent() {
        Cli::command().debug_assert();
    }

    #[test]
    fn no_mode_flag_starts_the_terminal_interface_and_rpc_starts_the_server() {
        assert_eq!(mode(&[]), Ok(Mode::Tui));
        assert_eq!(mode(&["--rpc"]), Ok(Mode::Rpc { listen: None }));
    }

    #[test]
    fn listen_and_connect_take_a_unix_path_and_need_rpc() {
        let path = PathBuf::from("/run/yuke.sock");
        assert_eq!(
            mode(&["--rpc", "--listen", "unix:///run/yuke.sock"]),
            Ok(Mode::Rpc {
                listen: Some(path.clone())
            })
        );
        assert_eq!(
            mode(&["--rpc", "--connect", "unix:///run/yuke.sock"]),
            Ok(Mode::Connect(path))
        );
        for flag in ["--listen", "--connect"] {
            assert_eq!(
                mode(&[flag, "unix:///a"]),
                Err(ErrorKind::MissingRequiredArgument),
                "{flag}"
            );
            assert_eq!(mode(&["--rpc", flag, "/a"]), Err(ErrorKind::ValueValidation), "{flag}");
            assert_eq!(
                mode(&["--rpc", flag, "unix://"]),
                Err(ErrorKind::ValueValidation),
                "{flag}"
            );
        }
        assert_eq!(
            mode(&["--rpc", "--listen", "unix:///a", "--connect", "unix:///a"]),
            Err(ErrorKind::ArgumentConflict)
        );
    }

    #[test]
    fn print_takes_its_flags_into_the_task() {
        assert_eq!(
            mode(&["-p", "Hi.", "--json", "-c", "--model", "a/b", "--reasoning", "xhigh"]),
            Ok(Mode::Print {
                task: Task {
                    prompt: "Hi.".to_owned(),
                    model: Some("a/b".to_owned()),
                    reasoning: Some(ReasoningChoice::Level(ReasoningLevel::Effort(Effort::Xhigh))),
                    session: SessionChoice::Newest,
                },
                json: true,
            })
        );
        let Ok(Mode::Print { task, .. }) = mode(&["-p", "Hi.", "--reasoning", "default"]) else {
            panic!("no print mode");
        };
        assert_eq!(task.reasoning, Some(ReasoningChoice::Endpoint));
    }

    #[test]
    fn login_takes_one_provider_and_no_mode_flag() {
        assert_eq!(mode(&["login", "xai-grok"]), Ok(Mode::Login("xai-grok".to_owned())));
        assert_eq!(mode(&["login"]), Err(ErrorKind::MissingRequiredArgument));
        assert_eq!(mode(&["--rpc", "login", "xai-grok"]), Err(ErrorKind::ArgumentConflict));
        assert_eq!(
            mode(&["-p", "Hi.", "login", "xai-grok"]),
            Err(ErrorKind::ArgumentConflict)
        );
    }

    #[test]
    fn rpc_with_a_print_flag_is_a_conflict_and_each_print_flag_needs_print() {
        assert_eq!(mode(&["--rpc", "-p", "Hi."]), Err(ErrorKind::ArgumentConflict));
        for flag in [&["--json"][..], &["--model", "a/b"], &["--reasoning", "off"], &["-c"]] {
            assert_eq!(mode(flag), Err(ErrorKind::MissingRequiredArgument), "{flag:?}");
            assert_eq!(
                mode(&[&["--rpc"][..], flag].concat()),
                Err(ErrorKind::ArgumentConflict),
                "{flag:?}"
            );
        }
        let id = SessionId::generate().to_string();
        assert_eq!(mode(&["--session", &id]), Err(ErrorKind::MissingRequiredArgument));
    }
}
