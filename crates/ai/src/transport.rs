//! A transport sends one request and returns the response head and body, as Go's `http.RoundTripper` does. A status
//! other than 200 is a response, not an error. One transport serves many sessions, and a body owns its connection.

use std::borrow::Cow;
use std::fmt;
use std::future::Future;
use std::pin::Pin;
use std::task::{Context, Poll};
use std::time::Instant;

use bytes::Bytes;

use crate::route;

/// A future that a [`Transport`] returns.
pub type BoxFuture<'a, T> = Pin<Box<dyn Future<Output = T> + Send + 'a>>;

/// A response body that a [`Transport`] returns.
pub type BoxBody = Pin<Box<dyn Body>>;

/// Send one request and return its head and body.
///
/// The retry policy trusts the faults. Return a fault that [`Fault::sent_nothing`] names only when the transport wrote
/// no request byte. Track the write yourself, because no hyper or reqwest error kind proves it. After the write starts,
/// return [`Fault::ConnectionLost`] for a broken connection. Put a connection back in a pool only after its body ended
/// with no fault.
pub trait Transport: Send + Sync {
    /// Send `request`, and read the response head. `deadline` bounds the exchange up to the end of the body.
    /// The request borrows only until the returned future ends.
    ///
    /// # Errors
    ///
    /// Returns a [`Fault`] if no response head arrives.
    fn open<'a>(
        &'a self,
        request: &'a Outgoing<'_>,
        deadline: Option<Instant>,
    ) -> BoxFuture<'a, Result<(Head, BoxBody), Fault>>;
}

/// The bytes of one response body, in chunks.
pub trait Body: Send {
    /// Poll for the next chunk. `None` ends the body.
    ///
    /// # Errors
    ///
    /// Returns a [`Fault`] if a read fails. The body ends after the fault.
    fn poll_chunk(self: Pin<&mut Self>, cx: &mut Context<'_>) -> Poll<Option<Result<Bytes, Fault>>>;
}

/// Read the next chunk of `body`.
pub(crate) async fn next_chunk(body: &mut BoxBody) -> Option<Result<Bytes, Fault>> {
    std::future::poll_fn(|cx| body.as_mut().poll_chunk(cx)).await
}

/// The faults of an exchange. An HTTP status is response data, not a fault. A fault that [`Fault::sent_nothing`]
/// names happened before the send, so a repeat cannot duplicate the request.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash)]
#[non_exhaustive]
pub enum Fault {
    /// The request holds an invalid header, a header that the transport writes itself, or too many headers. The
    /// request never left.
    InvalidRequest,
    /// The URL is invalid.
    BadUrl,
    /// The provider host did not resolve.
    DnsFailed,
    /// The socket or the TLS handshake never carried a request.
    ConnectFailed,
    /// A deadline passed before the request was sent.
    ConnectTimeout,
    /// The TLS configuration could not be built, for example because the platform gives no root certificate.
    TlsSetupFailed,
    /// A wait for the peer (the send, the head, or a body read) passed the idle deadline.
    IdleTimeout,
    /// The whole exchange passed its deadline.
    RequestTimeout,
    /// The client must not follow a 3xx response.
    RedirectRefused,
    /// An open connection broke during the exchange.
    ConnectionLost,
    /// The peer sent a head, a chunk, or an encoding the client refuses.
    MalformedResponse,
}

impl Fault {
    /// True when the fault happened before the request left, so the provider holds nothing of it.
    pub fn sent_nothing(self) -> bool {
        matches!(
            self,
            Self::InvalidRequest
                | Self::BadUrl
                | Self::DnsFailed
                | Self::ConnectFailed
                | Self::ConnectTimeout
                | Self::TlsSetupFailed
        )
    }
}

/// One sentence for the caller. It names no internal error and no credential.
impl fmt::Display for Fault {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.write_str(match self {
            Self::IdleTimeout => "the provider exchange exceeded the idle timeout",
            Self::RequestTimeout => "the provider exchange exceeded the request timeout",
            Self::ConnectFailed => "the provider connection failed",
            Self::ConnectTimeout => "the provider connection timed out before the request left",
            Self::DnsFailed => "the provider host did not resolve",
            Self::ConnectionLost => "the provider connection ended",
            Self::RedirectRefused => "the provider attempted a redirect",
            Self::BadUrl => "the provider endpoint URL is invalid",
            Self::MalformedResponse => "the provider sent a malformed response",
            Self::InvalidRequest => "the request holds an invalid header or too many headers",
            Self::TlsSetupFailed => "the client could not build its TLS configuration",
        })
    }
}

