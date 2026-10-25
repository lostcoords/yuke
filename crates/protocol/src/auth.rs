//! The logins of `auth/login`: a device login that the server drives for a client.

use serde::{Deserialize, Serialize};

use crate::LoginId;

/// The params of `auth/login`.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[cfg_attr(test, derive(ts_rs::TS))]
#[serde(rename_all = "camelCase")]
pub struct LoginParams {
    /// The id of a provider with a login flow, as `catalog/list` gives it.
    pub provider: String,
}

/// The result of `auth/login`: the code that the user confirms on the page of the provider.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[cfg_attr(test, derive(ts_rs::TS))]
#[serde(rename_all = "camelCase")]
pub struct LoginResult {
    /// The login. Its `auth/login_finished` names it.
    pub login_id: LoginId,
    /// The page where the user approves the login.
    pub verification_url: String,
    /// The code that the user confirms on the page, or enters when the page asks.
    pub user_code: String,
}

/// The params of `auth/logout`.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[cfg_attr(test, derive(ts_rs::TS))]
#[serde(rename_all = "camelCase")]
pub struct LogoutParams {
    /// The id of a provider, as `catalog/list` gives it.
    pub provider: String,
}

/// The params of `auth/cancel_login`.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[cfg_attr(test, derive(ts_rs::TS))]
#[serde(rename_all = "camelCase")]
pub struct CancelLoginParams {
    /// The login in progress.
    pub login_id: LoginId,
}

/// The params of `auth/login_finished`.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[cfg_attr(test, derive(ts_rs::TS))]
#[serde(rename_all = "camelCase")]
pub struct LoginFinishedParams {
    /// The login.
    pub login_id: LoginId,
    /// The provider of the login.
    pub provider: String,
    /// How the login ended.
    pub outcome: LoginOutcome,
}

/// How a login ended.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[cfg_attr(test, derive(ts_rs::TS))]
#[serde(tag = "kind", rename_all = "snake_case")]
pub enum LoginOutcome {
    /// The user approved, and the server saved the login in `auth.json`.
    Succeeded,
    /// `auth/cancel_login`, or a new `auth/login` for the provider, ended the login.
    Cancelled,
    /// The provider refused, the login expired, or the save failed, and `message` tells why.
    Failed {
        /// The text of the failure. It holds no token.
        message: String,
    },
}
