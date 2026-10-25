//! The `yuke` program. It has three modes: the terminal interface (no mode flag), the protocol server (`--rpc`), and
//! one task with no view (`-p`). The terminal interface does not exist yet. `--rpc` serves stdin and stdout.
//! `--rpc --listen` serves a Unix socket. `--rpc --connect` joins stdin and stdout to such a socket. `-p` writes the
//! answer to stdout, and the end of the turn picks the exit status. `yuke login` logs in to a provider, and
//! `yuke logout` removes the login.

mod app;
mod auth;
mod config;
mod paths;
mod plugins;
mod print;
mod prompt;
mod providers;
mod rpc;
mod skills;
#[cfg(test)]
mod testing;
mod tui;

use std::io::{self, Write};
use std::path::PathBuf;
use std::process::ExitCode;
use std::sync::Arc;
use std::time::Duration;

use clap::{Parser, Subcommand};

use tokio::signal::unix::{Signal, SignalKind, signal};
use yuke_ai::oauth::PendingLogin;
use yuke_engine::{CancellationToken, Outcome, TurnEnd, chain_text};
use yuke_protocol::SessionId;

use crate::app::{Machine, warn};
use crate::paths::Paths;
use crate::print::{Finished, Reasoning, SessionChoice, Task};
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
    /// Remove the stored login of PROVIDER from auth.json. yuke revokes no token at the provider, and a running server
    /// keeps a token of credential/update.
    Logout {
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
    /// A removal of the saved login of a provider.
    Logout(String),
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
        match self.command {
            Some(Command::Login { provider }) => return Mode::Login(provider),
            Some(Command::Logout { provider }) => return Mode::Logout(provider),
            None => {}
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
            reasoning: self.reasoning,
            session: match (self.session, self.continue_newest) {
                (Some(id), _) => SessionChoice::Id(id),
                (None, true) => SessionChoice::Newest,
                (None, false) => SessionChoice::New,
            },
        };

        Mode::Print { task, json: self.json }
    }
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
        let ran = match Cli::parse().into_mode() {
            Mode::Tui => run_tui().await,
            Mode::Rpc { listen } => serve_rpc(listen).await,
            Mode::Connect(path) => rpc::connect(&path, tokio::io::stdin(), tokio::io::stdout())
                .await
                .map(|()| ExitCode::SUCCESS),
            Mode::Print { task, json } => print_task(&task, json).await,
            Mode::Login(provider) => login(&provider).await,
            Mode::Logout(provider) => logout(&provider).await,
        };
        ran.unwrap_or_else(|error| {
            warn(&error);
            ExitCode::FAILURE
        })
    });
    // A read of stdin blocks a thread that nothing can stop, and a normal shutdown waits for that thread.
    runtime.shutdown_background();
    code
}

/// Run `task`, write its answer or its `--json` report, and answer the exit status.
async fn print_task(task: &Task, json: bool) -> Result<ExitCode, String> {
    let cancellation_token = CancellationToken::new();
    match run_until_signal(run_here(task, cancellation_token.clone()), &cancellation_token).await? {
        Signaled::Ended(finished, signal_number) => {
            let finished = finished?;
            write_output(&finished, json).map_err(|error| format!("the output did not write: {error}"))?;
            if let TurnEnd::Failed(error) = &finished.end
                && !json
            {
                warn(error);
            }
            Ok(exit_code(&finished.end, signal_number))
        }
        Signaled::Stopped(number) => Ok(signal_exit(number)),
    }
}

/// Log in to the provider `id`.
async fn login(id: &str) -> Result<ExitCode, String> {
    let machine = machine()?;
    let providers = Providers::load(&machine.paths.config)?;
    let (provider, flow) = providers.login(id)?;
    let mut signals = Signals::new()?;
    let show = |pending: &PendingLogin| {
        warn(&format!(
            "open {} and confirm the code {} (enter it if the page asks)",
            pending.verification_url, pending.user_code
        ));
    };
    let logged_in = auth::login(id, flow, machine.paths.data.clone(), &*machine.exchange, show);
    tokio::select! {
        result = logged_in => {
            result.map_err(|error| chain_text(&error))?;
            warn(&format!("logged in to {}", provider.name));
            Ok(ExitCode::SUCCESS)
        }
        number = signals.next() => Ok(signal_exit(number)),
    }
}

/// Remove the stored login of the provider `id` from `auth.json`. A running server keeps the token of
/// `credential/update` and finishes its logins.
async fn logout(id: &str) -> Result<ExitCode, String> {
    let machine = machine()?;
    let providers = Providers::load(&machine.paths.config)?;
    let provider = providers
        .iter()
        .find(|provider| provider.id == id)
        .ok_or_else(|| format!("yuke has no provider {id}"))?;
    auth::logout(id, machine.paths.data.clone())
        .await
        .map_err(|error| chain_text(&error))?;
    warn(&format!("logged out of {}", provider.name));
    Ok(ExitCode::SUCCESS)
}

/// Serve the protocol on the Unix socket at `listen`, or else on stdin and stdout. A signal ends each server, and the
/// end of stdin ends the server on stdin and stdout. A signal exits with 128 plus its number.
async fn serve_rpc(listen: Option<PathBuf>) -> Result<ExitCode, String> {
    let shutdown = CancellationToken::new();
    let served = async {
        let machine = machine()?;
        let clients = match listen {
            Some(path) => rpc::Clients::Socket(rpc::Socket::bind(&path)?),
            None => rpc::Clients::One(rpc::Stream::new(tokio::io::stdin(), tokio::io::stdout())),
        };
        rpc::serve(machine, DRAIN_LIMIT, clients, shutdown.clone().cancelled_owned()).await
    };
    match run_until_signal(served, &shutdown).await? {
        Signaled::Ended(ended, signal_number) => {
            ended?;
            Ok(signal_number.map_or(ExitCode::SUCCESS, signal_exit))
        }
        Signaled::Stopped(number) => Ok(signal_exit(number)),
    }
}

