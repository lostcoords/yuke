//! The stored logins of the remote servers. `mcp-auth.json` in the data folder holds one login for each server URL.
//! Each write holds the lock file `mcp-auth.lock`, so two processes never refresh one login at once.

use std::collections::BTreeMap;
use std::path::Path;
use std::time::{Duration, SystemTime, UNIX_EPOCH};

use serde::{Deserialize, Serialize};
use yuke_credentials::CredentialFile;
use yuke_engine::chain_text;

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

/// The login of one server in `mcp-auth.json` in one data folder.
#[derive(Clone)]
pub(crate) struct Store {
    file: CredentialFile,
    /// The URL of the server. It keys the login.
    pub(crate) url: String,
}

impl Store {
    pub(crate) fn new(folder: &Path, url: &str) -> Store {
        Store {
            file: CredentialFile::new(folder, "mcp-auth"),
            url: url.to_owned(),
        }
    }

    /// The login of the server.
    pub(crate) fn login(&self) -> Result<Option<StoredLogin>, String> {
        Ok(self.logins()?.remove(&self.url))
    }

    /// The logins of all servers. A missing file has none.
    fn logins(&self) -> Result<BTreeMap<String, StoredLogin>, String> {
        self.file.read().map_err(|error| chain_text(&error))
    }

    /// Take the lock. The call blocks until the holder releases it.
    pub(crate) fn lock(&self) -> Result<Locked, String> {
        Ok(Locked {
            store: self.clone(),
            locked: self.file.lock().map_err(|error| chain_text(&error))?,
        })
    }
}

/// The logins while this process holds the lock. Only this type writes them. The drop releases the lock.
pub(crate) struct Locked {
    store: Store,
    locked: yuke_credentials::Locked,
}

impl Locked {
    /// The login of the server.
    pub(crate) fn login(&self) -> Result<Option<StoredLogin>, String> {
        self.store.login()
    }

    /// Set the login of the server to `login`, or remove it.
    pub(crate) fn set_login(&self, login: Option<StoredLogin>) -> Result<(), String> {
        let mut logins = self.store.logins()?;
        match login {
            Some(login) => logins.insert(self.store.url.clone(), login),
            None => logins.remove(&self.store.url),
        };
        self.locked.write(&logins).map_err(|error| chain_text(&error))
    }
}
