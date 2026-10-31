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
mod test_files;
#[cfg(test)]
mod testing;
mod tui;

use std::io::{self, IsTerminal, Write};
use std::path::PathBuf;
use std::process::ExitCode;
use std::sync::Arc;
use std::time::Duration;

use clap::{Parser, Subcommand};

use tokio::signal::unix::{Signal, SignalKind, signal};
use yuke_ai::oauth::PendingLogin;
use yuke_engine::{CancellationToken, Outcome, TurnEnd, chain_text};
use yuke_protocol::{PluginLog, PluginState, PluginTarget, SessionId};

use crate::app::{Machine, warn};
use crate::paths::Paths;
use crate::plugins::manager;
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
    #[arg(long, value_name = "ID", conflicts_with = "continue_newest")]
    session: Option<SessionId>,

    /// Continue the session of the current folder with the newest event.
    #[arg(short = 'c', long = "continue")]
    continue_newest: bool,
}

/// A command of `yuke`.
#[derive(Debug, PartialEq, Subcommand)]
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
    /// Run the tests of yuke:test in the *.test.ts files at PATHS, or below the current folder. Each test runs in its
    /// own app with a fake model.
    Test {
        /// Test files, or folders that hold them.
        paths: Vec<PathBuf>,
    },
    /// Install, update, and list the Git plugins of config.json. Their commits are in plugins.lock.
    Plugin {
        #[command(subcommand)]
        command: PluginCommand,
    },
}

/// A command of `yuke plugin`.
#[derive(Debug, PartialEq, Subcommand)]
enum PluginCommand {
    /// Show each plugin of config.json, its locked commit, and whether it is installed. It uses no network.
    List,
    /// Install the commits of plugins.lock, and lock each new Git plugin at the commit of its ref.
    Sync {
        /// Fail when plugins.lock does not match config.json, and never write plugins.lock.
        #[arg(long)]
        locked: bool,
    },
    /// Move Git plugins to the newest commit of their ref. It shows the log of each move and asks before it writes
    /// plugins.lock.
    #[command(group(clap::ArgGroup::new("plugins").required(true).args(["all", "names"])))]
    Update {
        /// Update every Git plugin.
        #[arg(long)]
        all: bool,
        /// The plugins to update, by the name of their plugin.json.
        #[arg(value_name = "NAME")]
        names: Vec<String>,
        /// Write plugins.lock with no question.
        #[arg(long)]
        yes: bool,
    },
}

/// What the program runs.
#[derive(Debug, PartialEq)]
enum Mode {
    /// The terminal interface. Its start pane shows the session of the choice.
    Tui(SessionChoice),
    /// The protocol server on the Unix socket at `listen`, or else on stdin and stdout.
    Rpc { listen: Option<PathBuf> },
    /// The bridge from stdin and stdout to the server of the Unix socket at this path.
    Connect(PathBuf),
    /// One task with no view. `json` prints the `--json` report.
    Print { task: Task, json: bool },
}

/// The path of a `unix://PATH` value.
fn socket_path(value: &str) -> Result<PathBuf, String> {
    match value.strip_prefix("unix://") {
        Some(path) if !path.is_empty() => Ok(PathBuf::from(path)),
        _ => Err("use unix://PATH".to_owned()),
    }
}