impl std::error::Error for Fault {}

/// One HTTP header. A `'static` text borrows, and other text is owned. `Debug` writes no value, because a header can
/// carry a credential.
#[derive(Clone, PartialEq, Eq, Hash)]
pub struct Header {
    /// The field name.
    pub name: Cow<'static, str>,
    /// The field value.
    pub value: Cow<'static, str>,
}

impl fmt::Debug for Header {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.debug_struct("Header")
            .field("name", &self.name)
            .field("value", &"<redacted>")
            .finish()
    }
}

impl Header {
    /// A header of `name` and `value`. A `&'static str` borrows, and a `String` moves in.
    pub fn new(name: impl Into<Cow<'static, str>>, value: impl Into<Cow<'static, str>>) -> Self {
        Header {
            name: name.into(),
            value: value.into(),
        }
    }

    /// A header of two static texts, for a `static` table.
    pub const fn from_static(name: &'static str, value: &'static str) -> Self {
        Header {
            name: Cow::Borrowed(name),
            value: Cow::Borrowed(value),
        }
    }
}

/// The request bytes to send: the URL, the headers, and the body in parts.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash)]
pub struct Outgoing<'a> {
    url: &'a str,
    headers: &'a [Header],
    /// The body in parts, sent in order. A long context stays in one part across requests.
    body: [&'a [u8]; 3],
}

impl<'a> Outgoing<'a> {
    /// A request of `url`, `headers`, and one `body`.
    pub fn new(url: &'a str, headers: &'a [Header], body: &'a [u8]) -> Self {
        Outgoing {
            url,
            headers,
            body: [body, &[], &[]],
        }
    }

    /// A request whose body is three parts, sent in order.
    pub(crate) fn from_parts(url: &'a str, headers: &'a [Header], body: [&'a [u8]; 3]) -> Self {
        Outgoing { url, headers, body }
    }

    /// The endpoint URL.
    pub fn url(&self) -> &'a str {
        self.url
    }

    /// The headers, in order.
    pub fn headers(&self) -> &'a [Header] {
        self.headers
    }

    /// The body parts, sent in order.
    pub fn body(&self) -> impl Iterator<Item = &'a [u8]> {
        self.body.into_iter()
    }

    /// The byte count of the whole body.
    pub fn body_len(&self) -> usize {
        self.body.iter().map(|part| part.len()).sum()
    }

    /// Report whether every header is a valid HTTP field that the transport does not write itself.
    pub fn valid_headers(&self) -> bool {
        route::valid_headers(self.headers)
    }
}

/// The response head facts a caller acts on.
#[derive(Debug, Clone, PartialEq, Eq, Hash)]
pub struct Head {
    /// The HTTP status.
    pub status: u16,
    /// The provider request id from `request-id` or `x-request-id`, when the answer names one.
    pub request_id: Option<String>,
    /// A parsed `retry-after-ms`, or `retry-after` converted to milliseconds.
    pub retry_after_ms: Option<u64>,
    /// The provider's `x-should-retry`: false vetoes a repeat, and true asks for one.
    pub should_retry: Option<bool>,
}

impl Head {
    /// A head with `status` and no other fact.
    pub fn new(status: u16) -> Self {
        Head {
            status,
            request_id: None,
            retry_after_ms: None,
            should_retry: None,
        }
    }
}
