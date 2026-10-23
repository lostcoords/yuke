//! An HTTP/1.1 client over hyper on tokio, with rustls for `https`. [`Client::send`] sends one [`Request`] on a new
//! connection and returns the [`Response`] at its head. The [`Body`] streams after that. The client follows no
//! redirect and decodes no `content-encoding`: the caller decides both.
//!
//! A new connection for each request means that a failure before the request left proves that nothing was sent.

use std::fmt;
use std::future::Future;
use std::io;
use std::pin::{Pin, pin};
use std::sync::{Arc, OnceLock};
use std::task::{Context, Poll};
use std::time::Duration;

use bytes::Bytes;
use http::header::{CONNECTION, CONTENT_LENGTH, HOST, TRANSFER_ENCODING, USER_AGENT};
use http::{HeaderMap, HeaderValue, Method, StatusCode, Uri};
use http_body_util::Full;
use hyper::body::{Body as _, Incoming};
use hyper::client::conn::http1;
use hyper_util::rt::TokioIo;
use rustls::pki_types::ServerName;
use tokio::io::{AsyncRead, AsyncWrite};
use tokio::net::TcpStream;
use tokio::time::{Instant, Sleep};

pub use http;

#[cfg(any(test, feature = "testing"))]
pub mod testing;

/// How a [`Client`] waits for the peer and names itself.
#[derive(Debug, Clone, PartialEq, Eq, Hash)]
pub struct ClientOptions {
    /// The longest wait for the peer. The connect, the send, and the head share one wait. Each body read has one
    /// wait. `None` sets no bound.
    pub idle_timeout: Option<Duration>,
    /// The client sends this value on each request whose headers have no `user-agent`. It must be a valid header
    /// value.
    pub user_agent: String,
}

impl ClientOptions {
    /// Options with `user_agent` and the default idle timeout of 300 seconds.
    pub fn new(user_agent: impl Into<String>) -> Self {
        ClientOptions {
            idle_timeout: Some(Duration::from_secs(300)),
            user_agent: user_agent.into(),
        }
    }
}

/// The error that [`Client::new`] returns when the user agent is not a valid header value.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash)]
pub struct InvalidUserAgent;

impl fmt::Display for InvalidUserAgent {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.write_str("the user agent is not a valid header value")
    }
}

impl std::error::Error for InvalidUserAgent {}

/// One request. The client owns the framing headers:
/// - It sets `host` and `connection: close`.
/// - It removes `content-length` and `transfer-encoding`. It sets `content-length` for a body, or for a `POST`, a
///   `PUT`, or a `PATCH`.
/// - It adds its `user-agent` when `headers` has none.
#[derive(Clone, PartialEq, Eq)]
pub struct Request {
    /// The method.
    pub method: Method,
    /// An absolute `http` or `https` URL.
    pub url: String,
    /// The headers. A name can repeat, and its values keep their order.
    pub headers: HeaderMap,
    /// The body. It is empty for a request without a body.
    pub body: Bytes,
}

impl Request {
    /// A request of `method` to `url`, with no header and no body.
    pub fn new(method: Method, url: impl Into<String>) -> Self {
        Request {
            method,
            url: url.into(),
            headers: HeaderMap::new(),
            body: Bytes::new(),
        }
    }
}

/// `Debug` writes no header value and no body, because they can carry a credential.
impl fmt::Debug for Request {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.debug_struct("Request")
            .field("method", &self.method)
            .field("url", &self.url)
            .field("headers", &self.headers.keys().collect::<Vec<_>>())
            .field("body", &self.body.len())
            .finish()
    }
}

/// An HTTP response: the head, and a body that streams.
pub struct Response {
    /// The status.
    pub status: StatusCode,
    /// The headers. A name can repeat, and its values keep their order.
    pub headers: HeaderMap,
    /// The body.
    pub body: Body,
}