/// Run the terminal interface until a quit or a signal.
async fn run_tui() -> Result<ExitCode, String> {
    let shutdown = CancellationToken::new();
    match run_until_signal(tui::run(machine()?, shutdown.clone()), &shutdown).await? {
        Signaled::Ended(ended, signal_number) => {
            ended?;
            Ok(signal_number.map_or(ExitCode::SUCCESS, signal_exit))
        }
        Signaled::Stopped(number) => Ok(signal_exit(number)),
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
    let options = yuke_http::ClientOptions::new(concat!("yuke/", env!("YUKE_VERSION")));
    let http = Arc::new(yuke_http::Client::new(options.clone()).map_err(|error| chain_text(&error))?);
    let fetch = yuke_http::Client::new(yuke_http::ClientOptions {
        idle_timeout: None,
        ..options
    })
    .map_err(|error| chain_text(&error))?;
    Ok(Machine {
        paths,
        home,
        variable: Box::new(|name| std::env::var_os(name)),
        transport: Arc::clone(&http) as Arc<dyn yuke_ai::transport::Transport>,
        exchange: http,
        fetch: Arc::new(fetch),
        display: None,
    })
}

/// Write the answer, or the `--json` report, to stdout.
fn write_output(finished: &Finished, json: bool) -> io::Result<()> {
    let mut stdout = io::stdout().lock();
    if json {
        serde_json::to_writer(&mut stdout, finished)?;
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
        (TurnEnd::Outcome(Outcome::Cancelled), Some(number)) => signal_exit(number),
        (TurnEnd::Outcome(Outcome::Cancelled), None) | (TurnEnd::Failed(_), _) => ExitCode::FAILURE,
    }
}

/// The exit status after the signal `number`: `128 + number`, as the Unix shells give.
fn signal_exit(number: u8) -> ExitCode {
    ExitCode::from(128 + number)
}

/// The termination signals: SIGINT, SIGTERM, and SIGHUP. The handlers start at the creation, and they replace the
/// default exit for the rest of the process.
struct Signals {
    interrupt: Signal,
    terminate: Signal,
    hangup: Signal,
}

impl Signals {
    fn new() -> Result<Self, String> {
        let failure = |error: io::Error| format!("the signal handlers did not start: {error}");
        Ok(Self {
            interrupt: signal(SignalKind::interrupt()).map_err(failure)?,
            terminate: signal(SignalKind::terminate()).map_err(failure)?,
            hangup: signal(SignalKind::hangup()).map_err(failure)?,
        })
    }

    /// Wait for the next signal, and answer its number.
    async fn next(&mut self) -> u8 {
        tokio::select! {
            _ = self.interrupt.recv() => 2,
            _ = self.terminate.recv() => 15,
            _ = self.hangup.recv() => 1,
        }
    }
}

/// How an operation under the termination signals ended.
#[derive(Debug)]
enum Signaled<T> {
    /// The operation ended with its output, after the signal of the number when there was one.
    Ended(T, Option<u8>),
    /// A second signal of the number stopped the operation before its end.
    Stopped(u8),
}

/// Run `operation` to its end. The first termination signal cancels `cancellation_token`, and `operation` still runs
/// to its end. A second signal drops `operation`: the user stops an end that does not come, such as a cleanup of a
/// plugin that waits forever.
///
/// # Errors
///
/// Returns a text for the user when the signal handlers do not start.
async fn run_until_signal<T>(
    operation: impl Future<Output = T>,
    cancellation_token: &CancellationToken,
) -> Result<Signaled<T>, String> {
    let mut signals = Signals::new()?;
    tokio::pin!(operation);
    let number = tokio::select! {
        output = &mut operation => return Ok(Signaled::Ended(output, None)),
        number = signals.next() => number,
    };
    cancellation_token.cancel();
    Ok(tokio::select! {
        output = operation => Signaled::Ended(output, Some(number)),
        again = signals.next() => Signaled::Stopped(again),
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

    #[tokio::test]
    async fn a_second_signal_stops_an_operation_that_does_not_end() {
        let cancellation_token = CancellationToken::new();
        let send = async {
            for _ in 0..2 {
                tokio::time::sleep(Duration::from_millis(50)).await;
                let pid = std::process::id().to_string();
                let sent = std::process::Command::new("kill").args(["-HUP", &pid]).status();
                assert!(sent.unwrap().success());
            }
        };

        let (ran, ()) = tokio::join!(
            run_until_signal(std::future::pending::<()>(), &cancellation_token),
            send
        );

        assert!(matches!(ran, Ok(Signaled::Stopped(1))), "{ran:?}");
        assert!(cancellation_token.is_cancelled());
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
                    reasoning: Some(Reasoning::Xhigh),
                    session: SessionChoice::Newest,
                },
                json: true,
            })
        );
        let Ok(Mode::Print { task, .. }) = mode(&["-p", "Hi.", "--reasoning", "default"]) else {
            panic!("no print mode");
        };
        assert_eq!(task.reasoning, Some(Reasoning::Default));
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
    fn logout_takes_one_provider_and_no_mode_flag() {
        assert_eq!(mode(&["logout", "xai-grok"]), Ok(Mode::Logout("xai-grok".to_owned())));
        assert_eq!(mode(&["logout"]), Err(ErrorKind::MissingRequiredArgument));
        assert_eq!(mode(&["--rpc", "logout", "xai-grok"]), Err(ErrorKind::ArgumentConflict));
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
