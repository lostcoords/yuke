//! The logins of the providers. `auth.json` in the data folder holds one login for each provider. Only a login and a
//! refresh write it, and each holds the lock file `auth.lock`, so two processes never refresh one login at once.

use std::collections::{BTreeMap, HashSet};
use std::error::Error;
use std::fmt;
use std::fs::{self, File, OpenOptions, Permissions, TryLockError};
use std::io::{self, Write};
use std::os::unix::fs::{OpenOptionsExt, PermissionsExt};
use std::path::PathBuf;
use std::sync::{Arc, Mutex};
use std::time::{Duration, Instant, SystemTime, UNIX_EPOCH};

use async_trait::async_trait;
use serde::{Deserialize, Serialize};
use yuke_ai::oauth::{Flow, Grant, OAuthError, PendingLogin, Poll};
use yuke_ai::route::Credential;
use yuke_ai::transport::Exchange;
use yuke_engine::CredentialSource;
use yuke_protocol::UpdateCredentialParams;

use crate::app::lock;

const FILE: &str = "auth.json";
const TEMPORARY: &str = "auth.json.tmp";
const LOCK: &str = "auth.lock";

/// A login that ends within this margin refreshes before the attempt, so a long request does not outlive its token.
const MARGIN: Duration = Duration::from_mins(5);

/// The longest wait for the lock. A holder that keeps it longer is stuck, so the wait ends without a refresh.
pub(crate) const LOCK_LIMIT: Duration = Duration::from_secs(30);

/// The wait between two tries of the lock.
const LOCK_RETRY: Duration = Duration::from_millis(100);

/// The longest login. No flow names one, so the login ends after this time without an approval.
const LOGIN_LIMIT: Duration = Duration::from_mins(15);

/// RFC 8628 section 3.5 adds this much to the interval after a `slow_down` answer.
const SLOW_DOWN_STEP: Duration = Duration::from_secs(5);

/// The shortest wait between two polls.
const MIN_INTERVAL: Duration = Duration::from_secs(1);

/// The longest wait after a failed poll.
const MAX_BACKOFF: Duration = Duration::from_secs(60);

/// The login of one provider in `auth.json`. `Debug` writes no token.
#[derive(Clone, PartialEq, Eq, Serialize, Deserialize)]
struct StoredLogin {
    access_token: String,
    refresh_token: String,
    /// The end of the access token, in milliseconds since the Unix epoch.
    expires_at: u64,
    /// The account that each model request names, for a flow that has one.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    account_id: Option<String>,
}

impl fmt::Debug for StoredLogin {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.debug_struct("StoredLogin")
            .field("access_token", &"<redacted>")
            .field("refresh_token", &"<redacted>")
            .field("expires_at", &self.expires_at)
            .field("account_id", &self.account_id)
            .finish()
    }
}

impl StoredLogin {
    /// The login of `grant`. A grant without a refresh token keeps `refresh_token`. A grant without an account keeps
    /// `account_id`.
    fn from_grant(grant: Grant, refresh_token: String, account_id: Option<String>) -> StoredLogin {
        StoredLogin {
            access_token: grant.access_token,
            refresh_token: grant.refresh_token.unwrap_or(refresh_token),
            expires_at: millis(grant.expires_at),
            account_id: grant.account_id.or(account_id),
        }
    }

    /// Whether the access token is still valid `margin` after `now`.
    fn valid(&self, now: SystemTime, margin: Duration) -> bool {
        self.expires_at > millis(now + margin)
    }
}

/// An access token from `credential/update`. Only memory holds it, and yuke never refreshes it. `Debug` writes no
/// token.
#[derive(Clone)]
pub(crate) struct Pushed {
    access_token: String,
    /// The end of the access token, in milliseconds since the Unix epoch.
    expires_at: u64,
    /// The account that each model request names, for a flow with accounts.
    account_id: Option<String>,
}