/// `Debug` writes no header value, because a value such as `set-cookie` can carry a credential.
impl fmt::Debug for Response {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.debug_struct("Response")
            .field("status", &self.status)
            .field("headers", &self.headers.keys().collect::<Vec<_>>())
            .field("body", &self.body)
            .finish()
    }
}

/// The errors that a request can return. An HTTP status is response data, not an error.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash)]
pub enum Error {
    /// The request holds an invalid header or too many headers. The request never left.
    InvalidRequest,
    /// The URL is invalid, or its scheme is not `http` or `https`.
    BadUrl,
    /// The host did not resolve.
    DnsFailed,
    /// The socket or the TLS handshake never carried a request.
    ConnectFailed,
    /// The socket or the TLS handshake did not open before the deadline. No request left.
    ConnectTimeout,
    /// The TLS handshake rejected the certificate of the peer, for example an expired one or one of an unknown issuer.
    CertificateRejected,
    /// The TLS configuration could not be built, for example because the platform gives no root certificate.
    TlsSetupFailed,
    /// A wait for the peer (the send, the head, or a body read) passed the idle timeout.
    IdleTimeout,
    /// The whole request passed its deadline.
    RequestTimeout,
    /// An open connection broke during the request.
    ConnectionLost,
    /// The peer sent a head or a chunk that HTTP/1.1 does not allow.
    MalformedResponse,
}

/// One sentence for the caller. It names no internal error and no credential.
impl fmt::Display for Error {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.write_str(match self {
            Self::InvalidRequest => "the request holds an invalid header or too many headers",
            Self::BadUrl => "the URL is not a valid http or https URL",
            Self::DnsFailed => "the host did not resolve",
            Self::ConnectFailed => "the connection failed",
            Self::ConnectTimeout => "the connection did not open in time",
            Self::CertificateRejected => "the client rejected the TLS certificate of the peer",
            Self::TlsSetupFailed => "the client could not build its TLS configuration",
            Self::IdleTimeout => "the peer exceeded the idle timeout",
            Self::RequestTimeout => "the request exceeded its deadline",
            Self::ConnectionLost => "the connection ended",
            Self::MalformedResponse => "the peer sent a malformed response",
        })
    }
}

impl std::error::Error for Error {}

/// The client. It uses HTTP/1.1 over tokio, and rustls with the aws-lc-rs provider.
/// - On Unix outside Apple and Android, the `webpki` verifier checks certificates against the system roots. The roots
///   come from the paths in `SSL_CERT_FILE` or `SSL_CERT_DIR`, else from the system bundle file.
/// - On other platforms, the platform verifier checks certificates.
/// - The key exchange offers the hybrid post-quantum group `X25519MLKEM768` first.
#[derive(Debug)]
pub struct Client {
    idle_timeout: Option<Duration>,
    user_agent: HeaderValue,
    /// The TLS configuration, which the first successful `https` send builds. A failed build is not kept, so the next
    /// send builds again.
    tls: OnceLock<Arc<rustls::ClientConfig>>,
}

impl Client {
    /// Creates a client with `options`. The first `https` send builds the TLS configuration.
    ///
    /// # Errors
    ///
    /// Returns [`InvalidUserAgent`] if the user agent is not a valid header value.
    pub fn new(options: ClientOptions) -> Result<Self, InvalidUserAgent> {
        let user_agent = HeaderValue::try_from(options.user_agent).map_err(|_| InvalidUserAgent)?;
        Ok(Client {
            idle_timeout: options.idle_timeout,
            user_agent,
            tls: OnceLock::new(),
        })
    }

