//! Stream one SSE response over HTTP/1.1 with hyper on tokio, and rustls for `https`. Each open uses its own
//! connection, so a fault before the request left proves that nothing was sent.

use std::future::Future;
use std::io;
use std::pin::{Pin, pin};
use std::sync::{Arc, OnceLock};
use std::task::{Context, Poll};
use std::time::{Duration, SystemTime, UNIX_EPOCH};

use bytes::Bytes;
use http::header::{
    ACCEPT, ACCEPT_ENCODING, CONNECTION, CONTENT_ENCODING, CONTENT_LENGTH, CONTENT_TYPE, HOST, USER_AGENT,
};
use http::{HeaderMap, HeaderName, HeaderValue, Method, Request, Uri};
use http_body_util::Full;
use hyper::body::{Body as _, Incoming};
use hyper::client::conn::http1;
use hyper_util::rt::TokioIo;
use rustls::pki_types::ServerName;
use tokio::io::{AsyncRead, AsyncWrite};
use tokio::net::TcpStream;
use tokio::time::{Instant, Sleep};

use crate::transport::{Body, BoxBody, BoxFuture, Fault, Head, Outgoing, Transport};

/// How an [`HttpTransport`] waits for the peer and names itself.
#[derive(Debug, Clone, PartialEq, Eq, Hash)]
pub struct HttpOptions {
    /// The longest wait for the peer. The connect, the send, and the head share one wait. Each body read has one
    /// wait. `None` sets no bound.
    pub idle_timeout: Option<Duration>,
    /// The client sends this value on every request, so a gateway can identify the agent. It must be a valid
    /// header value.
    pub user_agent: String,
}

impl HttpOptions {
    /// Options with `user_agent` and the default idle timeout of 300 seconds.
    pub fn new(user_agent: impl Into<String>) -> Self {
        HttpOptions {
            idle_timeout: Some(Duration::from_secs(300)),
            user_agent: user_agent.into(),
        }
    }
}

/// The error of [`HttpTransport::new`]. See its `Display` text.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash)]
pub struct InvalidUserAgent;

impl std::fmt::Display for InvalidUserAgent {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.write_str("the user agent is not a valid header value")
    }
}

impl std::error::Error for InvalidUserAgent {}

/// The built-in transport. It uses HTTP/1.1 over tokio, and rustls with the aws-lc-rs provider. On Unix outside Apple and
/// Android, the `webpki` verifier checks certificates against the system roots: the paths in `SSL_CERT_FILE` or
/// `SSL_CERT_DIR`, else the system bundle file. Elsewhere the platform verifier checks them. The key exchange offers the
/// hybrid post-quantum group `X25519MLKEM768` first.
#[derive(Debug)]
pub struct HttpTransport {
    idle_timeout: Option<Duration>,
    user_agent: HeaderValue,
    /// The TLS configuration, which the first `https` open builds. `None` keeps a failed build.
    tls: OnceLock<Option<Arc<rustls::ClientConfig>>>,
}

impl HttpTransport {
    /// Creates a transport with `options`. The first `https` open builds the TLS configuration.
    ///
    /// # Errors
    ///
    /// Returns [`InvalidUserAgent`] if the user agent is not a valid header value.
    pub fn new(options: HttpOptions) -> Result<Self, InvalidUserAgent> {
        let user_agent = HeaderValue::try_from(options.user_agent).map_err(|_| InvalidUserAgent)?;
        Ok(HttpTransport {
            idle_timeout: options.idle_timeout,
            user_agent,
            tls: OnceLock::new(),
        })
    }

    /// The TLS configuration. A failed build fails every `https` open of this transport.
    fn tls(&self) -> Result<Arc<rustls::ClientConfig>, Fault> {
        self.tls
            .get_or_init(|| {
                let provider = Arc::new(rustls::crypto::aws_lc_rs::default_provider());
                let builder = rustls::ClientConfig::builder_with_provider(provider)
                    .with_safe_default_protocol_versions()
                    .ok()?;
                Some(Arc::new(with_verifier(builder)?.with_no_client_auth()))
            })
            .clone()
            .ok_or(Fault::TlsSetupFailed)
    }

