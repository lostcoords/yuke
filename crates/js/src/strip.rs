//! The cache of stripped TypeScript. The cache holds JavaScript, not bytecode, so no file on disk reaches the bytecode
//! reader of the engine.

use std::fmt;
use std::fs::File;
use std::io::{self, Write};
use std::path::{Path, PathBuf};
use std::sync::atomic::{AtomicU64, Ordering};

use sha2::{Digest, Sha256};

use crate::typescript::strip;

/// The sources that decide the JavaScript of a TypeScript file: the oxc versions of `Cargo.toml` and the transform.
/// The cache key holds them, so a change of either one makes new cache entries.
const TRANSFORM: [&str; 2] = [include_str!("../Cargo.toml"), include_str!("typescript.rs")];

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

/// The cache key of `source`: the lowercase hex SHA-256 of each text of [`TRANSFORM`] and of the source, each one
/// after a zero byte.
fn key(source: &str) -> String {
    let mut hasher = Sha256::new();
    for text in TRANSFORM.iter().chain([&source]) {
        hasher.update([0]);
        hasher.update(text.as_bytes());
    }
    let digest = hasher.finalize();

    let mut text = String::with_capacity(digest.len() * 2);
    for byte in digest {
        text.push(char::from(DIGITS[usize::from(byte >> 4)]));
        text.push(char::from(DIGITS[usize::from(byte & 15)]));
    }
    text
}