    /// Send `request` on a new connection, and return the response at its head. `deadline` bounds the request up to
    /// the end of the body.
    ///
    /// # Errors
    ///
    /// Returns an [`Error`] if no response head arrives.
    pub async fn send(&self, request: Request, deadline: Option<std::time::Instant>) -> Result<Response, Error> {
        // The deadline counts from here, before any preparation.
        let deadline = deadline.map(Instant::from_std);
        let target = Target::parse(&request.url)?;
        let http_request = self.build(&target, request)?;

        // Connect, send, and the head wait share the idle deadline, so a silent peer never holds the call.
        let bound = earlier(self.idle_timeout.map(|idle| Instant::now() + idle), deadline);
        let head = match bound {
            None => send(self.connect(&target).await?, http_request).await,
            Some((at, timed_out)) => {
                // A deadline that already passed starts no leg, so an expired request is never sent.
                if at <= Instant::now() {
                    return Err(timed_out);
                }
                // A timeout before the connection opens proves that the request did not leave.
                let socket = tokio::time::timeout_at(at, self.connect(&target))
                    .await
                    .map_err(|_| Error::ConnectTimeout)??;
                let outcome = tokio::time::timeout_at(at, send(socket, http_request)).await;
                outcome.unwrap_or(Err(timed_out))
            }
        };
        let (response, connection) = head?;
        let (parts, incoming) = response.into_parts();
        Ok(Response {
            status: parts.status,
            headers: parts.headers,
            body: Body {
                connection: Some(connection),
                incoming,
                idle_timeout: self.idle_timeout,
                deadline,
                timer: None,
                armed: None,
                done: false,
            },
        })
    }

    /// The TLS configuration. A failed build fails this send only.
    fn tls(&self) -> Result<Arc<rustls::ClientConfig>, Error> {
        if let Some(config) = self.tls.get() {
            return Ok(Arc::clone(config));
        }
        let provider = Arc::new(rustls::crypto::aws_lc_rs::default_provider());
        let builder = rustls::ClientConfig::builder_with_provider(provider)
            .with_safe_default_protocol_versions()
            .map_err(|_| Error::TlsSetupFailed)?;
        let built = Arc::new(
            with_verifier(builder)
                .ok_or(Error::TlsSetupFailed)?
                .with_no_client_auth(),
        );
        // Two sends can build at once. The first set wins, and both use its value.
        Ok(Arc::clone(self.tls.get_or_init(|| built)))
    }

    /// The hyper request of `request`, with the headers that the client adds. hyper decides the wire order and the
    /// case of the fields.
    fn build(&self, target: &Target, request: Request) -> Result<http::Request<Full<Bytes>>, Error> {
        let Request {
            method,
            headers: mut fields,
            body,
            ..
        } = request;
        let full = |result: Result<_, http::header::MaxSizeReached>| result.map_err(|_| Error::InvalidRequest);
        full(fields.try_insert(HOST, target.host_header.clone()))?;
        full(fields.try_insert(CONNECTION, HeaderValue::from_static("close")))?;
        // The client sends the whole body, so it decides the framing. RFC 9112 forbids both fields in one message.
        fields.remove(TRANSFER_ENCODING);
        fields.remove(CONTENT_LENGTH);
        // RFC 9110 asks for a length on a request of a method that defines content, even an empty one.
        if !body.is_empty() || [Method::POST, Method::PUT, Method::PATCH].contains(&method) {
            full(fields.try_insert(CONTENT_LENGTH, HeaderValue::from(body.len())))?;
        }
        if !fields.contains_key(USER_AGENT) {
            full(fields.try_insert(USER_AGENT, self.user_agent.clone()))?;
        }
        let mut http_request = http::Request::new(Full::new(body));
        *http_request.method_mut() = method;
        *http_request.uri_mut() = target.path.clone();
        *http_request.headers_mut() = fields;
        Ok(http_request)
    }

