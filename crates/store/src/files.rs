//! The folder of each session: its lock file and its blobs. A blob file has the hex SHA-256 of its bytes as its name,
//! and no other session reads it.

use std::fs::{File, OpenOptions, TryLockError};
use std::io::{self, Write};
use std::path::{Path, PathBuf};
use std::sync::atomic::{AtomicU64, Ordering};

use yuke_agent::StoreError;
use yuke_sql::rusqlite::Connection;

use crate::queries::sessions;
use crate::store::failed;

/// The name of the lock file in a session folder. No blob has this name, because a blob name has 64 characters.
const LOCK: &str = "lock";

/// The start of the name of each temporary file. No blob name starts with a dot.
const TEMPORARY_PREFIX: &str = ".tmp-";

/// The counter of the temporary files of this process. The process id and the counter make the name of each file.
static NEXT_TEMPORARY: AtomicU64 = AtomicU64::new(0);

/// The folder of session `session` in the folder `sessions`.
pub(crate) fn session_folder(sessions: &Path, session: &[u8; 16]) -> PathBuf {
    sessions.join(hex(session))
}

/// Take the lock of the session in `folder`, and make the folder when it is missing. Windows does not lock a file
/// that is open only for append, so the file opens for writing.
pub(crate) fn take_lock(folder: &Path) -> Result<File, StoreError> {
    std::fs::create_dir_all(folder).map_err(failed)?;
    let file = OpenOptions::new()
        .write(true)
        .create(true)
        .truncate(false)
        .open(folder.join(LOCK))
        .map_err(failed)?;

    match file.try_lock() {
        Ok(()) => Ok(file),
        Err(TryLockError::WouldBlock) => Err(StoreError::Owned),
        Err(TryLockError::Error(error)) => Err(failed(error)),
    }
}

/// Write `bytes` as a blob in `folder`, and return its reference. The file is durable before the return, so a commit
/// never names a file that a crash can lose. The same bytes again replace the file with equal content.
pub(crate) fn write_blob(folder: &Path, bytes: &[u8]) -> io::Result<yuke_ai::Blob> {
    let blob = yuke_agent::blob_of(bytes);
    std::fs::create_dir_all(folder)?;
    let temporary = temporary_file(folder);

    // An error before the rename leaves the temporary file, and the delete of the session removes it. A file of a
    // stopped process with the same id gets new content.
    let mut file = File::create(&temporary)?;
    file.write_all(bytes)?;
    file.sync_all()?;
    std::fs::rename(&temporary, folder.join(hex(&blob.digest)))?;

    sync_folder(folder)?;
    Ok(blob)
}

/// Copy each blob file of the session folder `source` into the session folder `destination`, and make the copies
/// durable. Each copy goes through a temporary file, because a read does not check the digest of a blob.
pub(crate) fn copy_blobs(source: &Path, destination: &Path) -> io::Result<()> {
    for entry in std::fs::read_dir(source)? {
        let entry = entry?;
        let name = entry.file_name();
        if name == LOCK || name.to_string_lossy().starts_with(TEMPORARY_PREFIX) {
            continue;
        }

        let temporary = temporary_file(destination);
        // On a file system with reflinks, such as btrfs or APFS, the copy can share the blocks of the source file.
        std::fs::copy(entry.path(), &temporary)?;
        // Windows syncs only a file that is open for writing.
        OpenOptions::new().write(true).open(&temporary)?.sync_all()?;
        std::fs::rename(&temporary, destination.join(name))?;
    }
    sync_folder(destination)
}

/// A new temporary file name in `folder`.
fn temporary_file(folder: &Path) -> PathBuf {
    let number = NEXT_TEMPORARY.fetch_add(1, Ordering::Relaxed);
    folder.join(format!("{TEMPORARY_PREFIX}{}-{number}", std::process::id()))
}

/// Make the entries of `folder` durable, such as a renamed file or a new folder. Windows does not open a folder as a
/// file, so only Unix syncs.
pub(crate) fn sync_folder(folder: &Path) -> io::Result<()> {
    if cfg!(unix) {
        File::open(folder)?.sync_all()?;
    }
    Ok(())
}

/// The bytes of the blob `digest` in `folder`. A missing file gives `None`, and a missing folder gives
/// [`StoreError::NotFound`], because a session folder lives as long as its session.
pub(crate) fn read_blob(folder: &Path, digest: &yuke_ai::Digest) -> Result<Option<Vec<u8>>, StoreError> {
    match std::fs::read(folder.join(hex(digest))) {
        Ok(bytes) => Ok(Some(bytes)),
        Err(error) if error.kind() == io::ErrorKind::NotFound => {
            if folder.is_dir() {
                Ok(None)
            } else {
                Err(StoreError::NotFound)
            }
        }
        Err(error) => Err(failed(error)),
    }
}

/// Remove the session folder with its lock file and blobs. A missing folder counts as removed, because the sweep of
/// another process can remove it first.
pub(crate) fn remove_session_folder(folder: &Path) -> io::Result<()> {
    match std::fs::remove_dir_all(folder) {
        Err(error) if error.kind() == io::ErrorKind::NotFound => Ok(()),
        result => result,
    }
}

/// Remove each session folder in `sessions` that has no session row and a free lock. A crash during a delete, or a
/// put of another process during a delete, leaves such a folder. A delete in progress holds the lock.
pub(crate) fn sweep(connection: &Connection, sessions: &Path) -> Result<(), StoreError> {
    for entry in std::fs::read_dir(sessions).map_err(failed)? {
        let entry = entry.map_err(failed)?;
        let Some(session) = entry.file_name().to_str().and_then(parse_session) else {
            continue;
        };
        let count = sessions::session_count(connection, session)
            .one()
            .map_err(failed)?
            .count;
        if count > 0 {
            continue;
        }

        let folder = entry.path();
        match take_lock(&folder) {
            Ok(lock) => {
                // Windows does not delete an open file, so the lock closes before the folder goes.
                drop(lock);
                remove_session_folder(&folder).map_err(failed)?;
            }
            Err(StoreError::Owned) => {}
            Err(error) => return Err(error),
        }
    }
    Ok(())
}

/// The session id of a folder name: 32 lowercase hex digits.
fn parse_session(name: &str) -> Option<[u8; 16]> {
    let lowercase_hex = name.len() == 32 && name.bytes().all(|byte| matches!(byte, b'0'..=b'9' | b'a'..=b'f'));
    if !lowercase_hex {
        return None;
    }
    u128::from_str_radix(name, 16).ok().map(u128::to_be_bytes)
}

/// The lowercase hex digits of `bytes`.
fn hex(bytes: &[u8]) -> String {
    const DIGITS: &[u8; 16] = b"0123456789abcdef";
    let mut text = String::with_capacity(bytes.len() * 2);
    for byte in bytes {
        text.push(char::from(DIGITS[usize::from(byte >> 4)]));
        text.push(char::from(DIGITS[usize::from(byte & 15)]));
    }
    text
}