    async fn exchange(&self, request: &Outgoing<'_>, deadline: Option<Instant>) -> Result<(Head, BoxBody), Fault> {
        // `HeaderMap::with_capacity` panics above its size limit, so too many headers fail the request before it leaves.
        if request.headers().len() > MAX_HEADERS {
            return Err(Fault::InvalidRequest);
        }
        let target = Target::parse(request.url())?;
        let http_request = self.build(&target, request)?;

        // Connect, send, and the head wait share the idle deadline, so a silent peer never holds the call.
        let bound = earlier(self.idle_timeout.map(|idle| Instant::now() + idle), deadline);
        let mut sent = false;
        let head = match bound {
            None => self.connect_and_send(&target, http_request, &mut sent).await,
            Some((at, timed_out)) => {
                // A deadline that already passed starts no leg, so an expired request is never sent.
                if at <= Instant::now() {
                    return Err(Fault::ConnectTimeout);
                }
                let outcome =
                    tokio::time::timeout_at(at, self.connect_and_send(&target, http_request, &mut sent)).await;
                // A deadline that passed before the request left names the connect, so a repeat is known to be safe.
                outcome.unwrap_or(Err(if sent { timed_out } else { Fault::ConnectTimeout }))
            }
        };
        let (response, connection) = head?;
        let head = read_head(response.headers(), response.status().as_u16(), wall_clock_seconds());
        let body = HttpBody {
            connection: Some(connection),
            body: response.into_body(),
            idle_timeout: self.idle_timeout,
            deadline,
            timer: None,
            armed: None,
            done: false,
        };
        Ok((head, Box::pin(body)))
    }

    /// Build the request head: host, user agent, connection, length, type, accept, then the caller headers. hyper
    /// decides the wire order and the case of the fields.
    fn build(&self, target: &Target, request: &Outgoing<'_>) -> Result<Request<Full<Bytes>>, Fault> {
        let length = request.body_len();
        // hyper sends a body that owns its bytes, so the parts join here once.
        let mut body = Vec::with_capacity(length);
        for part in request.body() {
            body.extend_from_slice(part);
        }
        let mut headers = HeaderMap::with_capacity(7 + request.headers().len());
        headers.insert(HOST, target.host_header.clone());
        headers.insert(USER_AGENT, self.user_agent.clone());
        headers.insert(CONNECTION, HeaderValue::from_static("close"));
        headers.insert(CONTENT_LENGTH, HeaderValue::from(length));
        headers.insert(CONTENT_TYPE, HeaderValue::from_static("application/json"));
        // The provider sends SSE, so request it.
        headers.insert(ACCEPT, HeaderValue::from_static("text/event-stream"));
        // Without this field, RFC 9110 lets the server choose any compression. The decoder reads plain bytes only.
        headers.insert(ACCEPT_ENCODING, HeaderValue::from_static("identity"));
        for header in request.headers() {
            let name = HeaderName::from_bytes(header.name.as_bytes()).map_err(|_| Fault::InvalidRequest)?;
            // Any byte but a control byte is valid, as `route::valid_header_value` checks.
            let value = HeaderValue::from_bytes(header.value.as_bytes()).map_err(|_| Fault::InvalidRequest)?;
            headers.append(name, value);
        }
        let mut http_request = Request::new(Full::new(Bytes::from(body)));
        *http_request.method_mut() = Method::POST;
        *http_request.uri_mut() = target.path.clone();
        *http_request.headers_mut() = headers;
        Ok(http_request)
    }

    /// Open the connection, send the request, and read the head. `sent` turns true once the connection carries the
    /// request, because the provider may hold it from there.
    async fn connect_and_send(
        &self,
        target: &Target,
        request: Request<Full<Bytes>>,
        sent: &mut bool,
    ) -> Result<(http::Response<Incoming>, Connection), Fault> {
        // A TLS configuration that fails to build fails the open before it connects.
        let tls = if target.tls { Some(self.tls()?) } else { None };
        let mut addresses = tokio::net::lookup_host((target.host.as_str(), target.port))
            .await
            .map_err(|_| Fault::DnsFailed)?
            .peekable();
        if addresses.peek().is_none() {
            return Err(Fault::DnsFailed);
        }
        let mut tcp = None;
        for address in addresses {
            if let Ok(stream) = TcpStream::connect(address).await {
                tcp = Some(stream);
                break;
            }
        }
        let tcp = tcp.ok_or(Fault::ConnectFailed)?;
        // The request goes out in one write, so no small segment waits for an acknowledgment.
        tcp.set_nodelay(true).map_err(|_| Fault::ConnectFailed)?;
        let socket: Box<dyn Socket> = if let Some(tls) = tls {
            let name = ServerName::try_from(target.host.clone()).map_err(|_| Fault::BadUrl)?;
            let stream = tokio_rustls::TlsConnector::from(tls)
                .connect(name, tcp)
                .await
                .map_err(|_| Fault::ConnectFailed)?;
            Box::new(stream)
        } else {
            Box::new(tcp)
        };
        *sent = true;
        send(socket, request).await
    }
}

