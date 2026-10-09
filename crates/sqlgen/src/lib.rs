//! Typed Rust for the SQLite queries of `.sql` files. [`generate`] runs the migrations into an in-memory database,
//! checks each query against that schema, and writes one module of functions for each query file. The functions
//! return the types of `yuke-sql`.
//!
//! A query file holds annotated queries:
//!
//! ```sql
//! --: Note(id: NoteId, author, title, body?)
//!
//! --! note_by_id (id: NoteId) : Note
//! --- The note with this id.
//! SELECT id, author, title, body FROM notes WHERE id = :id;
//! ```
//!
//! `--!` names a query, with its parameters in parentheses and its columns after `:`. `--:` names a row type that
//! more than one query can return. Each row declaration lists every returned column exactly once. The field order
//! can differ from the column order in the query. A query that returns columns needs an inline declaration or a
//! shared row type. The `---` lines before the SQL of a query are its doc comment. A field is not null, and `?` makes
//! it an `Option`. Only a `NOT NULL` constraint lets a table column go without `?`.
//!
//! A parameter annotation is the type of the function argument, for example `&str` or `NoteId`, because SQLite
//! reports no parameter type. A column takes its type from its schema declaration, `INTEGER` as `i64`, `REAL` as `f64`,
//! `TEXT` as `String`, and `BLOB` as `Vec<u8>`, unless an annotation names another type.

mod emit;
mod parse;
mod resolve;

use std::fmt;
use std::io::Write as _;
use std::path::{Path, PathBuf};
use std::process::{Command, Stdio};

/// Run each migration of the `migrations` folder, in file name order, and return the formatted Rust for the query
/// files of the `queries` folder. Each query file becomes a module that takes its name from the file.
///
/// The migrations are numbered `0001_name.sql`, `0002_name.sql`, and on, with no gap and no repeat. A database applies
/// them in this order, so each database gets the same schema.
///
/// # Errors
///
/// Returns [`Error`] when a file cannot be read, a migration fails, a query file does not fit the grammar, a query
/// fails a check, or rustfmt fails.
pub fn generate(migrations: &Path, queries: &Path) -> Result<Generated, Error> {
    let connection = rusqlite::Connection::open_in_memory().map_err(Error::Database)?;
    for (place, file) in sql_files(migrations)?.into_iter().enumerate() {
        check_number(&file, place + 1)?;
        let sql = read(&file)?;
        connection
            .execute_batch(&sql)
            .map_err(|source| Error::Migration { file, source })?;
    }
    let mut modules = Vec::new();
    for file in sql_files(queries)? {
        let source = read(&file)?;
        let parsed = parse::parse(&source).map_err(|message| Error::File {
            file: file.clone(),
            message,
        })?;
        modules.push(resolve::resolve(&connection, &file, &parsed)?);
    }
    let code = emit::emit(&modules).map_err(|error| Error::Format(error.to_string()))?;
    Ok(Generated {
        code: format(&code, queries)?,
        files: modules.len(),
        queries: modules.iter().map(|module| module.queries.len()).sum(),
    })
}

/// The output of [`generate`].
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Generated {
    /// The formatted Rust of all query files.
    pub code: String,
    /// The number of query files.
    pub files: usize,
    /// The number of queries in them.
    pub queries: usize,
}

/// The failure of [`generate`].
#[derive(Debug)]
pub enum Error {
    /// A file or a folder cannot be read.
    Io {
        /// The file or the folder.
        path: PathBuf,
        /// The cause.
        source: std::io::Error,
    },
    /// The in-memory database cannot be opened.
    Database(rusqlite::Error),
    /// A migration failed.
    Migration {
        /// The migration file.
        file: PathBuf,
        /// The error of SQLite.
        source: rusqlite::Error,
    },
    /// A query file does not fit the grammar, or one of its names is not valid.
    File {
        /// The query file.
        file: PathBuf,
        /// What is wrong, with the line when one line is wrong.
        message: String,
    },
    /// A query failed a check.
    Query {
        /// The query file.
        file: PathBuf,
        /// The name of the query.
        query: String,
        /// What is wrong.
        message: String,
    },
    /// rustfmt failed on the generated code.
    Format(String),
}