    /// Open the connection: TCP, and TLS for `https`.
    async fn connect(&self, target: &Target) -> Result<Box<dyn Socket>, Error> {
        // A TLS configuration that fails to build fails the send before it connects.
        let tls = if target.tls { Some(self.tls()?) } else { None };
        let mut addresses = tokio::net::lookup_host((target.host.as_str(), target.port))
            .await
            .map_err(|_| Error::DnsFailed)?
            .peekable();
        if addresses.peek().is_none() {
            return Err(Error::DnsFailed);
        }
        let mut tcp = None;
        for address in addresses {
            if let Ok(stream) = TcpStream::connect(address).await {
                tcp = Some(stream);
                break;
            }
        }
        let tcp = tcp.ok_or(Error::ConnectFailed)?;
        // The request goes out in one write, so no small segment waits for an acknowledgment.
        tcp.set_nodelay(true).map_err(|_| Error::ConnectFailed)?;
        let socket: Box<dyn Socket> = if let Some(tls) = tls {
            let name = ServerName::try_from(target.host.clone()).map_err(|_| Error::BadUrl)?;
            let stream = tokio_rustls::TlsConnector::from(tls)
                .connect(name, tcp)
                .await
                .map_err(|error| handshake_error(&error))?;
            Box::new(stream)
        } else {
            Box::new(tcp)
        };
        Ok(socket)
    }
}

/// Give `builder` the `webpki` verifier with the system roots. Return `None` when no root loads.
///
/// `SSL_CERT_FILE` or `SSL_CERT_DIR` names the exact roots. Otherwise the roots come from the system bundle file, and
/// from the certificate folders only when no bundle file exists. A root only in a folder then needs `SSL_CERT_DIR`.
#[cfg(all(unix, not(target_vendor = "apple"), not(target_os = "android")))]
fn with_verifier(
    builder: rustls::ConfigBuilder<rustls::ClientConfig, rustls::WantsVerifier>,
) -> Option<rustls::ConfigBuilder<rustls::ClientConfig, rustls::client::WantsClientCert>> {
    // The probe drops a named path that does not exist, so a named path goes to the loader that keeps it.
    let named = std::env::var_os("SSL_CERT_FILE").is_some() || std::env::var_os("SSL_CERT_DIR").is_some();
    let loaded = match openssl_probe::probe().cert_file {
        // The system tools write each root to the bundle, so one file read replaces hundreds.
        Some(bundle) if !named => rustls_native_certs::load_certs_from_paths(Some(&bundle), None),
        _ => rustls_native_certs::load_native_certs(),
    };
    let mut roots = rustls::RootCertStore::empty();
    roots.add_parsable_certificates(loaded.certs);
    (!roots.is_empty()).then(|| builder.with_root_certificates(roots))
}

/// Give `builder` the platform verifier. Return `None` when the verifier cannot start.
#[cfg(not(all(unix, not(target_vendor = "apple"), not(target_os = "android"))))]
fn with_verifier(
    builder: rustls::ConfigBuilder<rustls::ClientConfig, rustls::WantsVerifier>,
) -> Option<rustls::ConfigBuilder<rustls::ClientConfig, rustls::client::WantsClientCert>> {
    rustls_platform_verifier::BuilderVerifierExt::with_platform_verifier(builder).ok()
}

/// The error of a failed TLS handshake. The connector wraps the rustls error in the I/O error.
fn handshake_error(error: &io::Error) -> Error {
    match error.get_ref().and_then(|inner| inner.downcast_ref::<rustls::Error>()) {
        Some(rustls::Error::InvalidCertificate(_)) => Error::CertificateRejected,
        _ => Error::ConnectFailed,
    }
}

/// The byte stream of one connection: plain TCP, or TLS over TCP.
trait Socket: AsyncRead + AsyncWrite + Send + Unpin {}

impl<T: AsyncRead + AsyncWrite + Send + Unpin> Socket for T {}

type Connection = http1::Connection<TokioIo<Box<dyn Socket>>, Full<Bytes>>;