impl Cli {
    /// The mode that the flags name. A command runs in place of a mode.
    fn into_mode(self) -> Mode {
        if self.rpc {
            return match self.connect {
                Some(path) => Mode::Connect(path),
                None => Mode::Rpc { listen: self.listen },
            };
        }

        let session = match (self.session, self.continue_newest) {
            (Some(id), _) => SessionChoice::Id(id),
            (None, true) => SessionChoice::Newest,
            (None, false) => SessionChoice::New,
        };
        let Some(prompt) = self.prompt else {
            return Mode::Tui(session);
        };

        let task = Task {
            prompt,
            model: self.model,
            reasoning: self.reasoning,
            session,
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
        let mut cli = Cli::parse();
        let ran = match cli.command.take() {
            Some(Command::Login { provider }) => login(&provider).await,
            Some(Command::Logout { provider }) => logout(&provider).await,
            Some(Command::Test { paths }) => test(paths).await,
            Some(Command::Plugin { command }) => plugin(command).await,
            None => match cli.into_mode() {
                Mode::Tui(session) => run_tui(session).await,
                Mode::Rpc { listen } => serve_rpc(listen).await,
                Mode::Connect(path) => rpc::connect(&path, tokio::io::stdin(), tokio::io::stdout())
                    .await
                    .map(|()| ExitCode::SUCCESS),
                Mode::Print { task, json } => print_task(&task, json).await,
            },
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

/// Run the test files at `paths`, or below the current folder. Print each failure and a count, and fail when a test
/// fails.
async fn test(paths: Vec<PathBuf>) -> Result<ExitCode, String> {
    let paths = if paths.is_empty() {
        vec![PathBuf::from(".")]
    } else {
        paths
    };
    let files = test_files::collect(&paths)?;
    if files.is_empty() {
        return Err("no *.test.ts file found".to_owned());
    }
    let work = std::env::temp_dir().join(format!("yuke-test-{}", std::process::id()));
    std::fs::create_dir_all(&work).map_err(|error| format!("{}: {error}", work.display()))?;
    let summary = test_files::run(&files, &work, test_files::TIME_LIMIT, false).await;
    if let Err(error) = std::fs::remove_dir_all(&work) {
        warn(&format!("{}: {error}", work.display()));
    }
    let mut stdout = io::stdout().lock();
    write!(stdout, "{}", summary.failures)
        .and_then(|()| writeln!(stdout, "{} passed, {} failed", summary.passed, summary.failed))
        .map_err(|error| format!("the output did not write: {error}"))?;
    Ok(if summary.failed == 0 {
        ExitCode::SUCCESS
    } else {
        ExitCode::FAILURE
    })
}

/// The folders of yuke that the environment names, and the home folder of the user.
fn environment_paths() -> Result<(Paths, Option<PathBuf>), String> {
    let home = std::env::home_dir().filter(|home| home.is_absolute());
    let paths = Paths::of(&|name| std::env::var_os(name), home.as_deref())?;
    Ok((paths, home))
}

/// Run the `yuke plugin` command `command`, and print its result.
async fn plugin(command: PluginCommand) -> Result<ExitCode, String> {
    let (paths, _) = environment_paths()?;
    let say =
        |text: &str| writeln!(io::stdout(), "{text}").map_err(|error| format!("the output did not write: {error}"));
    let short = |commit: &str| commit[..7].to_owned();
    match command {
        PluginCommand::List => {
            for plugin in manager::list(&paths, &[])? {
                let state = match &plugin.state {
                    PluginState::Local => "local".to_owned(),
                    PluginState::NotLocked => "not locked: run `yuke plugin sync`".to_owned(),
                    PluginState::NotInstalled { commit } => {
                        format!("{} not installed: run `yuke plugin sync`", short(commit))
                    }
                    PluginState::Installed { commit } => short(commit),
                };
                say(&format!(
                    "{}  {}  {state}",
                    plugin.name.as_deref().unwrap_or("?"),
                    plugin.item
                ))?;
            }
        }
        PluginCommand::Sync { locked } => {
            let synced = manager::sync(&paths, locked).await?;
            for plugin in &synced.plugins {
                say(&format!("{}  {}", plugin.source, short(&plugin.commit)))?;
            }
            say(if synced.written {
                "plugins.lock written: run /reload in open sessions"
            } else {
                "plugins.lock unchanged"
            })?;
        }
        PluginCommand::Update { all, names, yes } => {
            // The question needs a terminal, so a run without one stops before any change.
            if !yes && !io::stdin().is_terminal() {
                return Err(
                    "update asks before it writes plugins.lock: run it in a terminal, or pass --yes".to_owned(),
                );
            }
            let target = if all {
                PluginTarget::All
            } else {
                PluginTarget::Names(names)
            };
            let changes = manager::check(&paths, &target).await?;
            if changes.is_empty() {
                say("each plugin is at the newest commit of its ref")?;
                return Ok(ExitCode::SUCCESS);
            }
            for change in &changes {
                say(&format!(
                    "{}  {} → {}",
                    change.name,
                    short(&change.old),
                    short(&change.new)
                ))?;
                match &change.log {
                    PluginLog::Commits(lines) => lines.iter().try_for_each(|line| say(&format!("  {line}")))?,
                    PluginLog::Error(error) => say(&format!("  no log: {error}"))?,
                }
            }
            if !yes && !confirm("Apply? [y/N] ")? {
                say("plugins.lock unchanged")?;
                return Ok(ExitCode::SUCCESS);
            }
            manager::apply(&paths, &changes).await?;
            say("plugins.lock written: run /reload in open sessions")?;
        }
    }
    Ok(ExitCode::SUCCESS)
}

/// Ask `question` on the terminal. Gives whether the answer is yes.
fn confirm(question: &str) -> Result<bool, String> {
    let fail = |error: io::Error| format!("the question did not work: {error}");
    // The question goes to stderr, so the user sees it when stdout goes to a file.
    let mut stderr = io::stderr();
    write!(stderr, "{question}")
        .and_then(|()| stderr.flush())
        .map_err(fail)?;
    let mut answer = String::new();
    io::stdin().read_line(&mut answer).map_err(fail)?;
    Ok(matches!(answer.trim().to_ascii_lowercase().as_str(), "y" | "yes"))
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
            result.map_err(|error| error.to_string())?;
            warn(&format!("logged in to {}", provider.name));
            Ok(ExitCode::SUCCESS)
        }
        number = signals.next() => Ok(signal_exit(number)),
    }
}

/// Remove the stored login or API key of the provider `id` from `auth.json`. A running server keeps the token of
/// `credential/update` and finishes its logins.
async fn logout(id: &str) -> Result<ExitCode, String> {
    let machine = machine()?;
    let providers = Providers::load(&machine.paths.config)?;
    let provider = providers.get(id)?;
    auth::logout(id, machine.paths.data.clone())
        .await
        .map_err(|error| error.to_string())?;
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

/// Run the terminal interface until a quit or a signal. Its start pane shows the session of `session`.
async fn run_tui(session: SessionChoice) -> Result<ExitCode, String> {
    let shutdown = CancellationToken::new();
    match run_until_signal(tui::run(machine()?, session, shutdown.clone()), &shutdown).await? {
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
    let (paths, home) = environment_paths()?;
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
        interface: None,
        test: None,
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

    fn parse(arguments: &[&str]) -> Result<Cli, ErrorKind> {
        Cli::try_parse_from(std::iter::once("yuke").chain(arguments.iter().copied())).map_err(|error| error.kind())
    }

    fn mode(arguments: &[&str]) -> Result<Mode, ErrorKind> {
        parse(arguments).map(Cli::into_mode)
    }

    fn command(arguments: &[&str]) -> Result<Option<Command>, ErrorKind> {
        parse(arguments).map(|cli| cli.command)
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
        assert_eq!(mode(&[]), Ok(Mode::Tui(SessionChoice::New)));
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
        assert_eq!(
            command(&["login", "xai-grok"]),
            Ok(Some(Command::Login {
                provider: "xai-grok".to_owned()
            }))
        );
        assert_eq!(command(&["login"]), Err(ErrorKind::MissingRequiredArgument));
        assert_eq!(
            command(&["--rpc", "login", "xai-grok"]),
            Err(ErrorKind::ArgumentConflict)
        );
        assert_eq!(
            command(&["-p", "Hi.", "login", "xai-grok"]),
            Err(ErrorKind::ArgumentConflict)
        );
    }

    #[test]
    fn logout_takes_one_provider_and_no_mode_flag() {
        assert_eq!(
            command(&["logout", "xai-grok"]),
            Ok(Some(Command::Logout {
                provider: "xai-grok".to_owned()
            }))
        );
        assert_eq!(command(&["logout"]), Err(ErrorKind::MissingRequiredArgument));
        assert_eq!(
            command(&["--rpc", "logout", "xai-grok"]),
            Err(ErrorKind::ArgumentConflict)
        );
    }

    #[test]
    fn plugin_update_takes_all_or_names_but_not_both() {
        let update = |names: &[&str], all: bool| {
            Ok(Some(Command::Plugin {
                command: PluginCommand::Update {
                    all,
                    names: names.iter().map(|&name| name.to_owned()).collect(),
                    yes: false,
                },
            }))
        };
        assert_eq!(command(&["plugin", "update", "--all"]), update(&[], true));
        assert_eq!(
            command(&["plugin", "update", "clock", "tools"]),
            update(&["clock", "tools"], false)
        );
        assert_eq!(command(&["plugin", "update"]), Err(ErrorKind::MissingRequiredArgument));
        assert_eq!(
            command(&["plugin", "update", "--all", "clock"]),
            Err(ErrorKind::ArgumentConflict)
        );
    }

    #[test]
    fn rpc_with_a_print_flag_is_a_conflict_and_each_print_flag_needs_print() {
        assert_eq!(mode(&["--rpc", "-p", "Hi."]), Err(ErrorKind::ArgumentConflict));
        for flag in [&["--json"][..], &["--model", "a/b"], &["--reasoning", "off"]] {
            assert_eq!(mode(flag), Err(ErrorKind::MissingRequiredArgument), "{flag:?}");
            assert_eq!(
                mode(&[&["--rpc"][..], flag].concat()),
                Err(ErrorKind::ArgumentConflict),
                "{flag:?}"
            );
        }
        let id = SessionId::generate().to_string();
        for flag in [&["-c"][..], &["--session", &id]] {
            assert_eq!(
                mode(&[&["--rpc"][..], flag].concat()),
                Err(ErrorKind::ArgumentConflict),
                "{flag:?}"
            );
        }
    }

    #[test]
    fn continue_and_session_choose_the_start_session_of_the_terminal_interface() {
        let id = SessionId::generate();
        assert_eq!(mode(&["-c"]), Ok(Mode::Tui(SessionChoice::Newest)));
        assert_eq!(
            mode(&["--session", &id.to_string()]),
            Ok(Mode::Tui(SessionChoice::Id(id)))
        );
        assert_eq!(
            mode(&["-c", "--session", &id.to_string()]),
            Err(ErrorKind::ArgumentConflict)
        );
    }
}
