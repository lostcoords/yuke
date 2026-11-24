//! The credential files of yuke: JSON that only the user can read, with a lock file for the writers.

use std::error::Error;
use std::fmt;
use std::fs::{self, File, OpenOptions};
use std::io::{self, Write};
use std::os::unix::fs::OpenOptionsExt;
use std::path::{Path, PathBuf};

use serde::Serialize;
use serde::de::DeserializeOwned;

/// A JSON file of credentials in a folder: only the user can read it, and a lock file orders the writers.
#[derive(Debug, Clone)]
pub struct CredentialFile {
    json: PathBuf,
    lock: PathBuf,
    temporary: PathBuf,
}

impl CredentialFile {
    /// The file `<name>.json` in `folder`, with the lock file `<name>.lock` and the temporary file `<name>.json.tmp`.
    pub fn new(folder: &Path, name: &str) -> CredentialFile {
        CredentialFile {
            json: folder.join(format!("{name}.json")),
            lock: folder.join(format!("{name}.lock")),
            temporary: folder.join(format!("{name}.json.tmp")),
        }
    }

    /// The value in the file. A missing file gives `T::default()`.
    ///
    /// # Errors
    ///
    /// Returns an error when the file does not read or does not hold a `T`.
    pub fn read<T: DeserializeOwned + Default>(&self) -> Result<T, FileError> {
        let bytes = match fs::read(&self.json) {
            Ok(bytes) => bytes,
            Err(error) if error.kind() == io::ErrorKind::NotFound => return Ok(T::default()),
            Err(error) => return Err(FileError::new(&self.json, error)),
        };
        serde_json::from_slice(&bytes).map_err(|error| FileError::new(&self.json, error))
    }

    /// Take the lock, and create the folder when it is missing. The call blocks until the holder releases the lock.
    ///
    /// # Errors
    ///
    /// Returns an error when the folder or the lock file does not open, or when the lock fails.
    pub fn lock(&self) -> Result<Locked, FileError> {
        if let Some(folder) = self.json.parent() {
            fs::create_dir_all(folder).map_err(|error| FileError::new(folder, error))?;
        }
        let file = OpenOptions::new()
            .write(true)
            .create(true)
            .truncate(false)
            .mode(0o600)
            .open(&self.lock)
            .map_err(|error| FileError::new(&self.lock, error))?;
        file.lock().map_err(|error| FileError::new(&self.lock, error))?;
        Ok(Locked {
            file: self.clone(),
            _lock: file,
        })
    }
}

/// A credential file while this process holds its lock. Only this type writes the file. The drop releases the lock.
#[derive(Debug)]
pub struct Locked {
    file: CredentialFile,
    _lock: File,
}

impl Locked {
    /// The value in the file, as [`CredentialFile::read`] gives it.
    ///
    /// # Errors
    ///
    /// Returns an error when the file does not read or does not hold a `T`.
    pub fn read<T: DeserializeOwned + Default>(&self) -> Result<T, FileError> {
        self.file.read()
    }

    /// Replace the file with the JSON of `value`. The new file is whole or absent after a crash, and only the user can
    /// read it.
    ///
    /// # Errors
    ///
    /// Returns an error when `value` does not serialize, or when the temporary file or the rename fails.
    pub fn write<T: Serialize>(&self, value: &T) -> Result<(), FileError> {
        let file = &self.file;
        let bytes = serde_json::to_vec_pretty(value).map_err(|error| FileError::new(&file.json, error))?;
        let temporary_error = |error| FileError::new(&file.temporary, error);
        let mut temporary = OpenOptions::new()
            .write(true)
            .create(true)
            .truncate(true)
            .mode(0o600)
            .open(&file.temporary)
            .map_err(temporary_error)?;
        temporary.write_all(&bytes).map_err(temporary_error)?;
        temporary.sync_all().map_err(temporary_error)?;
        fs::rename(&file.temporary, &file.json).map_err(|error| FileError::new(&file.json, error))
    }
}

/// A file call failed. The text is the path. The cause is the `source`: an I/O error or a JSON error.
#[derive(Debug)]
pub struct FileError {
    path: PathBuf,
    source: Box<dyn Error + Send + Sync>,
}

impl FileError {
    fn new(path: &Path, source: impl Error + Send + Sync + 'static) -> FileError {
        FileError {
            path: path.to_owned(),
            source: Box::new(source),
        }
    }
}

