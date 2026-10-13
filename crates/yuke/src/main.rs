//! The `yuke` program. It has three modes: the terminal interface (no mode flag), the protocol server (`--rpc`), and
//! one task with no view (`-p`). Only `-p` runs now: the answer goes to stdout, and the end of the turn picks the exit
//! status.

mod config;
mod paths;
mod print;
mod prompt;

use std::io::{self, Write};
use std::process::ExitCode;
use std::sync::Arc;
use std::sync::atomic::{AtomicU8, Ordering};

use clap::{Parser, ValueEnum};
use serde::Serialize;
use tokio::signal::unix::{SignalKind, signal};
use yuke_ai::Effort;
use yuke_ai::catalog::ReasoningLevel;
use yuke_engine::{CancellationToken, Outcome, TurnEnd};
use yuke_protocol::SessionId;

use crate::paths::Paths;
use crate::print::{Finished, Machine, SessionChoice, Task, describe, warn};

/// The command line of `yuke`.
#[derive(Debug, Parser)]
#[command(
    name = "yuke",
    version,
    about = "A coding agent. Without -p or --rpc, yuke starts the terminal interface."
)]
struct Cli {
    /// Run one task with PROMPT. Print the last answer, then exit.
    #[arg(short = 'p', long = "print", value_name = "PROMPT", value_parser = clap::builder::NonEmptyStringValueParser::new())]
    prompt: Option<String>,

    /// Serve the yuke protocol on stdin and stdout.
    // Clap does not check `requires` beside a conflicting flag, so `--rpc` names each print flag.
    #[arg(long, conflicts_with_all = ["prompt", "json", "model", "reasoning", "session", "continue_newest"])]
    rpc: bool,

    /// Print one JSON object: the session id, the end of the turn, and the text of the last answer.
    #[arg(long, requires = "prompt")]
    json: bool,

    /// The model, as provider/model. The default is the "model" value in config.json.
    #[arg(long, value_name = "PROVIDER/MODEL", requires = "prompt")]
    model: Option<String>,

    /// The reasoning level. Without it, the endpoint sets the level.
    #[arg(long, value_enum, requires = "prompt")]
    reasoning: Option<Reasoning>,

    /// Continue the session with this id.
    #[arg(long, value_name = "ID", conflicts_with = "continue_newest", requires = "prompt")]
    session: Option<SessionId>,

    /// Continue the session of the current folder with the newest event.
    #[arg(short = 'c', long = "continue", requires = "prompt")]
    continue_newest: bool,
}

/// What the program runs.
#[derive(Debug, PartialEq)]
enum Mode {
    /// The terminal interface.
    Tui,
    /// The protocol server on stdin and stdout.
    Rpc,
    /// One task with no view. `json` prints the `--json` report.
    Print { task: Task, json: bool },
}

impl Cli {
    /// The mode that the flags name.
    fn mode(self) -> Mode {
        if self.rpc {
            return Mode::Rpc;
        }

        let Some(prompt) = self.prompt else {
            return Mode::Tui;
        };

        let task = Task {
            prompt,
            model: self.model,
            reasoning: self.reasoning.map(ReasoningLevel::from),
            session: match (self.session, self.continue_newest) {
                (Some(id), _) => SessionChoice::Id(id),
                (None, true) => SessionChoice::Newest,
                (None, false) => SessionChoice::New,
            },
        };

        Mode::Print { task, json: self.json }
    }
}

/// A reasoning level on the command line.
#[derive(Debug, Clone, Copy, ValueEnum)]
enum Reasoning {
    Off,
    Minimal,
    Low,
    Medium,
    High,
    Xhigh,
    Max,
}