/// Send the request on a new connection, and drive the connection until the head arrives.
async fn send(
    socket: Box<dyn Socket>,
    request: http::Request<Full<Bytes>>,
) -> Result<(http::Response<Incoming>, Connection), Error> {
    let (mut sender, mut connection) = http1::handshake(TokioIo::new(socket))
        .await
        .map_err(|err| error_of(&err))?;
    let mut response = pin!(sender.send_request(request));
    let response = std::future::poll_fn(|cx| {
        if let Poll::Ready(result) = response.as_mut().poll(cx) {
            return Poll::Ready(result.map_err(|err| error_of(&err)));
        }
        match Pin::new(&mut connection).poll(cx) {
            // The connection ended before the head, so the response holds its cause.
            Poll::Ready(Err(err)) => Poll::Ready(Err(error_of(&err))),
            Poll::Ready(Ok(())) => match response.as_mut().poll(cx) {
                Poll::Ready(result) => Poll::Ready(result.map_err(|err| error_of(&err))),
                Poll::Pending => Poll::Ready(Err(Error::ConnectionLost)),
            },
            Poll::Pending => Poll::Pending,
        }
    })
    .await?;
    drop(sender);
    Ok((response, connection))
}

/// Name one hyper failure. A truncated message is a lost connection, and a parse failure a malformed response.
fn error_of(err: &hyper::Error) -> Error {
    // hyper refused to send the request, so nothing left.
    if err.is_user() {
        return Error::InvalidRequest;
    }
    if err.is_parse() || err.is_parse_status() {
        return Error::MalformedResponse;
    }
    if err.is_incomplete_message() {
        return Error::ConnectionLost;
    }
    let mut source = std::error::Error::source(err);
    while let Some(cause) = source {
        if let Some(io) = cause.downcast_ref::<io::Error>() {
            return io_error(io);
        }
        source = cause.source();
    }
    Error::ConnectionLost
}

/// Name one read failure. A TLS failure ends the connection, so it is a lost connection. Other invalid bytes are a
/// malformed response.
fn io_error(io: &io::Error) -> Error {
    if matches!(io.get_ref(), Some(inner) if inner.is::<rustls::Error>()) {
        return Error::ConnectionLost;
    }
    match io.kind() {
        io::ErrorKind::InvalidData | io::ErrorKind::InvalidInput => Error::MalformedResponse,
        _ => Error::ConnectionLost,
    }
}

/// Choose the earlier of the idle and the request deadline, with the error that the chosen deadline names.
fn earlier(idle: Option<Instant>, request: Option<Instant>) -> Option<(Instant, Error)> {
    match (idle, request) {
        (None, None) => None,
        // The earlier deadline binds, and names the error.
        (None, Some(request)) => Some((request, Error::RequestTimeout)),
        (Some(idle), Some(request)) if request <= idle => Some((request, Error::RequestTimeout)),
        (Some(idle), _) => Some((idle, Error::IdleTimeout)),
    }
}

/// Where one request goes.
#[derive(Debug)]
struct Target {
    tls: bool,
    /// The host without IPv6 brackets, for the resolver and the TLS server name.
    host: String,
    port: u16,
    /// `host[:port]` as the URL writes it.
    host_header: HeaderValue,
    /// The path and the query.
    path: Uri,
}

impl Target {
    fn parse(url: &str) -> Result<Self, Error> {
        let uri: Uri = url.parse().map_err(|_| Error::BadUrl)?;
        let tls = match uri.scheme_str() {
            Some("http") => false,
            Some("https") => true,
            _ => return Err(Error::BadUrl),
        };
        let authority = uri.authority().ok_or(Error::BadUrl)?;
        let host = authority.host();
        if host.is_empty() {
            return Err(Error::BadUrl);
        }
        let host_and_port = authority
            .as_str()
            .rsplit_once('@')
            .map_or(authority.as_str(), |(_, rest)| rest);
        // The parser keeps a port that is no number, and `Authority::port` then reports none.
        let port = match host_and_port.get(host.len()..).and_then(|rest| rest.strip_prefix(':')) {
            Some(port) => port.parse().map_err(|_| Error::BadUrl)?,
            None if tls => 443,
            None => 80,
        };
        let host_header = HeaderValue::try_from(host_and_port).map_err(|_| Error::BadUrl)?;
        let path = uri.path_and_query().map_or("/", http::uri::PathAndQuery::as_str);
        Ok(Target {
            tls,
            host: host.trim_start_matches('[').trim_end_matches(']').to_owned(),
            port,
            host_header,
            path: path.parse().map_err(|_| Error::BadUrl)?,
        })
    }
}