impl Pushed {
    /// The token of `params` for a provider with `flow`, at `now`. It is valid until its end, with no margin.
    ///
    /// # Errors
    ///
    /// Returns a text that names the bad field: an empty token, a control character, an end in the past, or an
    /// account that `flow` cannot name.
    pub(crate) fn new(params: UpdateCredentialParams, flow: Flow, now: SystemTime) -> Result<Pushed, String> {
        let bad = |value: &str| value.is_empty() || value.chars().any(char::is_control);
        if bad(&params.access_token) {
            return Err("accessToken: send a value that is not empty and has no control character".to_owned());
        }
        if params.expires_at <= millis(now) {
            return Err("expiresAt: the token already expired".to_owned());
        }
        match &params.account_id {
            Some(_) if flow.account_header().is_none() => {
                return Err(format!("accountId: {} names no account, so send none", params.provider));
            }
            Some(account) if bad(account) => {
                return Err("accountId: send a value that is not empty and has no control character".to_owned());
            }
            _ => {}
        }
        Ok(Pushed {
            access_token: params.access_token,
            expires_at: params.expires_at,
            account_id: params.account_id,
        })
    }
}

impl fmt::Debug for Pushed {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.debug_struct("Pushed")
            .field("access_token", &"<redacted>")
            .field("expires_at", &self.expires_at)
            .field("account_id", &self.account_id)
            .finish()
    }
}

/// The milliseconds of `time` since the Unix epoch. A time before the epoch is zero.
pub(crate) fn millis(time: SystemTime) -> u64 {
    time.duration_since(UNIX_EPOCH)
        .map_or(0, |since| u64::try_from(since.as_millis()).unwrap_or(u64::MAX))
}

/// Why no credential or no login came.
#[derive(Debug)]
pub(crate) enum AuthError {
    /// No login of the provider exists.
    NoLogin(String),
    /// The token that the client gave for the provider expired.
    PushExpired(String),
    /// The login ended, or its refresh token can be spent.
    Ended(String),
    /// The login expired, and its refresh failed for now.
    Unavailable { provider: String, cause: OAuthError },
    /// Another process held the lock past the limit, and the access token expired.
    Locked(PathBuf),
    /// The provider did not start a login.
    NotStarted(OAuthError),
    /// The provider refused the login, or its answer was not readable.
    Refused(OAuthError),
    /// The user did not approve the login in time.
    Expired,
    /// The provider gave no refresh token, so the login cannot last.
    NoRefreshToken,
    /// A file operation failed.
    File { path: PathBuf, error: io::Error },
    /// `auth.json` holds no valid content.
    Invalid { path: PathBuf, error: serde_json::Error },
    /// The thread of a file call stopped.
    Task(tokio::task::JoinError),
}

impl fmt::Display for AuthError {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            Self::NoLogin(provider) => write!(f, "no login for {provider}: run `yuke login {provider}`"),
            Self::PushExpired(provider) => write!(
                f,
                "the accessToken of credential/update for {provider} expired: send a new credential/update"
            ),
            Self::Ended(provider) => write!(f, "the login for {provider} ended: run `yuke login {provider}` again"),
            Self::Unavailable { provider, .. } => write!(f, "the login for {provider} expired and did not refresh"),
            Self::Locked(path) => write!(f, "{}: another process holds the lock", path.display()),
            Self::NotStarted(_) => f.write_str("the login did not start"),
            Self::Refused(_) => f.write_str("the login did not complete"),
            Self::Expired => f.write_str("the login expired before its approval"),
            Self::NoRefreshToken => f.write_str("the provider gave no refresh token, so the login cannot last"),
            Self::File { path, .. } | Self::Invalid { path, .. } => write!(f, "{}", path.display()),
            Self::Task(_) => f.write_str("a file call of the login stopped"),
        }
    }
}

impl Error for AuthError {
    fn source(&self) -> Option<&(dyn Error + 'static)> {
        match self {
            Self::Unavailable { cause, .. } | Self::NotStarted(cause) | Self::Refused(cause) => Some(cause),
            Self::File { error, .. } => Some(error),
            Self::Invalid { error, .. } => Some(error),
            Self::Task(error) => Some(error),
            Self::NoLogin(_)
            | Self::PushExpired(_)
            | Self::Ended(_)
            | Self::Locked(_)
            | Self::Expired
            | Self::NoRefreshToken => None,
        }
    }
}

/// The files of the logins in one data folder.
#[derive(Debug, Clone)]
struct Files {
    folder: PathBuf,
}

impl Files {
    fn path(&self, name: &str) -> PathBuf {
        self.folder.join(name)
    }

    fn file_error(&self, name: &str) -> impl FnOnce(io::Error) -> AuthError {
        let path = self.path(name);
        move |error| AuthError::File { path, error }
    }