impl Transport for HttpTransport {
    fn open<'a>(
        &'a self,
        request: &'a Outgoing<'_>,
        deadline: Option<std::time::Instant>,
    ) -> BoxFuture<'a, Result<(Head, BoxBody), Fault>> {
        // The request deadline counts from here, before any preparation.
        Box::pin(self.exchange(request, deadline.map(Instant::from_std)))
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

/// The byte stream of one connection: plain TCP, or TLS over TCP.
trait Socket: AsyncRead + AsyncWrite + Send + Unpin {}

impl<T: AsyncRead + AsyncWrite + Send + Unpin> Socket for T {}

type Connection = http1::Connection<TokioIo<Box<dyn Socket>>, Full<Bytes>>;

/// Send the request on a fresh connection, and drive the connection until the head arrives.
async fn send(
    socket: Box<dyn Socket>,
    request: Request<Full<Bytes>>,
) -> Result<(http::Response<Incoming>, Connection), Fault> {
    let (mut sender, mut connection) = http1::handshake(TokioIo::new(socket))
        .await
        .map_err(|err| fault_of(&err))?;
    let mut response = pin!(sender.send_request(request));
    let response = std::future::poll_fn(|cx| {
        if let Poll::Ready(result) = response.as_mut().poll(cx) {
            return Poll::Ready(result.map_err(|err| fault_of(&err)));
        }
        match Pin::new(&mut connection).poll(cx) {
            // The connection ended before the head, so the response holds its cause.
            Poll::Ready(Err(err)) => Poll::Ready(Err(fault_of(&err))),
            Poll::Ready(Ok(())) => match response.as_mut().poll(cx) {
                Poll::Ready(result) => Poll::Ready(result.map_err(|err| fault_of(&err))),
                Poll::Pending => Poll::Ready(Err(Fault::ConnectionLost)),
            },
            Poll::Pending => Poll::Pending,
        }
    })
    .await?;
    drop(sender);
    let status = response.status().as_u16();
    // The client never follows a redirect, so the key never reaches another origin. A 304 has no redirect target.
    if (300..400).contains(&status) && status != 304 {
        return Err(Fault::RedirectRefused);
    }
    check_content_encoding(response.headers())?;
    Ok((response, connection))
}

/// The request asks for `identity`, so a body in any other `content-encoding` is a malformed response.
fn check_content_encoding(headers: &HeaderMap) -> Result<(), Fault> {
    let identity = |value: &HeaderValue| value.as_bytes().trim_ascii().eq_ignore_ascii_case(b"identity");
    if headers.get_all(CONTENT_ENCODING).iter().all(identity) {
        Ok(())
    } else {
        Err(Fault::MalformedResponse)
    }
}

/// The most caller headers one request takes. A `HeaderMap` holds at most 32768 fields, and the transport writes seven.
const MAX_HEADERS: usize = 32_000;

/// Name one hyper failure. A truncated message is a lost connection, and a parse failure a malformed response.
fn fault_of(err: &hyper::Error) -> Fault {
    if err.is_parse() || err.is_parse_status() {
        return Fault::MalformedResponse;
    }
    if err.is_incomplete_message() {
        return Fault::ConnectionLost;
    }
    let mut source = std::error::Error::source(err);
    while let Some(cause) = source {
        if let Some(io) = cause.downcast_ref::<io::Error>() {
            return io_fault(io);
        }
        source = cause.source();
    }
    Fault::ConnectionLost
}

/// Name one read failure. A TLS failure ends the connection, so it is a lost connection. Other invalid bytes are a
/// malformed response.
fn io_fault(io: &io::Error) -> Fault {
    if matches!(io.get_ref(), Some(inner) if inner.is::<rustls::Error>()) {
        return Fault::ConnectionLost;
    }
    match io.kind() {
        io::ErrorKind::InvalidData | io::ErrorKind::InvalidInput => Fault::MalformedResponse,
        _ => Fault::ConnectionLost,
    }
}