impl fmt::Display for Error {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            Error::Io { path, source } => write!(f, "{}: {source}", path.display()),
            Error::Database(source) => write!(f, "the in-memory database does not open: {source}"),
            Error::Migration { file, source } => write!(f, "{}: {source}", file.display()),
            Error::File { file, message } => write!(f, "{}: {message}", file.display()),
            Error::Query { file, query, message } => write!(f, "{}: query `{query}`: {message}", file.display()),
            Error::Format(message) => write!(f, "rustfmt failed: {message}"),
        }
    }
}

// The message holds the cause, so `source` stays `None` and a reporter does not print the cause twice.
impl std::error::Error for Error {}

/// Check that `file` is migration number `place`. Two branches can add the same number with two file names, so git
/// shows no conflict, and this check makes the second branch renumber its migration.
fn check_number(file: &Path, place: usize) -> Result<(), Error> {
    let number = file
        .file_name()
        .and_then(|name| name.to_str())
        .and_then(|name| name.split_once('_'))
        .filter(|(digits, _)| !digits.is_empty() && digits.bytes().all(|byte| byte.is_ascii_digit()))
        .and_then(|(digits, _)| digits.parse::<usize>().ok());
    let message = match number {
        Some(number) if number == place => return Ok(()),
        Some(number) => format!(
            "the migration has number {number}, but it is migration {place} in file name order. Number the \
             migrations 1, 2, 3, and on, with no gap and no repeat."
        ),
        None => "a migration name starts with its number and `_`, for example `0001_initial.sql`".to_owned(),
    };
    Err(Error::File {
        file: file.to_owned(),
        message,
    })
}

/// The `.sql` files of `folder`, in file name order.
fn sql_files(folder: &Path) -> Result<Vec<PathBuf>, Error> {
    let io = |source| Error::Io {
        path: folder.to_owned(),
        source,
    };
    let mut files = Vec::new();
    for entry in std::fs::read_dir(folder).map_err(io)? {
        let path = entry.map_err(io)?.path();
        if path.extension().is_some_and(|extension| extension == "sql") {
            files.push(path);
        }
    }
    files.sort();
    Ok(files)
}

fn read(file: &Path) -> Result<String, Error> {
    std::fs::read_to_string(file).map_err(|source| Error::Io {
        path: file.to_owned(),
        source,
    })
}

/// Format `code` with rustfmt. rustfmt runs in the `queries` folder, so it finds the `rustfmt.toml` of the
/// workspace, and the output passes `cargo fmt --check`.
fn format(code: &str, queries: &Path) -> Result<String, Error> {
    let rustfmt = std::env::var_os("RUSTFMT").unwrap_or_else(|| "rustfmt".into());
    let mut child = Command::new(rustfmt)
        .args(["--edition", "2024", "--emit", "stdout"])
        .current_dir(queries)
        .stdin(Stdio::piped())
        .stdout(Stdio::piped())
        .stderr(Stdio::piped())
        .spawn()
        .map_err(|error| Error::Format(error.to_string()))?;
    let mut stdin = child
        .stdin
        .take()
        .ok_or_else(|| Error::Format("rustfmt has no input".to_owned()))?;
    stdin
        .write_all(code.as_bytes())
        .map_err(|error| Error::Format(error.to_string()))?;
    // rustfmt reads until the end of its input, so the input closes before the wait.
    drop(stdin);
    let output = child
        .wait_with_output()
        .map_err(|error| Error::Format(error.to_string()))?;
    if !output.status.success() {
        return Err(Error::Format(String::from_utf8_lossy(&output.stderr).into_owned()));
    }
    String::from_utf8(output.stdout).map_err(|error| Error::Format(error.to_string()))
}