    /// The logins of `auth.json`. A missing file has none.
    fn read(&self) -> Result<BTreeMap<String, StoredLogin>, AuthError> {
        let path = self.path(FILE);
        let bytes = match fs::read(&path) {
            Ok(bytes) => bytes,
            Err(error) if error.kind() == io::ErrorKind::NotFound => return Ok(BTreeMap::new()),
            Err(error) => return Err(AuthError::File { path, error }),
        };
        serde_json::from_slice(&bytes).map_err(|error| AuthError::Invalid { path, error })
    }

    /// The login of `provider`.
    fn login(&self, provider: &str) -> Result<Option<StoredLogin>, AuthError> {
        Ok(self.read()?.remove(provider))
    }

    /// Take the lock, and wait at most `limit`. `None` when another holder keeps it longer.
    fn lock(&self, limit: Duration) -> Result<Option<LockedFiles>, AuthError> {
        fs::create_dir_all(&self.folder).map_err(self.file_error(""))?;
        // The lock is its own file, because the rename of `auth.json` changes the file of that name.
        let file = OpenOptions::new()
            .write(true)
            .create(true)
            .truncate(false)
            .mode(0o600)
            .open(self.path(LOCK))
            .map_err(self.file_error(LOCK))?;
        let deadline = Instant::now() + limit;
        loop {
            match file.try_lock() {
                Ok(()) => {
                    return Ok(Some(LockedFiles {
                        files: self.clone(),
                        _lock: file,
                    }));
                }
                Err(TryLockError::WouldBlock) => {
                    let left = deadline.saturating_duration_since(Instant::now());
                    if left.is_zero() {
                        return Ok(None);
                    }
                    std::thread::sleep(left.min(LOCK_RETRY));
                }
                Err(TryLockError::Error(error)) => return Err(self.file_error(LOCK)(error)),
            }
        }
    }
}

/// The files of the logins while this process holds the lock. Only this type writes `auth.json`. The drop releases
/// the lock.
#[derive(Debug)]
struct LockedFiles {
    files: Files,
    _lock: File,
}

impl LockedFiles {
    /// Set the login of `provider` to `login`, or remove it.
    fn set(&self, provider: &str, login: Option<StoredLogin>) -> Result<(), AuthError> {
        let mut logins = self.files.read()?;
        match login {
            Some(login) => logins.insert(provider.to_owned(), login),
            None => logins.remove(provider),
        };
        self.write(&logins)
    }

    /// Replace `auth.json` with `logins`. The new file is whole or absent after a crash, and only the user can read it.
    fn write(&self, logins: &BTreeMap<String, StoredLogin>) -> Result<(), AuthError> {
        let files = &self.files;
        let bytes = serde_json::to_vec_pretty(logins).map_err(|error| AuthError::Invalid {
            path: files.path(FILE),
            error,
        })?;
        let temporary = files.path(TEMPORARY);
        let mut file = OpenOptions::new()
            .write(true)
            .create(true)
            .truncate(true)
            .mode(0o600)
            .open(&temporary)
            .map_err(files.file_error(TEMPORARY))?;
        // A file that an earlier crash left keeps its old mode, so the mode is set again.
        file.set_permissions(Permissions::from_mode(0o600))
            .map_err(files.file_error(TEMPORARY))?;
        file.write_all(&bytes).map_err(files.file_error(TEMPORARY))?;
        file.sync_all().map_err(files.file_error(TEMPORARY))?;
        fs::rename(&temporary, files.path(FILE)).map_err(files.file_error(FILE))?;
        // The rename is durable only after the folder syncs.
        File::open(&files.folder)
            .and_then(|folder| folder.sync_all())
            .map_err(files.file_error(""))
    }
}

/// The provider ids of the entries of `auth.json` in the data folder `folder`.
///
/// # Errors
///
/// Returns an [`AuthError`] when the file does not read or holds no valid content.
pub(crate) async fn logged_in(folder: PathBuf) -> Result<HashSet<String>, AuthError> {
    blocking(move || Ok(Files { folder }.read()?.into_keys().collect())).await
}

/// Run `f` on a blocking thread of tokio, because the file calls block.
async fn blocking<T: Send + 'static>(
    f: impl FnOnce() -> Result<T, AuthError> + Send + 'static,
) -> Result<T, AuthError> {
    tokio::task::spawn_blocking(f).await.map_err(AuthError::Task)?
}

