//! A route holds how one request reaches a provider, and the credential headers it presents.

use std::borrow::Cow;
use std::fmt;

use serde::Deserialize;

use crate::transport::Header;

/// Select the HTTP header and value format. This type holds no credential bytes.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum CredentialHeader {
    /// `x-api-key: <key>`.
    XApiKey,
    /// `Authorization: Bearer <secret>`.
    AuthorizationBearer,
    /// `api-key: <key>`, as Azure OpenAI takes a key.
    ApiKey,
}

impl CredentialHeader {
    /// Return the header name.
    pub fn name(self) -> &'static str {
        match self {
            Self::XApiKey => "x-api-key",
            Self::AuthorizationBearer => "Authorization",
            Self::ApiKey => "api-key",
        }
    }
}

/// RFC 9110 defines the field-name token characters. A colon would split the field line.
fn is_tchar(c: u8) -> bool {
    matches!(
        c,
        b'!' | b'#' | b'$' | b'%' | b'&' | b'\'' | b'*' | b'+' | b'-' | b'.' | b'^' | b'_' | b'`' | b'|' | b'~'
    ) || c.is_ascii_alphanumeric()
}

/// Return true when a header name is one RFC 9110 token.
fn valid_header_name(name: &str) -> bool {
    !name.is_empty() && name.bytes().all(is_tchar)
}

/// Return true when a header value holds no control byte except a tab. This rejects CR and LF.
pub(crate) fn valid_header_value(value: &str) -> bool {
    value.bytes().all(|c| c == b'\t' || !c.is_ascii_control())
}

/// The transport writes these headers itself: framing, content type, connection, host, acceptance, and agent.
const TRANSPORT_HEADERS: [&str; 10] = [
    "accept",
    "accept-encoding",
    "connection",
    "content-length",
    "content-type",
    "host",
    "te",
    "transfer-encoding",
    "upgrade",
    "user-agent",
];

/// Return the name of the first header with invalid field syntax, that the transport writes itself, or that repeats a
/// name in `written`. An empty name in `written` rejects nothing. The check allocates nothing. The caller owns the
/// meaning of a duplicate field.
pub fn invalid_header<'h>(headers: &'h [Header], written: &[&str]) -> Option<&'h str> {
    let valid = |header: &Header| {
        valid_header_name(&header.name)
            && valid_header_value(&header.value)
            && !TRANSPORT_HEADERS
                .iter()
                .chain(written)
                .any(|owned| owned.eq_ignore_ascii_case(&header.name))
    };
    headers.iter().find(|header| !valid(header)).map(|header| &*header.name)
}

/// Select the header that carries the session id. Each value names one header, so a second host can reuse it.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash, Default, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum SessionHeader {
    /// The route carries the session id in no header.
    #[default]
    None,
    /// The ChatGPT backend routes a repeated prefix to one prompt cache by this header.
    SessionId,
    /// OpenCode Zen and Go route one conversation to one upstream by this header. They refuse a request without it.
    XOpencodeSession,
}

impl SessionHeader {
    /// The header name, or `None` when the route carries the session id in no header.
    pub fn name(self) -> Option<&'static str> {
        match self {
            Self::None => None,
            Self::SessionId => Some("session-id"),
            Self::XOpencodeSession => Some("x-opencode-session"),
        }
    }
}

/// The host fields of a provider. The encoder appends the protocol path. The caller validates configuration before use.
#[derive(Debug, Clone, PartialEq, Eq, Hash, Default)]
pub struct Route {
    /// The base URL, such as `https://api.anthropic.com/v1`.
    pub base_url: Cow<'static, str>,
    /// The header that carries the credential. `None` means that the route takes no credential.
    pub credential_header: Option<CredentialHeader>,
    /// The encoder rejects a header that repeats the credential header, the session header, an identity header of the
    /// credential, or a transport header.
    pub headers: Cow<'static, [Header]>,
    /// The header that carries the session id.
    pub session_header: SessionHeader,
}

/// The credential of a route. Presence must match [`Route::credential_header`]. `Debug` writes no secret.
#[derive(Clone, PartialEq, Eq, Hash, Default)]
pub enum Credential {
    /// The route takes no credential.
    #[default]
    None,
    /// An API key.
    ApiKey(Cow<'static, str>),
    /// An OAuth grant.
    OAuth(OAuth),
}

/// An access token and its valid identity headers. `Debug` writes no secret.
#[derive(Clone, PartialEq, Eq, Hash)]
pub struct OAuth {
    /// The bearer token.
    pub access_token: Cow<'static, str>,
    /// The identity headers the grant carries.
    pub headers: Cow<'static, [Header]>,
}

impl fmt::Debug for Credential {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            Self::None => f.write_str("None"),
            Self::ApiKey(_) => f.write_str("ApiKey(<redacted>)"),
            Self::OAuth(grant) => f.debug_tuple("OAuth").field(grant).finish(),
        }
    }
}

impl fmt::Debug for OAuth {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.debug_struct("OAuth")
            .field("access_token", &"<redacted>")
            .field("headers", &self.headers)
            .finish()
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn validates_header_names_and_values() {
        let valid = |header| invalid_header(&[header], &[]).is_none();
        assert!(valid(Header::from_static("anthropic-version", "2023-06-01")));
        assert!(!valid(Header::from_static("", "x"))); // An empty name aborts the client.
        assert!(!valid(Header::from_static("bad:name", "x")));
        assert!(!valid(Header::from_static("bad name", "x")));
        assert!(!valid(Header::from_static("x-note", "a\r\nb")));
        assert!(valid(Header::from_static("x-note", "a\tb"))); // A tab is legal.
        assert!(!valid(Header::from_static("User-Agent", "other"))); // The transport owns it.
    }

    #[test]
    fn credential_debug_redacts_secret() {
        let key = format!("{:?}", Credential::ApiKey("sk-secret".into()));
        let grant = format!(
            "{:?}",
            Credential::OAuth(OAuth {
                access_token: "token-secret".into(),
                headers: Vec::new().into(),
            })
        );
        assert!(!key.contains("sk-secret"));
        assert!(!grant.contains("token-secret"));
    }
}
