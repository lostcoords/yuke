//! The stored logins of the remote servers. `mcp-auth.json` in the data folder holds one login for each server URL.
//! Each write holds the lock file `mcp-auth.lock`, so two processes never refresh one login at once.

use std::collections::BTreeMap;
use std::fs::{self, File, OpenOptions};
use std::io::{self, Write};
use std::os::unix::fs::OpenOptionsExt;
use std::path::{Path, PathBuf};
use std::time::{Duration, SystemTime, UNIX_EPOCH};

use serde::{Deserialize, Serialize};

const FILE: &str = "mcp-auth.json";
const TEMPORARY: &str = "mcp-auth.json.tmp";
const LOCK: &str = "mcp-auth.lock";

/// The stored login of one server.
#[derive(Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub(crate) struct StoredLogin {
    pub(crate) client_id: String,
    pub(crate) token_endpoint: String,
    pub(crate) access_token: String,
    pub(crate) refresh_token: Option<String>,
    /// The end of the access token in seconds since the epoch. Without it, the token lasts until the server refuses it.
    pub(crate) expires_at: Option<u64>,
}

impl StoredLogin {
    /// Whether the access token still works after `margin`.
    pub(crate) fn valid(&self, margin: Duration) -> bool {
        let now = SystemTime::now().duration_since(UNIX_EPOCH).unwrap_or_default();
        self.expires_at
            .is_none_or(|end| Duration::from_secs(end) > now + margin)
    }
}

/// The files of the login of one server in one data folder.
#[derive(Clone)]
pub(crate) struct Store {
    folder: PathBuf,
    /// The URL of the server. It keys the login.
    pub(crate) url: String,
}

impl Store {
    pub(crate) fn new(folder: &Path, url: &str) -> Store {
        Store {
            folder: folder.to_owned(),
            url: url.to_owned(),
        }
    }

    fn path(&self, name: &str) -> PathBuf {
        self.folder.join(name)
    }

    fn file_error(&self, name: &str) -> impl FnOnce(io::Error) -> String {
        let path = self.path(name);
        move |error| format!("{}: {error}", path.display())
    }

    /// The logins of all servers. A missing file has none.
    fn read(&self) -> Result<BTreeMap<String, StoredLogin>, String> {
        let bytes = match fs::read(self.path(FILE)) {
            Ok(bytes) => bytes,
            Err(error) if error.kind() == io::ErrorKind::NotFound => return Ok(BTreeMap::new()),
            Err(error) => return Err(self.file_error(FILE)(error)),
        };
        serde_json::from_slice(&bytes).map_err(|error| format!("{}: {error}", self.path(FILE).display()))
    }

    /// The login of the server.
    pub(crate) fn login(&self) -> Result<Option<StoredLogin>, String> {
        Ok(self.read()?.remove(&self.url))
    }

    /// Take the lock. The call blocks until the holder releases it.
    pub(crate) fn lock(&self) -> Result<Locked, String> {
        fs::create_dir_all(&self.folder).map_err(self.file_error(""))?;
        // The lock is its own file, because the rename of `mcp-auth.json` changes the file of that name.
        let file = OpenOptions::new()
            .write(true)
            .create(true)
            .truncate(false)
            .mode(0o600)
            .open(self.path(LOCK))
            .map_err(self.file_error(LOCK))?;
        file.lock().map_err(self.file_error(LOCK))?;
        Ok(Locked {
            store: self.clone(),
            _lock: file,
        })
    }
}

/// The files of the logins while this process holds the lock. Only this type writes `mcp-auth.json`. The drop releases
/// the lock.
pub(crate) struct Locked {
    store: Store,
    _lock: File,
}

impl std::ops::Deref for Locked {
    type Target = Store;

    fn deref(&self) -> &Store {
        &self.store
    }
}

impl Locked {
    /// Set the login of the server to `login`, or remove it. The new file is whole or absent after a crash, and only
    /// the user can read it.
    pub(crate) fn set_login(&self, login: Option<StoredLogin>) -> Result<(), String> {
        let store = &self.store;
        let mut logins = store.read()?;
        match login {
            Some(login) => logins.insert(store.url.clone(), login),
            None => logins.remove(&store.url),
        };
        let bytes =
            serde_json::to_vec_pretty(&logins).map_err(|error| format!("{}: {error}", store.path(FILE).display()))?;
        let mut file = OpenOptions::new()
            .write(true)
            .create(true)
            .truncate(true)
            .mode(0o600)
            .open(store.path(TEMPORARY))
            .map_err(store.file_error(TEMPORARY))?;
        file.write_all(&bytes).map_err(store.file_error(TEMPORARY))?;
        file.sync_all().map_err(store.file_error(TEMPORARY))?;
        fs::rename(store.path(TEMPORARY), store.path(FILE)).map_err(store.file_error(FILE))
    }
}