/// The credential of a provider with a login. It reads `auth.json` before each attempt, and it refreshes a login that
/// ends within [`MARGIN`]. After [`LoginSource::push`], it gives the pushed token only. A clone shares the source.
#[derive(Clone)]
pub(crate) struct LoginSource(Arc<Login>);

impl fmt::Debug for LoginSource {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.debug_struct("LoginSource")
            .field("provider", &self.0.provider)
            .field("folder", &self.0.files.folder)
            .finish_non_exhaustive()
    }
}

struct Login {
    provider: String,
    flow: Flow,
    files: Files,
    exchange: Arc<dyn Exchange>,
    lock_limit: Duration,
    /// The refresh tokens that a refresh can have spent while `auth.json` still holds them. None goes out again.
    spent: Mutex<HashSet<String>>,
    /// The newest token from `credential/update`. Once set, it replaces the login for the life of the process.
    pushed: Mutex<Option<Pushed>>,
}

impl LoginSource {
    /// The source of `provider` with `flow`, and with the files in `folder`.
    pub(crate) fn new(
        provider: String,
        flow: Flow,
        folder: PathBuf,
        exchange: Arc<dyn Exchange>,
        lock_limit: Duration,
    ) -> LoginSource {
        LoginSource(Arc::new(Login {
            provider,
            flow,
            files: Files { folder },
            exchange,
            lock_limit,
            spent: Mutex::default(),
            pushed: Mutex::default(),
        }))
    }

    /// Use `pushed` for each attempt from now on, in place of the stored login.
    pub(crate) fn push(&self, pushed: Pushed) {
        *lock(&self.0.pushed) = Some(pushed);
    }

    /// Whether a `credential/update` gave a token.
    pub(crate) fn has_pushed(&self) -> bool {
        lock(&self.0.pushed).is_some()
    }
}

impl Login {
    /// The login of the provider in `auth.json`.
    async fn stored(&self) -> Result<StoredLogin, AuthError> {
        let files = self.files.clone();
        let provider = self.provider.clone();
        blocking(move || files.login(&provider))
            .await?
            .ok_or_else(|| AuthError::NoLogin(self.provider.clone()))
    }

    /// The login of the next attempt.
    async fn current(&self) -> Result<StoredLogin, AuthError> {
        let stored = self.stored().await?;
        if stored.valid(SystemTime::now(), MARGIN) {
            return Ok(stored);
        }
        let files = self.files.clone();
        let limit = self.lock_limit;
        let Some(locked) = blocking(move || files.lock(limit)).await? else {
            // A refresh without the lock can send a token that the holder spends too, so only a valid token serves.
            let stored = self.stored().await?;
            if stored.valid(SystemTime::now(), Duration::ZERO) {
                return Ok(stored);
            }
            return Err(AuthError::Locked(self.files.path(LOCK)));
        };
        self.refresh(locked).await
    }

    /// Refresh the login while `locked` holds the lock.
    async fn refresh(&self, locked: LockedFiles) -> Result<StoredLogin, AuthError> {
        // Another process can have refreshed during the wait for the lock, so the file holds the truth.
        let stored = self.stored().await?;
        let now = SystemTime::now();
        if stored.valid(now, MARGIN) {
            return Ok(stored);
        }
        if lock(&self.spent).contains(&stored.refresh_token) {
            return if stored.valid(now, Duration::ZERO) {
                Ok(stored)
            } else {
                Err(self.ended())
            };
        }
        match self.flow.refresh(&*self.exchange, &stored.refresh_token, now).await {
            Ok(grant) => {
                let new = StoredLogin::from_grant(grant, stored.refresh_token.clone(), stored.account_id);
                if self.save(locked, Some(new.clone())).await.is_err() {
                    // The provider can have spent the old token, and the file still holds it.
                    lock(&self.spent).insert(stored.refresh_token);
                }
                Ok(new)
            }
            // The refresh can take long, so the token is checked again at its end.
            Err(OAuthError::Transient(_)) if stored.valid(SystemTime::now(), Duration::ZERO) => Ok(stored),
            Err(cause @ OAuthError::Transient(_)) => Err(AuthError::Unavailable {
                provider: self.provider.clone(),
                cause,
            }),
            // The login is gone, or its token can be spent: only a new login recovers it.
            Err(OAuthError::Permanent | OAuthError::Ambiguous(_) | OAuthError::BadResponse) => {
                if self.save(locked, None).await.is_err() {
                    lock(&self.spent).insert(stored.refresh_token);
                }
                Err(self.ended())
            }
        }
    }

