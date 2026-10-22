//! Typed Rust for the SQLite queries of `.sql` files. [`generate`] runs the migrations into an in-memory database,
//! checks each query against that schema, and writes one module of functions for each query file. The functions
//! return the types of `yuke-sql`. The output also holds `MIGRATIONS`, the SQL of each migration in number order, for
//! the migration runner of the crate.
//!
//! A query file holds annotated queries:
//!
//! ```sql
//! --! note_by_id (id: crate::NoteId) : (id: crate::NoteId, author, title, body?)
//! --- The note with this id.
//! SELECT id, author, title, body FROM notes WHERE id = :id;
//! ```
//!
//! `--!` names a query, with its parameters in parentheses and its columns after `:`. A query of one column gives the
//! value of that column. A query of several columns gets a row struct with the name of the query in `PascalCase`, for
//! example `NoteById`. The row declaration lists every returned column exactly once. The field order can differ from the column order in the query. The `---` lines before
//! the SQL of a query are its doc comment. A field is not null, and `?` makes it an `Option`. Only a `NOT NULL`
//! constraint lets a table column go without `?`. A type of the crate needs its full path, for example
//! `crate::NoteId`, because the generated modules import no name of their parent.
//!
//! SQLite reports the table column of a result, not whether the result can be `NULL`. So the generator rejects only a
//! nullable table column without `?`. Some queries return `NULL` from a `NOT NULL` column. These queries are an outer
//! join (also inside a view, a CTE, or a subquery), a scalar subquery without a row, a bare column of an aggregate over
//! no rows, and a compound select with a later arm that returns `NULL`. Mark their columns with `?`. A read of a
//! `NULL` into a field that is not an `Option` fails.
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

/// Run each migration of `crate_folder/migrations`, in file name order, and return the formatted Rust for the query
/// files of `crate_folder/queries`. Each query file becomes a module that takes its name from the file. The code
/// belongs in `crate_folder/src/queries.rs`, because its `MIGRATIONS` includes each migration by a path from there.
///
/// The migrations are numbered `0001_name.sql`, `0002_name.sql`, and on, with no gap and no repeat. A database applies
/// them in this order, so each database gets the same schema.
///
/// # Errors
///
/// Returns [`Error`] when a file cannot be read, a migration fails, a query file does not fit the grammar, a query
/// fails a check, or rustfmt fails.
pub fn generate(crate_folder: &Path) -> Result<Generated, Error> {
    let connection = rusqlite::Connection::open_in_memory()
        .map_err(|error| Error::caused("the in-memory database does not open".to_owned(), error))?;
    let mut migrations = Vec::new();
    for (place, file) in sql_files(&crate_folder.join("migrations"))?.into_iter().enumerate() {
        let name = migration_name(&file, place + 1)?;
        let sql = read(&file)?;
        connection
            .execute_batch(&sql)
            .map_err(|error| Error::caused(format!("{}: the migration failed", file.display()), error))?;
        migrations.push(name);
    }
    let queries = crate_folder.join("queries");
    let mut modules = Vec::new();
    for file in sql_files(&queries)? {
        let source = read(&file)?;
        let parsed = parse::parse(&source).map_err(|message| Error::new(format!("{}: {message}", file.display())))?;
        modules.push(resolve::resolve(&connection, &file, parsed)?);
    }
    let code = emit::emit(&migrations, &modules)
        .map_err(|error| format_error("yuke-sqlgen cannot write the generated code", error))?;
    Ok(Generated {
        code: format(&code, crate_folder)?,
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

/// The failure of [`generate`]: a text that names the file, and the query when one query fails, and the error under it
/// when one exists.
#[derive(Debug)]
pub struct Error {
    message: String,
    source: Option<Box<dyn std::error::Error + Send + Sync>>,
}

impl Error {
    fn new(message: String) -> Self {
        Error { message, source: None }
    }

    fn caused(message: String, source: impl std::error::Error + Send + Sync + 'static) -> Self {
        Error {
            message,
            source: Some(Box::new(source)),
        }
    }
}

impl fmt::Display for Error {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.write_str(&self.message)
    }
}

impl std::error::Error for Error {
    fn source(&self) -> Option<&(dyn std::error::Error + 'static)> {
        self.source
            .as_deref()
            .map(|source| source as &(dyn std::error::Error + 'static))
    }
}

/// The file name of `file` when it is migration number `place`. Two branches can add the same number with two file
/// names, so git shows no conflict, and this check makes the second branch renumber its migration.
fn migration_name(file: &Path, place: usize) -> Result<String, Error> {
    let name = file.file_name().and_then(|name| name.to_str());
    let number = name
        .and_then(|name| name.split_once('_'))
        .filter(|(digits, _)| !digits.is_empty() && digits.bytes().all(|byte| byte.is_ascii_digit()))
        .and_then(|(digits, _)| digits.parse::<usize>().ok());
    let message = match (name, number) {
        (Some(name), Some(number)) if number == place => return Ok(name.to_owned()),
        (_, Some(number)) => format!(
            "the migration has number {number}, but it is migration {place} in file name order. Number the \
             migrations 1, 2, 3, and on, with no gap and no repeat."
        ),
        (_, None) => "a migration name starts with its number and `_`, for example `0001_initial.sql`".to_owned(),
    };
    Err(Error::new(format!("{}: {message}", file.display())))
}

/// The `.sql` files of `folder`, in file name order.
fn sql_files(folder: &Path) -> Result<Vec<PathBuf>, Error> {
    let io = |error| Error::caused(format!("{} cannot be read", folder.display()), error);
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
    std::fs::read_to_string(file).map_err(|error| Error::caused(format!("{} cannot be read", file.display()), error))
}

/// Format `code` with rustfmt. rustfmt runs in `crate_folder`, so it finds the `rustfmt.toml` of the workspace. The
/// output then passes `cargo fmt --check`.
fn format(code: &str, crate_folder: &Path) -> Result<String, Error> {
    let rustfmt = std::env::var_os("RUSTFMT").unwrap_or_else(|| "rustfmt".into());
    let mut child = Command::new(rustfmt)
        .args(["--edition", "2024", "--emit", "stdout"])
        .current_dir(crate_folder)
        .stdin(Stdio::piped())
        .stdout(Stdio::piped())
        .stderr(Stdio::piped())
        .spawn()
        .map_err(|error| format_error("rustfmt does not start", error))?;
    // rustfmt reads until the end of its input, so the input closes before the wait. The wait comes before any error
    // return, so no child outlives the call.
    let written = match child.stdin.take() {
        Some(mut stdin) => stdin.write_all(code.as_bytes()),
        None => Err(std::io::Error::other("rustfmt has no input")),
    };
    let output = child
        .wait_with_output()
        .map_err(|error| format_error("rustfmt does not end", error))?;
    if !output.status.success() {
        return Err(Error::new(format!(
            "rustfmt refused the generated code: {}",
            String::from_utf8_lossy(&output.stderr)
        )));
    }
    written.map_err(|error| format_error("the generated code does not reach rustfmt", error))?;
    String::from_utf8(output.stdout).map_err(|error| format_error("rustfmt writes no UTF-8 text", error))
}

/// The error of the failed format `step`, with `source` as its cause.
fn format_error(step: &'static str, source: impl std::error::Error + Send + Sync + 'static) -> Error {
    Error::caused(step.to_owned(), source)
}