/// Choose the earlier of the idle and the request deadline, with the fault that the chosen deadline names.
fn earlier(idle: Option<Instant>, request: Option<Instant>) -> Option<(Instant, Fault)> {
    match (idle, request) {
        (None, None) => None,
        // The earlier deadline binds, and names the error.
        (None, Some(request)) => Some((request, Fault::RequestTimeout)),
        (Some(idle), Some(request)) if request <= idle => Some((request, Fault::RequestTimeout)),
        (Some(idle), _) => Some((idle, Fault::IdleTimeout)),
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
    fn parse(url: &str) -> Result<Self, Fault> {
        let uri: Uri = url.parse().map_err(|_| Fault::BadUrl)?;
        let tls = match uri.scheme_str() {
            Some("http" | "ws") => false,
            Some("https" | "wss") => true,
            _ => return Err(Fault::BadUrl),
        };
        let authority = uri.authority().ok_or(Fault::BadUrl)?;
        let host = authority.host();
        if host.is_empty() {
            return Err(Fault::BadUrl);
        }
        let port = authority.port_u16().unwrap_or(if tls { 443 } else { 80 });
        let host_header = match authority.port() {
            Some(port) => format!("{host}:{port}"),
            None => host.to_owned(),
        };
        let host_header = HeaderValue::try_from(host_header).map_err(|_| Fault::BadUrl)?;
        let path = uri.path_and_query().map_or("/", http::uri::PathAndQuery::as_str);
        Ok(Target {
            tls,
            host: host.trim_start_matches('[').trim_end_matches(']').to_owned(),
            port,
            host_header,
            path: path.parse().map_err(|_| Fault::BadUrl)?,
        })
    }
}

/// One response body. The body owns its connection, and drives the connection while the caller reads.
struct HttpBody {
    /// `None` once the connection ended.
    connection: Option<Connection>,
    body: Incoming,
    idle_timeout: Option<Duration>,
    deadline: Option<Instant>,
    /// The timer of the read deadlines. Each read for more bytes resets it, so the body allocates it once.
    timer: Option<Pin<Box<Sleep>>>,
    /// The fault of the armed deadline, or `None` while no read waits.
    armed: Option<Fault>,
    /// The body ended or failed. It returns nothing more.
    done: bool,
}

impl HttpBody {
    fn fail(&mut self, fault: Fault) -> Poll<Option<Result<Bytes, Fault>>> {
        self.done = true;
        self.connection = None;
        Poll::Ready(Some(Err(fault)))
    }
}

impl Body for HttpBody {
    fn poll_chunk(self: Pin<&mut Self>, cx: &mut Context<'_>) -> Poll<Option<Result<Bytes, Fault>>> {
        let this = self.get_mut();
        if this.done {
            return Poll::Ready(None);
        }
        if let Some(connection) = &mut this.connection {
            match Pin::new(connection).poll(cx) {
                Poll::Ready(Ok(())) => this.connection = None,
                Poll::Ready(Err(err)) => return this.fail(fault_of(&err)),
                Poll::Pending => {}
            }
        }
        loop {
            match Pin::new(&mut this.body).poll_frame(cx) {
                Poll::Ready(Some(Ok(frame))) => {
                    // A trailer frame carries no body bytes.
                    if let Ok(data) = frame.into_data()
                        && !data.is_empty()
                    {
                        this.armed = None;
                        return Poll::Ready(Some(Ok(data)));
                    }
                }
                Poll::Ready(Some(Err(err))) => return this.fail(fault_of(&err)),
                Poll::Ready(None) => {
                    this.done = true;
                    this.armed = None;
                    return Poll::Ready(None);
                }
                Poll::Pending => break,
            }
        }
        if this.armed.is_none()
            && let Some((at, fault)) = earlier(this.idle_timeout.map(|idle| Instant::now() + idle), this.deadline)
        {
            // A deadline that already passed starts no read.
            if at <= Instant::now() {
                return this.fail(fault);
            }
            match &mut this.timer {
                Some(timer) => timer.as_mut().reset(at),
                None => this.timer = Some(Box::pin(tokio::time::sleep_until(at))),
            }
            this.armed = Some(fault);
        }
        if let (Some(fault), Some(timer)) = (this.armed, &mut this.timer)
            && timer.as_mut().poll(cx).is_ready()
        {
            return this.fail(fault);
        }
        Poll::Pending
    }
}

fn wall_clock_seconds() -> i64 {
    SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map_or(0, |since| i64::try_from(since.as_secs()).unwrap_or(i64::MAX))
}

/// Read the status, the retry hints, and the request id. `now` is the wall-clock time in seconds since the epoch,
/// for an HTTP-date retry hint.
fn read_head(headers: &HeaderMap, status: u16, now: i64) -> Head {
    let mut head = Head::new(status);
    for (name, value) in headers {
        let value = value.as_bytes();
        let text = std::str::from_utf8(value).ok();
        match name.as_str() {
            "request-id" | "x-request-id" => {
                if head.request_id.is_none() {
                    head.request_id = Some(String::from_utf8_lossy(value).into_owned());
                }
            }
            // The millisecond form wins. Both SDK families read it first.
            "retry-after-ms" => {
                if let Some(ms) = text.and_then(|text| decimal_ms(text, 1.0)) {
                    head.retry_after_ms = Some(ms);
                }
            }
            "retry-after" => {
                if head.retry_after_ms.is_none() {
                    head.retry_after_ms = text.and_then(|text| retry_after_ms(text, now));
                }
            }
            "x-should-retry" => {
                if value.eq_ignore_ascii_case(b"true") {
                    head.should_retry = Some(true);
                }
                if value.eq_ignore_ascii_case(b"false") {
                    head.should_retry = Some(false);
                }
            }
            _ => {}
        }
    }
    head
}

fn retry_after_ms(value: &str, now: i64) -> Option<u64> {
    if let Some(ms) = decimal_ms(value, 1000.0) {
        return Some(ms);
    }
    let at = imf_fixdate(value)?;
    if at <= now {
        return Some(0);
    }
    Some(u64::try_from(at - now).ok()?.saturating_mul(1000))
}

fn decimal_ms(value: &str, ms_per_unit: f64) -> Option<u64> {
    let units: f64 = value.parse().ok()?;
    if !units.is_finite() || units < 0.0 {
        return None;
    }
    #[expect(
        clippy::cast_possible_truncation,
        clippy::cast_sign_loss,
        reason = "a float cast saturates, so a huge delay becomes `u64::MAX`"
    )]
    let ms = (units * ms_per_unit).ceil() as u64;
    Some(ms)
}