/// One response body. The body owns its connection, and drives the connection while the caller reads. A drop closes
/// the connection.
pub struct Body {
    /// `None` once the connection ended.
    connection: Option<Connection>,
    incoming: Incoming,
    idle_timeout: Option<Duration>,
    deadline: Option<Instant>,
    /// The timer of the read deadlines. Each read for more bytes resets it, so the body allocates it once.
    timer: Option<Pin<Box<Sleep>>>,
    /// The error of the armed deadline, or `None` while no read waits.
    armed: Option<Error>,
    /// The body ended or failed. It returns nothing more.
    done: bool,
}

impl fmt::Debug for Body {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.debug_struct("Body").field("done", &self.done).finish_non_exhaustive()
    }
}

impl Body {
    /// Read the next chunk. `None` ends the body.
    ///
    /// # Errors
    ///
    /// Returns an [`Error`] if a read fails. The body ends after the error.
    pub async fn chunk(&mut self) -> Option<Result<Bytes, Error>> {
        std::future::poll_fn(|cx| self.poll_chunk(cx)).await
    }

    /// Poll for the next chunk. `None` ends the body.
    ///
    /// # Errors
    ///
    /// Returns an [`Error`] if a read fails. The body ends after the error.
    pub fn poll_chunk(&mut self, cx: &mut Context<'_>) -> Poll<Option<Result<Bytes, Error>>> {
        if self.done {
            return Poll::Ready(None);
        }
        if let Some(connection) = &mut self.connection {
            match Pin::new(connection).poll(cx) {
                Poll::Ready(Ok(())) => self.connection = None,
                Poll::Ready(Err(err)) => return self.fail(error_of(&err)),
                Poll::Pending => {}
            }
        }
        loop {
            match Pin::new(&mut self.incoming).poll_frame(cx) {
                Poll::Ready(Some(Ok(frame))) => {
                    // A trailer frame carries no body bytes.
                    if let Ok(data) = frame.into_data()
                        && !data.is_empty()
                    {
                        self.armed = None;
                        return Poll::Ready(Some(Ok(data)));
                    }
                }
                Poll::Ready(Some(Err(err))) => return self.fail(error_of(&err)),
                Poll::Ready(None) => {
                    self.done = true;
                    self.armed = None;
                    return Poll::Ready(None);
                }
                Poll::Pending => break,
            }
        }
        if self.armed.is_none()
            && let Some((at, error)) = earlier(self.idle_timeout.map(|idle| Instant::now() + idle), self.deadline)
        {
            // A deadline that already passed starts no read.
            if at <= Instant::now() {
                return self.fail(error);
            }
            match &mut self.timer {
                Some(timer) => timer.as_mut().reset(at),
                None => self.timer = Some(Box::pin(tokio::time::sleep_until(at))),
            }
            self.armed = Some(error);
        }
        if let (Some(error), Some(timer)) = (self.armed, &mut self.timer)
            && timer.as_mut().poll(cx).is_ready()
        {
            return self.fail(error);
        }
        Poll::Pending
    }

    fn fail(&mut self, error: Error) -> Poll<Option<Result<Bytes, Error>>> {
        self.done = true;
        self.connection = None;
        Poll::Ready(Some(Err(error)))
    }
}

#[cfg(test)]
mod tests;