    /// Set the login of the provider to `login`, or remove it. The lock ends after the write.
    async fn save(&self, locked: LockedFiles, login: Option<StoredLogin>) -> Result<(), AuthError> {
        let provider = self.provider.clone();
        blocking(move || locked.set(&provider, login)).await
    }

    fn ended(&self) -> AuthError {
        AuthError::Ended(self.provider.clone())
    }
}

#[async_trait]
impl CredentialSource for LoginSource {
    async fn credential(&self) -> Result<Credential, Box<dyn Error + Send + Sync>> {
        // An expired push never falls back to the login, so the account and its billing never change without a word.
        let pushed = lock(&self.0.pushed).clone();
        if let Some(pushed) = pushed {
            if pushed.expires_at <= millis(SystemTime::now()) {
                return Err(Box::new(AuthError::PushExpired(self.0.provider.clone())));
            }
            return Ok(self.0.flow.credential(pushed.access_token, pushed.account_id));
        }
        let login = Arc::clone(&self.0);
        // The read and the refresh run in their own task, so a cancel cannot cut a refresh between its send and its
        // write.
        let current = tokio::spawn(async move { login.current().await }).await??;
        // A push during the read wins over the login that the read found.
        if let Some(pushed) = lock(&self.0.pushed).clone() {
            return Ok(self.0.flow.credential(pushed.access_token, pushed.account_id));
        }
        Ok(self.0.flow.credential(current.access_token, current.account_id))
    }
}

/// Log in to `provider` with `flow`, and save the login in the data folder `folder`. `show` gets the code and the
/// page of the approval. The login ends after [`LOGIN_LIMIT`] without an approval.
///
/// # Errors
///
/// Returns [`AuthError`] when the provider refuses, the login expires, or the save fails.
pub(crate) async fn login(
    provider: &str,
    flow: Flow,
    folder: PathBuf,
    exchange: &dyn Exchange,
    show: impl FnOnce(&PendingLogin),
) -> Result<(), AuthError> {
    // The clock counts the waits and the requests, so a slow provider cannot outlast the limit.
    let started = tokio::time::Instant::now();
    let pending = flow.start(exchange).await.map_err(AuthError::NotStarted)?;
    show(&pending);
    let mut interval = pending.interval.max(MIN_INTERVAL);
    let mut backoff = Duration::ZERO;
    // RFC 8628 section 3.5 asks for one whole interval before the first poll.
    let mut delay = interval;
    loop {
        if started.elapsed() + delay > LOGIN_LIMIT {
            return Err(AuthError::Expired);
        }
        tokio::time::sleep(delay).await;
        match pending.poll(exchange, SystemTime::now()).await {
            Ok(Poll::Approved(grant)) => return save_login(provider, grant, folder).await,
            Ok(Poll::Pending) => {
                backoff = Duration::ZERO;
                delay = interval;
            }
            Ok(Poll::SlowDown) => {
                backoff = Duration::ZERO;
                interval += SLOW_DOWN_STEP;
                delay = interval;
            }
            Err(OAuthError::Transient(_)) => {
                backoff = (backoff * 2).clamp(interval, MAX_BACKOFF.max(interval));
                delay = backoff;
            }
            Err(error) => return Err(AuthError::Refused(error)),
        }
    }
}

/// Save the grant of a new login of `provider` under the lock.
async fn save_login(provider: &str, mut grant: Grant, folder: PathBuf) -> Result<(), AuthError> {
    let refresh_token = grant.refresh_token.take().ok_or(AuthError::NoRefreshToken)?;
    let login = StoredLogin::from_grant(grant, refresh_token, None);
    let files = Files { folder };
    let provider = provider.to_owned();
    blocking(move || {
        let Some(locked) = files.lock(LOCK_LIMIT)? else {
            return Err(AuthError::Locked(files.path(LOCK)));
        };
        locked.set(&provider, Some(login))
    })
    .await
}

#[cfg(test)]
mod tests;
