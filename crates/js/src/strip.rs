//! The removal of TypeScript types, and the cache of its output. The cache holds JavaScript, not bytecode, so no
//! file on disk reaches the bytecode reader of the engine.

use std::fmt;
use std::fs::File;
use std::io::{self, Write};
use std::path::{Path, PathBuf};
use std::sync::atomic::{AtomicU64, Ordering};

use oxc_allocator::Allocator;
use oxc_codegen::Codegen;
use oxc_parser::Parser;
use oxc_semantic::SemanticBuilder;
use oxc_span::{LabeledSpan, SourceType};
use oxc_transformer::{TransformOptions, Transformer};
use sha2::{Digest, Sha256};

/// The oxc version of `Cargo.toml`. Another version can print other JavaScript, so the cache key holds it.
pub(crate) const OXC_VERSION: &str = "0.153.0";

/// The start of the name of each temporary file. No cache file name starts with a dot.
const TEMPORARY_PREFIX: &str = ".tmp-";

/// The digits of a hex text.
const DIGITS: &[u8; 16] = b"0123456789abcdef";

/// The counter of the temporary files of this process. The process id and the counter make the name of each file.
static NEXT_TEMPORARY: AtomicU64 = AtomicU64::new(0);

/// The failure to give the JavaScript of a TypeScript file.
#[derive(Debug)]
pub(crate) enum StripError {
    /// The file is not valid TypeScript. Each line names a place in the file and the problem.
    Syntax(String),

    /// The cache folder refused a read or a write.
    Cache(PathBuf, io::Error),
}

impl fmt::Display for StripError {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            Self::Syntax(text) => f.write_str(text),
            Self::Cache(path, error) => write!(f, "the cache file {} failed: {error}", path.display()),
        }
    }
}

/// A folder of stripped files. The name of each file is the hex SHA-256 of the oxc version and the TypeScript source.
/// A changed source gets a new file. An old file stays until the user removes it.
#[derive(Debug)]
pub(crate) struct Cache {
    folder: PathBuf,
}

impl Cache {
    pub(crate) fn new(folder: PathBuf) -> Self {
        Self { folder }
    }

    /// The JavaScript of the TypeScript `source` of the file at `path`, from the cache when it holds the source.
    pub(crate) fn javascript(&self, path: &Path, source: &str) -> Result<String, StripError> {
        let file = self.folder.join(format!("{}.js", key(source)));
        match std::fs::read_to_string(&file) {
            Ok(code) => return Ok(code),
            Err(error) if error.kind() == io::ErrorKind::NotFound => {}
            Err(error) => return Err(StripError::Cache(file, error)),
        }

        let code = strip(path, source).map_err(StripError::Syntax)?;
        self.write(&file, &code)
            .map_err(|error| StripError::Cache(file, error))?;
        Ok(code)
    }

    /// Write `code` to `file` through a temporary file, so a reader never sees a part of it. A crash can lose the file,
    /// and the next load strips the source again.
    fn write(&self, file: &Path, code: &str) -> io::Result<()> {
        std::fs::create_dir_all(&self.folder)?;
        let number = NEXT_TEMPORARY.fetch_add(1, Ordering::Relaxed);
        let temporary = self
            .folder
            .join(format!("{TEMPORARY_PREFIX}{}-{number}", std::process::id()));
        File::create(&temporary)?.write_all(code.as_bytes())?;
        std::fs::rename(&temporary, file)
    }
}

/// The cache key of `source`: the lowercase hex SHA-256 of the oxc version, a zero byte, and the source.
fn key(source: &str) -> String {
    let mut hasher = Sha256::new();
    hasher.update(OXC_VERSION.as_bytes());
    hasher.update([0]);
    hasher.update(source.as_bytes());
    let digest = hasher.finalize();

    let mut text = String::with_capacity(digest.len() * 2);
    for byte in digest {
        text.push(char::from(DIGITS[usize::from(byte >> 4)]));
        text.push(char::from(DIGITS[usize::from(byte & 15)]));
    }
    text
}

/// Remove the types of the TypeScript module `source`, and return the JavaScript. The output keeps modern syntax. The
/// code generator writes new code, so a line of the output can differ from the line of the source.
pub(crate) fn strip(path: &Path, source: &str) -> Result<String, String> {
    let allocator = Allocator::default();
    let parsed = Parser::new(&allocator, source, SourceType::ts().with_module(true)).parse();
    if parsed.diagnostics.has_errors() {
        return Err(describe(
            path,
            source,
            parsed
                .diagnostics
                .errors()
                .map(|error| (error.labels.first().map(LabeledSpan::offset), &*error.message)),
        ));
    }

    let mut program = parsed.program;
    let built = SemanticBuilder::new_compiler().build(&program);
    if built.diagnostics.has_errors() {
        return Err(describe(
            path,
            source,
            built
                .diagnostics
                .errors()
                .map(|error| (error.labels.first().map(LabeledSpan::offset), &*error.message)),
        ));
    }
    let scoping = built.semantic.into_scoping();

    let transformed =
        Transformer::new(&allocator, path, &TransformOptions::default()).build_with_scoping(scoping, &mut program);
    if transformed.diagnostics.has_errors() {
        return Err(describe(
            path,
            source,
            transformed
                .diagnostics
                .errors()
                .map(|error| (error.labels.first().map(LabeledSpan::offset), &*error.message)),
        ));
    }

    Ok(Codegen::new().build(&program).code)
}

/// One line for each error: the path, the line and column of the error's offset, and its message.
fn describe<'a>(path: &Path, source: &str, errors: impl Iterator<Item = (Option<u32>, &'a str)>) -> String {
    let lines: Vec<String> = errors
        .map(|(offset, message)| match offset {
            Some(offset) => {
                let (line, column) = place(source, offset);
                format!("{}:{line}:{column}: {message}", path.display())
            }
            None => format!("{}: {message}", path.display()),
        })
        .collect();
    lines.join("\n")
}

/// The line and column, both from 1, of the byte `offset` in `source`. The column counts characters.
fn place(source: &str, offset: u32) -> (usize, usize) {
    let before = source.get(..offset as usize).unwrap_or(source);
    let line = before.matches('\n').count() + 1;
    let column = before.rsplit('\n').next().map_or(0, |text| text.chars().count()) + 1;
    (line, column)
}