impl fmt::Display for FileError {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        self.path.display().fmt(f)
    }
}

impl Error for FileError {
    fn source(&self) -> Option<&(dyn Error + 'static)> {
        Some(&*self.source)
    }
}

#[cfg(test)]
mod tests {
    use std::collections::BTreeMap;
    use std::os::unix::fs::PermissionsExt;
    use std::sync::mpsc;
    use std::time::Duration;

    use super::*;

    type Entries = BTreeMap<String, String>;

    /// A new empty folder for the test `name`.
    fn folder(name: &str) -> PathBuf {
        let folder = std::env::temp_dir().join(format!("yuke-credentials-{}-{name}", std::process::id()));
        _ = fs::remove_dir_all(&folder);
        folder
    }

    fn entries(pairs: &[(&str, &str)]) -> Entries {
        pairs
            .iter()
            .map(|(key, value)| ((*key).to_owned(), (*value).to_owned()))
            .collect()
    }

    fn mode(path: &Path) -> u32 {
        fs::metadata(path).unwrap().permissions().mode() & 0o777
    }

    #[test]
    fn a_missing_file_reads_as_the_default() {
        let file = CredentialFile::new(&folder("missing"), "auth");

        assert_eq!(file.read::<Entries>().unwrap(), Entries::new());
    }

    #[test]
    fn a_written_value_reads_back_from_the_json_file_of_its_name() {
        let folder = folder("write_read");
        let file = CredentialFile::new(&folder, "mcp-auth");
        let value = entries(&[("a", "1")]);

        file.lock().unwrap().write(&value).unwrap();

        assert_eq!(file.read::<Entries>().unwrap(), value);
        assert_eq!(
            fs::read_to_string(folder.join("mcp-auth.json")).unwrap(),
            "{\n  \"a\": \"1\"\n}"
        );
        assert!(!folder.join("mcp-auth.json.tmp").exists());
    }

    #[test]
    fn the_json_file_and_the_lock_file_are_private_to_the_user() {
        let folder = folder("modes");
        let file = CredentialFile::new(&folder, "auth");

        file.lock().unwrap().write(&entries(&[])).unwrap();

        assert_eq!(mode(&folder.join("auth.json")), 0o600);
        assert_eq!(mode(&folder.join("auth.lock")), 0o600);
    }

    #[test]
    fn a_second_lock_waits_until_the_first_is_dropped() {
        let file = CredentialFile::new(&folder("lock"), "auth");
        let first = file.lock().unwrap();
        let (taken, second) = mpsc::channel();
        let waiting = file.clone();
        let thread = std::thread::spawn(move || {
            let _second = waiting.lock().unwrap();
            taken.send(()).unwrap();
        });

        let early = second.recv_timeout(Duration::from_millis(200));
        drop(first);
        let late = second.recv_timeout(Duration::from_secs(10));
        thread.join().unwrap();

        assert_eq!(early, Err(mpsc::RecvTimeoutError::Timeout));
        assert_eq!(late, Ok(()));
    }

    #[test]
    fn a_temporary_file_that_a_crash_left_changes_neither_a_read_nor_the_next_write() {
        let folder = folder("leftover");
        let file = CredentialFile::new(&folder, "auth");
        let value = entries(&[("a", "1")]);
        file.lock().unwrap().write(&value).unwrap();
        // A longer text than the next write shows that the write truncates the file.
        fs::write(folder.join("auth.json.tmp"), "{ half a file ".repeat(20)).unwrap();

        let read = file.read::<Entries>().unwrap();
        file.lock().unwrap().write(&entries(&[("b", "2")])).unwrap();

        assert_eq!(read, value);
        assert_eq!(file.read::<Entries>().unwrap(), entries(&[("b", "2")]));
    }

    #[test]
    fn an_unreadable_file_names_its_path_and_gives_the_json_error_as_its_source() {
        let folder = folder("broken");
        fs::create_dir_all(&folder).unwrap();
        fs::write(folder.join("auth.json"), "not json").unwrap();

        let error = CredentialFile::new(&folder, "auth").read::<Entries>().unwrap_err();

        assert_eq!(error.to_string(), folder.join("auth.json").display().to_string());
        assert!(
            error.source().unwrap().to_string().starts_with("expected ident"),
            "{error:?}"
        );
    }
}