fn imf_fixdate(value: &str) -> Option<i64> {
    const DAYS: [&[u8]; 7] = [b"Mon", b"Tue", b"Wed", b"Thu", b"Fri", b"Sat", b"Sun"];
    const MONTHS: [&[u8]; 12] = [
        b"Jan", b"Feb", b"Mar", b"Apr", b"May", b"Jun", b"Jul", b"Aug", b"Sep", b"Oct", b"Nov", b"Dec",
    ];
    let bytes = value.as_bytes();
    if bytes.len() != 29 || &bytes[3..5] != b", " || &bytes[25..] != b" GMT" {
        return None;
    }
    if [7, 11, 16].iter().any(|&i| bytes[i] != b' ') || bytes[19] != b':' || bytes[22] != b':' {
        return None;
    }
    if !DAYS.contains(&&bytes[0..3]) {
        return None;
    }
    let month = u8::try_from(MONTHS.iter().position(|name| *name == &bytes[8..11])? + 1).ok()?;
    let number = |range: std::ops::Range<usize>| value.get(range)?.parse::<u16>().ok();
    let day = number(5..7)?;
    let year = number(12..16)?;
    let hour = number(17..19)?;
    let minute = number(20..22)?;
    let second = number(23..25)?;
    if day == 0 || day > days_in_month(year, month) || hour > 23 || minute > 59 || second > 60 {
        return None;
    }
    Some(
        days_from_civil(year, month, day) * 86_400
            + i64::from(hour) * 3600
            + i64::from(minute) * 60
            + i64::from(second),
    )
}

fn days_in_month(year: u16, month: u8) -> u16 {
    let leap = year.is_multiple_of(4) && (!year.is_multiple_of(100) || year.is_multiple_of(400));
    match month {
        2 if leap => 29,
        2 => 28,
        4 | 6 | 9 | 11 => 30,
        _ => 31,
    }
}

fn days_from_civil(year: u16, month: u8, day: u16) -> i64 {
    let y = i64::from(year) - i64::from(month <= 2);
    let era = y.div_euclid(400);
    let yoe = y - era * 400;
    let m = i64::from(month);
    let doy = (153 * (if m > 2 { m - 3 } else { m + 9 }) + 2).div_euclid(5) + i64::from(day) - 1;
    let doe = yoe * 365 + yoe.div_euclid(4) - yoe.div_euclid(100) + doy;
    era * 146_097 + doe - 719_468
}

#[cfg(test)]
mod tests;
