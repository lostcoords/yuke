//! A transport sends one request and returns the response head and body, as Go's `http.RoundTripper` does. A status
//! other than 200 is a response, not an error. A redirect is the one exception: it is [`Fault::RedirectRefused`].
//! One transport serves many sessions, and a body owns its connection.
//! An [`Exchange`] sends a small request and reads its whole answer, such as an OAuth token request.

use std::borrow::Cow;
use std::fmt;
use std::future::Future;
use std::pin::Pin;
use std::task::{Context, Poll};
use std::time::Instant;

use bytes::Bytes;

/// A future that a [`Transport`] returns.
pub type BoxFuture<'a, T> = Pin<Box<dyn Future<Output = T> + Send + 'a>>;

/// A response body that a [`Transport`] returns.
pub type BoxBody = Pin<Box<dyn Body>>;

/// Send one request and return its head and body.
///
/// Return [`Fault::ConnectFailed`] only before the request leaves. Return
/// [`Fault::ConnectionLost`] when the connection breaks after the request starts. Put a connection back in a pool only
/// after its body ended with no fault.
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

/// Post one small request and read its whole JSON answer.
pub trait Exchange: Send + Sync {
    /// Send `request`, and read its whole answer. `deadline` bounds the exchange up to the end of the answer.
    ///
    /// # Errors
    ///
    /// Returns a [`Fault`] if no whole answer arrives, and [`Fault::AnswerTooLarge`] for an answer above
    /// [`ExchangeRequest::max_answer`].
    fn exchange<'a>(
        &'a self,
        request: &'a ExchangeRequest<'_>,
        deadline: Option<Instant>,
    ) -> BoxFuture<'a, Result<Answer, Fault>>;
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

/// The faults of an exchange. An HTTP status is response data, not a fault.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash)]
pub enum Fault {
    /// The request holds an invalid header or too many headers. The request never left.
    InvalidRequest,
    /// The URL is invalid.
    BadUrl,
    /// The provider host did not resolve.
    DnsFailed,
    /// The socket or the TLS handshake never carried a request.
    ConnectFailed,
    /// The socket or the TLS handshake did not open before the deadline. No request left.
    ConnectTimeout,
    /// The TLS handshake rejected the certificate of the provider, for example an expired one or one of an unknown
    /// issuer.
    CertificateRejected,
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
    /// The answer of an exchange exceeds its limit.
    AnswerTooLarge,
}

/// One sentence for the caller. It names no internal error and no credential.
impl fmt::Display for Fault {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.write_str(match self {
            Self::IdleTimeout => "the provider exchange exceeded the idle timeout",
            Self::RequestTimeout => "the provider exchange exceeded the request timeout",
            Self::ConnectFailed => "the provider connection failed",
            Self::ConnectTimeout => "the provider connection did not open in time",
            Self::CertificateRejected => "the client rejected the TLS certificate of the provider",
            Self::DnsFailed => "the provider host did not resolve",
            Self::ConnectionLost => "the provider connection ended",
            Self::RedirectRefused => "the provider attempted a redirect",
            Self::BadUrl => "the provider endpoint URL is invalid",
            Self::MalformedResponse => "the provider sent a malformed response",
            Self::InvalidRequest => "the request holds an invalid header or too many headers",
            Self::TlsSetupFailed => "the client could not build its TLS configuration",
            Self::AnswerTooLarge => "the provider answer exceeds the size limit",
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

/// A small request whose whole JSON answer the caller reads. `Debug` writes no body, because a body can carry a
/// credential.
#[derive(Clone, Copy)]
pub struct ExchangeRequest<'a> {
    /// The endpoint URL.
    pub url: &'a str,
    /// The media type of the body.
    pub content_type: &'static str,
    /// The body.
    pub body: &'a [u8],
    /// The most answer bytes that the caller takes.
    pub max_answer: usize,
}

impl fmt::Debug for ExchangeRequest<'_> {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.debug_struct("ExchangeRequest")
            .field("url", &self.url)
            .field("content_type", &self.content_type)
            .field("body", &"<redacted>")
            .field("max_answer", &self.max_answer)
            .finish()
    }
}

/// The whole answer of an [`ExchangeRequest`]. `Debug` writes no body, because a body can carry a credential.
#[derive(Clone, PartialEq, Eq)]
pub struct Answer {
    /// The response head.
    pub head: Head,
    /// The body.
    pub body: Vec<u8>,
}

impl fmt::Debug for Answer {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.debug_struct("Answer")
            .field("head", &self.head)
            .field("body", &"<redacted>")
            .finish()
    }
}