impl From<Reasoning> for ReasoningLevel {
    fn from(reasoning: Reasoning) -> Self {
        match reasoning {
            Reasoning::Off => ReasoningLevel::Off,
            Reasoning::Minimal => ReasoningLevel::Effort(Effort::Minimal),
            Reasoning::Low => ReasoningLevel::Effort(Effort::Low),
            Reasoning::Medium => ReasoningLevel::Effort(Effort::Medium),
            Reasoning::High => ReasoningLevel::Effort(Effort::High),
            Reasoning::Xhigh => ReasoningLevel::Effort(Effort::Xhigh),
            Reasoning::Max => ReasoningLevel::Effort(Effort::Max),
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

#[tokio::main(flavor = "current_thread")]
async fn main() -> ExitCode {
    match Cli::parse().mode() {
        Mode::Tui => not_implemented("the terminal interface"),
        Mode::Rpc => not_implemented("the protocol server"),
        Mode::Print { task, json } => print_task(&task, json).await,
    }
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
    let signal_number = Arc::new(AtomicU8::new(0));
    if let Err(error) = watch_signals(cancellation_token.clone(), Arc::clone(&signal_number)) {
        warn(&format!("the signal handlers did not start: {}", describe(&error)));
        return ExitCode::FAILURE;
    }

    match run_here(task, cancellation_token).await {
        Ok(finished) => {
            if let Err(error) = write_output(&finished, json) {
                warn(&format!("the output did not write: {error}"));
                return ExitCode::FAILURE;
            }
            if let TurnEnd::Failed(error) = &finished.end
                && !json
            {
                warn(error);
            }
            exit_code(&finished.end, signal_number.load(Ordering::SeqCst))
        }
        Err(error) => {
            warn(&error);
            ExitCode::FAILURE
        }
    }
}

/// Run `task` on this machine: its environment, its folders, and an HTTP transport.
async fn run_here(task: &Task, cancellation_token: CancellationToken) -> Result<Finished, String> {
    let home = std::env::home_dir().filter(|home| home.is_absolute());
    let paths = Paths::of(&|name| std::env::var_os(name), home.as_deref())?;
    let cwd = std::env::current_dir()
        .and_then(std::fs::canonicalize)
        .map_err(|error| format!("the current folder: {error}"))?;
    let transport = yuke_ai::HttpTransport::new(yuke_ai::HttpOptions::new(concat!("yuke/", env!("CARGO_PKG_VERSION"))))
        .map_err(|error| describe(&error))?;
    let variable = |name: &str| std::env::var_os(name);
    let machine = Machine {
        paths,
        cwd,
        home,
        variable: &variable,
        transport: &transport,
    };
    print::run(task, &machine, cancellation_token).await
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
fn exit_code(end: &TurnEnd, signal_number: u8) -> ExitCode {
    match end {
        TurnEnd::Outcome(Outcome::Completed { .. } | Outcome::Stopped) => ExitCode::SUCCESS,
        TurnEnd::Outcome(Outcome::Cancelled) => ExitCode::from(128 + signal_number),
        TurnEnd::Failed(_) => ExitCode::FAILURE,
    }
}

/// Cancel the turn at the first SIGINT or SIGTERM, and keep its number in `signal_number`.
fn watch_signals(cancellation_token: CancellationToken, signal_number: Arc<AtomicU8>) -> io::Result<()> {
    let mut interrupt = signal(SignalKind::interrupt())?;
    let mut terminate = signal(SignalKind::terminate())?;
    tokio::spawn(async move {
        let number = tokio::select! {
            _ = interrupt.recv() => 2,
            _ = terminate.recv() => 15,
        };
        signal_number.store(number, Ordering::SeqCst);
        cancellation_token.cancel();
    });
    Ok(())
}

#[cfg(test)]
mod tests {
    use clap::CommandFactory;
    use clap::error::ErrorKind;

    use super::*;

    fn mode(arguments: &[&str]) -> Result<Mode, ErrorKind> {
        Cli::try_parse_from(std::iter::once("yuke").chain(arguments.iter().copied()))
            .map(Cli::mode)
            .map_err(|error| error.kind())
    }

    #[test]
    fn the_command_line_definition_is_consistent() {
        Cli::command().debug_assert();
    }

    #[test]
    fn no_mode_flag_starts_the_terminal_interface_and_rpc_starts_the_server() {
        assert_eq!(mode(&[]), Ok(Mode::Tui));
        assert_eq!(mode(&["--rpc"]), Ok(Mode::Rpc));
    }

    #[test]
    fn print_takes_its_flags_into_the_task() {
        assert_eq!(
            mode(&["-p", "Hi.", "--json", "-c", "--model", "a/b", "--reasoning", "xhigh"]),
            Ok(Mode::Print {
                task: Task {
                    prompt: "Hi.".to_owned(),
                    model: Some("a/b".to_owned()),
                    reasoning: Some(ReasoningLevel::Effort(Effort::Xhigh)),
                    session: SessionChoice::Newest,
                },
                json: true,
            })
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
