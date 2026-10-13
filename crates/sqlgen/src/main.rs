//! Write `src/queries.rs` of a crate from the SQL files of its `migrations` and `queries` folders.
#![expect(clippy::print_stdout, clippy::print_stderr, reason = "a command reports its result")]

use std::ffi::OsString;
use std::path::{Path, PathBuf};
use std::process::ExitCode;

const USAGE: &str = "Usage: cargo run -p yuke-sqlgen -- [--check] [--crate <dir>]";

const HELP: &str = "\
Write <dir>/src/queries.rs from the SQL files of <dir>/migrations and <dir>/queries.

Usage: cargo run -p yuke-sqlgen -- [--check] [--crate <dir>]

Options:
  --check        Compare with the file on disk, and write nothing. Exit with status 1 when the file is out of date.
  --crate <dir>  The crate folder. The default is crates/store of this workspace.
  --help         Show this help.

Examples:
  cargo run -p yuke-sqlgen
  cargo run -p yuke-sqlgen -- --check
  cargo run -p yuke-sqlgen -- --crate crates/sqlgen/tests/fixture --check
";

/// The command line.
struct Arguments {
    check: bool,
    help: bool,
    /// The crate folder from `--crate`, or `None` for `crates/store`.
    crate_folder: Option<PathBuf>,
}

impl Arguments {
    /// Parse the arguments. They are `OsString`, so a folder that is not UTF-8 stays valid.
    fn parse(mut arguments: impl Iterator<Item = OsString>) -> Result<Self, String> {
        let mut parsed = Arguments {
            check: false,
            help: false,
            crate_folder: None,
        };
        while let Some(argument) = arguments.next() {
            match argument.to_str() {
                Some("--check") => parsed.check = true,
                Some("--help" | "-h") => parsed.help = true,
                Some("--crate") => {
                    let folder = arguments
                        .next()
                        .ok_or("`--crate` needs a folder, for example `--crate crates/store`")?;
                    parsed.crate_folder = Some(PathBuf::from(folder));
                }
                _ => return Err(format!("unknown argument `{}`", argument.to_string_lossy())),
            }
        }
        Ok(parsed)
    }
}

fn main() -> ExitCode {
    let arguments = match Arguments::parse(std::env::args_os().skip(1)) {
        Ok(arguments) => arguments,
        Err(message) => {
            eprintln!("error: {message}\n{USAGE}\nRun `cargo run -p yuke-sqlgen -- --help` for the options.");
            return ExitCode::from(2);
        }
    };
    if arguments.help {
        print!("{HELP}");
        return ExitCode::SUCCESS;
    }
    match run(&arguments) {
        Ok(code) => code,
        Err(message) => {
            eprintln!("error: {message}");
            ExitCode::FAILURE
        }
    }
}

fn run(arguments: &Arguments) -> Result<ExitCode, String> {
    let crate_folder = match &arguments.crate_folder {
        Some(folder) => folder.clone(),
        // This crate is crates/sqlgen, so its parent folder holds crates/store.
        None => Path::new(env!("CARGO_MANIFEST_DIR"))
            .parent()
            .ok_or("the manifest folder of yuke-sqlgen has no parent")?
            .join("store"),
    };
    let output = crate_folder.join("src/queries.rs");
    let shown = shown(&output);
    let generated = yuke_sqlgen::generate(&crate_folder).map_err(|error| causes(&error))?;
    let summary = format!("query files: {}\nqueries: {}", generated.files, generated.queries);

    let current = match std::fs::read_to_string(&output) {
        Ok(current) => Some(current),
        Err(error) if error.kind() == std::io::ErrorKind::NotFound => None,
        Err(error) => return Err(format!("{shown}: {error}")),
    };
    if current.as_deref() == Some(generated.code.as_str()) {
        println!("{shown} is up to date\n{summary}");
        return Ok(ExitCode::SUCCESS);
    }
    if arguments.check {
        let crate_option = match &arguments.crate_folder {
            Some(folder) => format!(" -- --crate {}", folder.display()),
            None => String::new(),
        };
        eprintln!("error: {shown} is out of date\nRun `cargo run -p yuke-sqlgen{crate_option}` to update it.");
        return Ok(ExitCode::FAILURE);
    }
    std::fs::write(&output, &generated.code).map_err(|error| format!("{shown}: {error}"))?;
    println!("updated {shown}\n{summary}");
    Ok(ExitCode::SUCCESS)
}

/// `path` relative to the current folder when it is inside it, so the output stays short.
fn shown(path: &Path) -> String {
    std::env::current_dir()
        .ok()
        .and_then(|current| path.strip_prefix(current).ok().map(Path::to_path_buf))
        .unwrap_or_else(|| path.to_path_buf())
        .display()
        .to_string()
}

/// The text of `error` and of each of its sources, joined by colons.
fn causes(error: &dyn std::error::Error) -> String {
    std::iter::successors(Some(error), |error| error.source())
        .map(ToString::to_string)
        .collect::<Vec<_>>()
        .join(": ")
}
