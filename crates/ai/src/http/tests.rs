//! Loopback HTTP tests for [`HttpTransport`]: one real server and one real client per test.

use std::fmt::Write as _;
use std::time::Duration;

use tokio::io::{AsyncReadExt, AsyncWriteExt};
use tokio::net::{TcpListener, TcpStream};

use super::*;
use crate::encoder::Encoded;
use crate::failure::{Failure, ProviderKind};
use crate::request::{OriginRef, Protocol};
use crate::stream::{Options, Stream};
use crate::transport::Header;
use crate::transport::next_chunk;

const TEST_USER_AGENT: &str = "ai-test/0";

const CANNED_SSE: &str = "data: {\"type\":\"message_start\",\"message\":{\"usage\":{\"input_tokens\":1}}}\n\n\
                          data: {\"type\":\"message_stop\"}\n\n";

/// What one loopback server answers.
#[derive(Default)]
struct Server {
    status: u16,
    body: Vec<u8>,
    /// Bypass framing to send malformed or truncated wire bytes.
    raw_response: Option<&'static [u8]>,
    /// A redirect target. The client must never follow it.
    location: Option<&'static str>,
    /// Sent after the content type, in order.
    headers: Vec<(&'static str, &'static str)>,
    /// Send the body, then hold the stream open until the client closes it.
    stall: bool,
    /// Read the request, then send no head until the client closes the connection.
    silent: bool,
    /// Send each body byte as its own chunk, with a pause before each one.
    trickle: bool,
}

/// What the server saw of the request.
#[derive(Debug, Default)]
struct Seen {
    user_agents: Vec<String>,
    languages: Vec<String>,
    notes: Vec<String>,
    encodings: Vec<String>,
}

/// Read one request head and its body.
async fn read_request(stream: &mut TcpStream) -> Seen {
    let mut bytes = Vec::new();
    let mut buf = [0u8; 4096];
    let head_end = loop {
        let n = stream.read(&mut buf).await.unwrap();
        assert_ne!(n, 0, "the client closed before its head");
        bytes.extend_from_slice(&buf[..n]);
        if let Some(at) = bytes.windows(4).position(|w| w == b"\r\n\r\n") {
            break at + 4;
        }
    };
    let head = std::str::from_utf8(&bytes[..head_end]).unwrap();
    let mut seen = Seen::default();
    let mut length = 0;
    for line in head.split("\r\n").skip(1).filter(|line| !line.is_empty()) {
        let (name, value) = line.split_once(':').unwrap();
        let value = value.trim().to_owned();
        if name.eq_ignore_ascii_case("user-agent") {
            seen.user_agents.push(value);
        } else if name.eq_ignore_ascii_case("accept-language") {
            seen.languages.push(value);
        } else if name.eq_ignore_ascii_case("accept-encoding") {
            seen.encodings.push(value);
        } else if name.eq_ignore_ascii_case("x-note") {
            seen.notes.push(value);
        } else if name.eq_ignore_ascii_case("content-length") {
            length = value.parse().unwrap();
        }
    }
    while bytes.len() < head_end + length {
        let n = stream.read(&mut buf).await.unwrap();
        bytes.extend_from_slice(&buf[..n]);
    }
    seen
}

/// Wait until the client closes the connection.
async fn wait_for_close(stream: &mut TcpStream) {
    let mut buf = [0u8; 64];
    while matches!(stream.read(&mut buf).await, Ok(n) if n != 0) {}
}

/// Accept one connection and answer it as `server` says.
async fn serve_once(listener: TcpListener, server: Server) -> Seen {
    let (mut stream, _) = listener.accept().await.unwrap();
    let seen = read_request(&mut stream).await;
    if let Some(bytes) = server.raw_response {
        stream.write_all(bytes).await.unwrap();
        return seen;
    }
    if server.silent {
        wait_for_close(&mut stream).await;
        return seen;
    }
    let mut head = format!(
        "HTTP/1.1 {} OK\r\nconnection: close\r\ncontent-type: text/event-stream\r\n",
        server.status
    );
    if let Some(location) = server.location {
        _ = write!(head, "location: {location}\r\n");
    }
    for (name, value) in &server.headers {
        _ = write!(head, "{name}: {value}\r\n");
    }
    head.push_str("transfer-encoding: chunked\r\n\r\n");
    let mut out = head.into_bytes();
    if server.trickle {
        if stream.write_all(&out).await.is_err() {
            return seen;
        }
        for byte in &server.body {
            tokio::time::sleep(Duration::from_millis(1)).await;
            if stream
                .write_all(&[b'1', b'\r', b'\n', *byte, b'\r', b'\n'])
                .await
                .is_err()
            {
                return seen;
            }
        }
        out.clear();
    } else if !server.body.is_empty() {
        out.extend_from_slice(format!("{:x}\r\n", server.body.len()).as_bytes());
        out.extend_from_slice(&server.body);
        out.extend_from_slice(b"\r\n");
    }
    // A failed write means the client already closed, which a stalled exchange expects.
    if stream.write_all(&out).await.is_err() {
        return seen;
    }
    if server.stall {
        wait_for_close(&mut stream).await;
        return seen;
    }
    _ = stream.write_all(b"0\r\n\r\n").await;
    seen
}

/// Open an Anthropic stream with an empty request to the local server at `port`.
async fn open_stream(transport: &HttpTransport, port: u16) -> Stream {
    let url = format!("http://127.0.0.1:{port}/messages");
    let headers = source_headers();
    let encoded = Encoded {
        http: Outgoing::new(&url, &headers, b"{}"),
        protocol: Protocol::AnthropicMessages,
        origin: OriginRef {
            model: "m",
            base_url: "",
        },
    };
    Stream::open(transport, &encoded, Options::default()).await
}

/// The headers every exchange sends. Repeated lines of a list-valued header keep their order.
fn source_headers() -> Vec<Header> {
    [
        ("x-api-key", "test-key"),
        ("Accept-Language", "en"),
        ("accept-language", "es"),
        ("x-note", "café"),
    ]
    .map(|(name, value)| Header::from_static(name, value))
    .to_vec()
}

/// What the client observed of one exchange.
#[derive(Debug, Default)]
struct ClientOut {
    head: Option<Head>,
    bytes: Vec<u8>,
    err: Option<Fault>,
}

/// Open the request and read the whole body. The request input drops before the body is read.
async fn run_client(transport: &HttpTransport, port: u16, deadline: Option<std::time::Instant>) -> ClientOut {
    let mut out = ClientOut::default();
    let opened = {
        let url = format!("http://127.0.0.1:{port}/messages");
        let headers = source_headers();
        let body = b"{}".to_vec();
        let request = Outgoing::new(&url, &headers, &body);
        transport.open(&request, deadline).await
    };
    let mut body = match opened {
        Ok((head, body)) => {
            out.head = Some(head);
            body
        }
        Err(fault) => {
            out.err = Some(fault);
            return out;
        }
    };
    while let Some(chunk) = next_chunk(&mut body).await {
        match chunk {
            Ok(bytes) => out.bytes.extend_from_slice(&bytes),
            Err(fault) => {
                out.err = Some(fault);
                break;
            }
        }
    }
    out
}

fn transport(idle_timeout: Option<Duration>) -> HttpTransport {
    HttpTransport::new(HttpOptions {
        idle_timeout,
        user_agent: TEST_USER_AGENT.to_owned(),
    })
    .unwrap()
}

/// Run one server and one client exchange on a private loopback port.
async fn exchange(
    server: Server,
    transport: &HttpTransport,
    deadline: Option<std::time::Instant>,
) -> (Seen, ClientOut) {
    let listener = TcpListener::bind("127.0.0.1:0").await.unwrap();
    let port = listener.local_addr().unwrap().port();
    let server = tokio::spawn(serve_once(listener, server));
    let out = run_client(transport, port, deadline).await;
    (server.await.unwrap(), out)
}

fn after(ms: u64) -> std::time::Instant {
    std::time::Instant::now() + Duration::from_millis(ms)
}

#[tokio::test]
async fn streams_sse_body() {
    for transport in [
        transport(None),
        HttpTransport::new(HttpOptions::new(TEST_USER_AGENT)).unwrap(),
    ] {
        let server = Server {
            status: 200,
            body: CANNED_SSE.into(),
            ..Server::default()
        };
        let (seen, out) = exchange(server, &transport, None).await;
        assert_eq!(out.err, None);
        assert_eq!(out.head.unwrap().status, 200);
        assert_eq!(out.bytes, CANNED_SSE.as_bytes());
        assert_eq!(seen.user_agents, [TEST_USER_AGENT]);
        assert_eq!(seen.languages, ["en", "es"]);
        assert_eq!(seen.notes, ["café"]);
    }
}

#[tokio::test]
async fn non_200_response_keeps_status_id_and_body() {
    let long = format!(
        "{{\"error\":{{\"type\":\"invalid_request_error\",\"message\":\"{}\"}}}}",
        "x".repeat(5000)
    );
    let server = Server {
        status: 400,
        body: long.clone().into(),
        headers: vec![("request-id", "req_123")],
        ..Server::default()
    };
    let (_, out) = exchange(server, &transport(None), None).await;
    assert_eq!(out.err, None);
    let head = out.head.unwrap();
    assert_eq!(head.status, 400);
    assert_eq!(head.request_id.as_deref(), Some("req_123"));
    assert_eq!(out.bytes, long.as_bytes());
}

#[tokio::test]
async fn head_reads_request_id_and_retry_hints() {
    type Case = (
        Vec<(&'static str, &'static str)>,
        Option<&'static str>,
        Option<u64>,
        Option<bool>,
    );
    let cases: [Case; 3] = [
        // The millisecond form wins over a later delay in seconds, the first request id wins, and `false` vetoes a
        // repeat.
        (
            vec![
                ("x-request-id", "first"),
                ("request-id", "second"),
                ("retry-after-ms", "1500"),
                ("retry-after", "3"),
                ("x-should-retry", "false"),
            ],
            Some("first"),
            Some(1500),
            Some(false),
        ),
        // Delay seconds alone set the hint, and `true` asks for a repeat.
        (
            vec![("Retry-After", "3"), ("x-should-retry", "true")],
            None,
            Some(3000),
            Some(true),
        ),
        // A decimal millisecond delay counts, and no `x-should-retry` leaves the decision to the caller.
        (vec![("retry-after-ms", "250.5")], None, Some(251), None),
    ];
    for (headers, request_id, retry_after_ms, should_retry) in cases {
        let server = Server {
            status: 429,
            headers,
            ..Server::default()
        };
        let (_, out) = exchange(server, &transport(None), None).await;
        assert_eq!(out.err, None);
        let head = out.head.unwrap();
        assert_eq!(head.request_id.as_deref(), request_id);
        assert_eq!(head.retry_after_ms, retry_after_ms);
        assert_eq!(head.should_retry, should_retry);
    }
}

#[tokio::test]
async fn stalled_body_hits_idle_timeout() {
    // The server sends the head, then holds the stream open with no body until the client closes it.
    let server = Server {
        status: 200,
        stall: true,
        ..Server::default()
    };
    let (_, out) = exchange(server, &transport(Some(Duration::from_millis(50))), None).await;
    assert_eq!(out.err, Some(Fault::IdleTimeout));
    assert_eq!(out.head.unwrap().status, 200);
}

#[tokio::test]
async fn silent_peer_hits_idle_timeout() {
    let server = Server {
        status: 200,
        silent: true,
        ..Server::default()
    };
    let (_, out) = exchange(server, &transport(Some(Duration::from_millis(50))), None).await;
    assert_eq!(out.err, Some(Fault::IdleTimeout));
}

#[tokio::test]
async fn redirect_is_refused() {
    // The client must reject a 302 response to another origin to keep the key private.
    let server = Server {
        status: 302,
        location: Some("http://evil.example/steal"),
        ..Server::default()
    };
    let (_, out) = exchange(server, &transport(None), None).await;
    assert_eq!(out.err, Some(Fault::RedirectRefused));
    assert_eq!(out.bytes, b"");
}

// A real body returns a pending read between bytes, so a dropped `next` must keep every partial line.
#[tokio::test]
async fn dropped_next_loses_no_event_over_http() {
    let sse = [
        r#"{"type":"message_start","message":{"usage":{"input_tokens":3}}}"#,
        r#"{"type":"content_block_start","index":0,"content_block":{"type":"text","text":""}}"#,
        r#"{"type":"content_block_delta","index":0,"delta":{"type":"text_delta","text":"Hi"}}"#,
        r#"{"type":"content_block_stop","index":0}"#,
        r#"{"type":"message_delta","delta":{"stop_reason":"end_turn"},"usage":{"output_tokens":1}}"#,
        r#"{"type":"message_stop"}"#,
    ]
    .map(|data| format!("data: {data}\n\n"))
    .concat();
    let server = Server {
        status: 200,
        body: sse.into(),
        trickle: true,
        ..Server::default()
    };
    let listener = TcpListener::bind("127.0.0.1:0").await.unwrap();
    let port = listener.local_addr().unwrap().port();
    let served = tokio::spawn(serve_once(listener, server));
    let transport = transport(None);
    let mut stream = open_stream(&transport, port).await;
    let mut lines = Vec::new();
    let mut drops = 0;
    loop {
        // The first poll of `yield_now` is pending, so each pending `next` drops after one poll.
        tokio::select! {
            biased;
            item = stream.next() => match item {
                Some(item) => lines.push(crate::stream::testing::item_line(&item)),
                None => break,
            },
            () = tokio::task::yield_now() => drops += 1,
        }
    }
    assert!(drops > 100, "the body waited {drops} times");
    assert_eq!(
        lines.join("\n"),
        "start 0 text\n\
         text_delta 0 \"Hi\"\n\
         stop 0 text\n\
         done stop \"end_turn\" input=3 output=1"
    );
    drop(stream);
    served.await.unwrap();
}

#[tokio::test]
async fn error_status_and_error_event_fail_alike() {
    let answer = r#"{"type":"error","error":{"type":"overloaded_error","message":"Overloaded"}}"#;
    for status in [503, 200] {
        let body = if status == 200 {
            format!("data: {answer}\n\n")
        } else {
            answer.to_owned()
        };
        let server = Server {
            status,
            body: body.into(),
            headers: vec![("request-id", "req-real-http")],
            ..Server::default()
        };
        let listener = TcpListener::bind("127.0.0.1:0").await.unwrap();
        let port = listener.local_addr().unwrap().port();
        let served = tokio::spawn(serve_once(listener, server));
        let transport = transport(None);
        let mut stream = open_stream(&transport, port).await;
        assert_eq!(stream.info().status, Some(status));
        assert_eq!(stream.info().request_id.as_deref(), Some("req-real-http"));
        let mut failure = None;
        while let Some(event) = stream.next().await {
            if let Err(cause) = event {
                failure = Some(cause);
            }
        }
        assert_eq!(failure, Some(Failure::Provider(ProviderKind::ServerError)));
        assert_eq!(stream.info().error_body.as_deref(), Some(answer.as_bytes()));
        drop(stream);
        served.await.unwrap();
    }
}

#[tokio::test]
async fn request_deadline_wins_over_longer_idle_timeout() {
    for idle in [None, Some(Duration::from_secs(30))] {
        let server = Server {
            status: 200,
            stall: true,
            ..Server::default()
        };
        let (_, out) = exchange(server, &transport(idle), Some(after(50))).await;
        assert_eq!(out.err, Some(Fault::RequestTimeout));
        assert_eq!(out.head.unwrap().status, 200);
    }
}

// No leg starts once the deadline passed, so the request never leaves and a repeat is known to be safe.
#[tokio::test]
async fn expired_deadline_fails_before_send() {
    let listener = TcpListener::bind("127.0.0.1:0").await.unwrap();
    let port = listener.local_addr().unwrap().port();
    let out = run_client(
        &transport(Some(Duration::from_secs(300))),
        port,
        Some(std::time::Instant::now()),
    )
    .await;
    assert_eq!(out.err, Some(Fault::ConnectTimeout));
    // An expired request opens no connection.
    let accepted = tokio::time::timeout(Duration::from_millis(50), listener.accept()).await;
    assert!(accepted.is_err(), "the client connected after its deadline");
}

// The handshake never ends, so the idle deadline passes before the request leaves, and the fault names the connect.
#[tokio::test]
async fn stalled_handshake_hits_connect_timeout() {
    let listener = TcpListener::bind("127.0.0.1:0").await.unwrap();
    let port = listener.local_addr().unwrap().port();
    let peer = tokio::spawn(async move {
        let (stream, _) = listener.accept().await.unwrap();
        tokio::time::sleep(Duration::from_secs(5)).await;
        drop(stream);
    });
    let url = format!("https://127.0.0.1:{port}/messages");
    let request = Outgoing::new(&url, &[], b"{}");
    let fault = transport(Some(Duration::from_millis(50)))
        .open(&request, None)
        .await
        .err();
    assert_eq!(fault, Some(Fault::ConnectTimeout));
    peer.abort();
}

#[tokio::test]
async fn silent_peer_hits_request_deadline() {
    let server = Server {
        status: 200,
        silent: true,
        ..Server::default()
    };
    let (_, out) = exchange(server, &transport(None), Some(after(50))).await;
    assert_eq!(out.err, Some(Fault::RequestTimeout));
}

#[tokio::test]
async fn content_length_body_drains_after_request_drops() {
    let server = Server {
        raw_response: Some(b"HTTP/1.1 200 OK\r\nContent-Length: 4\r\nConnection: close\r\n\r\nbody"),
        ..Server::default()
    };
    let (_, out) = exchange(server, &transport(None), None).await;
    assert_eq!(out.err, None);
    assert_eq!(out.head.unwrap().status, 200);
    assert_eq!(out.bytes, b"body");
}

#[tokio::test]
async fn malformed_or_truncated_body_fails() {
    let cases: [(&'static [u8], Fault); 3] = [
        (
            b"HTTP/1.1 200 OK\r\nContent-Length: 4\r\nConnection: close\r\n\r\nx",
            Fault::ConnectionLost,
        ),
        (
            b"HTTP/1.1 200 OK\r\nTransfer-Encoding: chunked\r\nConnection: close\r\n\r\n1\rX",
            Fault::MalformedResponse,
        ),
        (
            b"HTTP/1.1 200 OK\r\nTransfer-Encoding: chunked\r\nConnection: close\r\n\r\n3\r\nx",
            Fault::ConnectionLost,
        ),
    ];
    for (bytes, cause) in cases {
        let server = Server {
            raw_response: Some(bytes),
            ..Server::default()
        };
        let (_, out) = exchange(server, &transport(None), None).await;
        assert_eq!(out.err, Some(cause), "{}", String::from_utf8_lossy(bytes));
        assert_eq!(out.head.unwrap().status, 200);
    }
}

// A drop is the cancellation of Rust: the open future and the body each own the connection, so a drop closes it.
#[tokio::test]
async fn cancelled_open_and_read_release_connection() {
    for body_wait in [false, true] {
        let server = Server {
            status: 200,
            silent: !body_wait,
            stall: body_wait,
            ..Server::default()
        };
        let listener = TcpListener::bind("127.0.0.1:0").await.unwrap();
        let port = listener.local_addr().unwrap().port();
        // The server returns only once the client closed the connection.
        let served = tokio::spawn(serve_once(listener, server));
        let transport = transport(Some(Duration::from_secs(30)));
        let url = format!("http://127.0.0.1:{port}/messages");
        let body = b"{}".to_vec();
        let headers = source_headers();
        let request = Outgoing::new(&url, &headers, &body);
        if body_wait {
            let (head, mut body) = transport.open(&request, None).await.unwrap();
            assert_eq!(head.status, 200);
            let read = tokio::time::timeout(Duration::from_millis(50), next_chunk(&mut body)).await;
            assert!(read.is_err(), "the stalled body returned a chunk");
            drop(body);
        } else {
            let opened = tokio::time::timeout(Duration::from_millis(50), transport.open(&request, None)).await;
            assert!(opened.is_err(), "the silent peer answered a head");
        }
        tokio::time::timeout(Duration::from_secs(5), served)
            .await
            .unwrap()
            .unwrap();
    }
}

#[tokio::test]
async fn shared_transport_opens_concurrently() {
    let transport = transport(Some(Duration::from_secs(5)));
    let gate = Arc::new(tokio::sync::Barrier::new(8));
    let mut ports = Vec::new();
    let mut servers = tokio::task::JoinSet::new();
    for _ in 0..8 {
        let listener = TcpListener::bind("127.0.0.1:0").await.unwrap();
        ports.push(listener.local_addr().unwrap().port());
        let gate = gate.clone();
        servers.spawn(async move {
            let (mut stream, _) = listener.accept().await.unwrap();
            read_request(&mut stream).await;
            gate.wait().await;
            let response = format!(
                "HTTP/1.1 200 OK\r\nConnection: close\r\nContent-Length: {}\r\n\r\n{CANNED_SSE}",
                CANNED_SSE.len()
            );
            stream.write_all(response.as_bytes()).await.unwrap();
        });
    }
    let clients = futures_join(ports.iter().map(|&port| run_client(&transport, port, None)));
    // No server answers until all eight requests arrive, so serialized exchanges cannot pass.
    let outcome = tokio::time::timeout(Duration::from_secs(5), async {
        let outputs = clients.await;
        let mut served = Vec::new();
        while let Some(result) = servers.join_next().await {
            served.push(result);
        }
        (outputs, served)
    })
    .await;
    if outcome.is_err() {
        servers.shutdown().await;
    }
    let (outputs, served) = outcome.expect("not every exchange finished before the bound");
    for server in served {
        server.unwrap();
    }
    for out in outputs {
        assert_eq!(out.err, None);
        assert_eq!(out.head.unwrap().status, 200);
        assert_eq!(out.bytes, CANNED_SSE.as_bytes());
    }
}

/// Poll every future on this task until all finish, so the opens share one thread as yuke's sessions do.
async fn futures_join<F: Future>(futures: impl Iterator<Item = F>) -> Vec<F::Output> {
    let mut pending: Vec<Pin<Box<F>>> = futures.map(Box::pin).collect();
    let mut done: Vec<Option<F::Output>> = pending.iter().map(|_| None).collect();
    std::future::poll_fn(|cx| {
        let mut all = true;
        for (future, slot) in pending.iter_mut().zip(done.iter_mut()) {
            if slot.is_none() {
                match future.as_mut().poll(cx) {
                    Poll::Ready(output) => *slot = Some(output),
                    Poll::Pending => all = false,
                }
            }
        }
        if all { Poll::Ready(()) } else { Poll::Pending }
    })
    .await;
    done.into_iter().flatten().collect()
}

/// Open `url` with a short idle timeout, and return the fault.
async fn open_fault(url: &str) -> Option<Fault> {
    let transport = transport(Some(Duration::from_secs(5)));
    let request = Outgoing::new(url, &[], b"{}");
    transport.open(&request, None).await.err()
}

// Each fault here happens before the request left, so the stream records it as definitely unsent.
#[tokio::test]
async fn connect_failures_send_nothing() {
    let listener = TcpListener::bind("127.0.0.1:0").await.unwrap();
    let port = listener.local_addr().unwrap().port();
    drop(listener);
    let fault = open_fault(&format!("http://127.0.0.1:{port}/messages")).await;
    assert_eq!(fault, Some(Fault::ConnectFailed));
    assert!(fault.is_some_and(Fault::sent_nothing));
    // The `.invalid` top-level name never resolves (RFC 2606).
    let fault = open_fault("http://host.invalid/messages").await;
    assert_eq!(fault, Some(Fault::DnsFailed));
    assert!(fault.is_some_and(Fault::sent_nothing));

    // A plain HTTP peer answers the TLS hello with bytes that are no handshake.
    let listener = TcpListener::bind("127.0.0.1:0").await.unwrap();
    let port = listener.local_addr().unwrap().port();
    let peer = tokio::spawn(async move {
        let (mut stream, _) = listener.accept().await.unwrap();
        _ = stream.write_all(b"HTTP/1.1 400 Bad Request\r\n\r\n").await;
    });
    let fault = open_fault(&format!("https://127.0.0.1:{port}/messages")).await;
    assert_eq!(fault, Some(Fault::ConnectFailed));
    assert!(fault.is_some_and(Fault::sent_nothing));
    peer.await.unwrap();
}

// The client offers the hybrid post-quantum group `X25519MLKEM768` first.
#[test]
fn tls_prefers_post_quantum_key_exchange() {
    let transport = transport(None);
    let first = transport
        .tls()
        .unwrap()
        .crypto_provider()
        .kx_groups
        .first()
        .map(|group| group.name());
    assert_eq!(first, Some(rustls::NamedGroup::X25519MLKEM768));
}

// Linux reads certificate-file settings. macOS uses the system certificate store.
#[cfg(target_os = "linux")]
#[tokio::test]
async fn missing_root_certificates_fail_only_https() {
    // A child process isolates the root-store settings from the other tests.
    const NO_ROOTS_CHILD: &str = "AI_TEST_NO_ROOTS_CHILD";

    if std::env::var_os(NO_ROOTS_CHILD).is_none() {
        let status = std::process::Command::new(std::env::current_exe().unwrap())
            .args(["--exact", "http::tests::missing_root_certificates_fail_only_https"])
            .env(NO_ROOTS_CHILD, "1")
            .env("SSL_CERT_FILE", "/dev/null")
            .env_remove("SSL_CERT_DIR")
            .stdout(std::process::Stdio::null())
            .status()
            .unwrap();
        assert!(status.success());
        return;
    }
    let transport = transport(None);
    for _ in 0..2 {
        let request = Outgoing::new("https://127.0.0.1:9/messages", &[], b"{}");
        let fault = transport.open(&request, None).await.err();
        assert_eq!(fault, Some(Fault::TlsSetupFailed));
        assert!(fault.is_some_and(Fault::sent_nothing));
    }
    let server = Server {
        status: 200,
        body: CANNED_SSE.into(),
        ..Server::default()
    };
    let (_, out) = exchange(server, &transport, None).await;
    assert_eq!(out.err, None);
}

#[test]
fn invalid_user_agent_is_rejected() {
    let options = HttpOptions::new("bad\r\n");
    assert!(matches!(HttpTransport::new(options), Err(InvalidUserAgent)));
}

#[test]
fn retry_after_reads_seconds_or_http_date() {
    let now = 784_111_777; // Sun, 06 Nov 1994 08:49:37 GMT
    assert_eq!(imf_fixdate("Sun, 06 Nov 1994 08:49:37 GMT"), Some(now));
    assert_eq!(imf_fixdate("Thu, 01 Jan 1970 00:00:00 GMT"), Some(0));
    assert_eq!(imf_fixdate("Tue, 29 Feb 2000 00:00:00 GMT"), Some(951_782_400));
    assert_eq!(retry_after_ms("120", now), Some(120_000));
    // Both SDKs read the delay with `parseFloat`, so a decimal and a sign count.
    assert_eq!(retry_after_ms("1.5", now), Some(1_500));
    assert_eq!(retry_after_ms("+5", now), Some(5_000));
    assert_eq!(retry_after_ms("18446744073709551615999", now), Some(u64::MAX));
    assert_eq!(retry_after_ms("Sun, 06 Nov 1994 08:50:07 GMT", now), Some(30_000));
    // A date in the past is no delay.
    assert_eq!(retry_after_ms("Sun, 06 Nov 1994 08:00:00 GMT", now), Some(0));
    // The obsolete forms and malformed values leave the delay to the caller.
    for value in [
        "Sunday, 06-Nov-94 08:49:37 GMT",
        "Sun Nov  6 08:49:37 1994",
        "Sun, 06 Nov 1994 08:49:37 UTC",
        "Wed, 30 Feb 2000 00:00:00 GMT",
        "Sun, 06 Nov 1994 24:00:00 GMT",
        "Xyz, 06 Nov 1994 08:49:37 GMT",
        "-5",
        "inf",
        "nan",
        "",
    ] {
        assert_eq!(retry_after_ms(value, now), None, "{value}");
    }
}

#[test]
fn url_parses_or_fails_as_bad_url() {
    let target = Target::parse("https://api.example.test/v1/messages?x=1").unwrap();
    assert!(target.tls);
    assert_eq!((target.host.as_str(), target.port), ("api.example.test", 443));
    assert_eq!(target.host_header, "api.example.test");
    assert_eq!(target.path, "/v1/messages?x=1");
    let local = Target::parse("http://[::1]:8080/chat").unwrap();
    assert_eq!((local.host.as_str(), local.port), ("::1", 8080));
    assert_eq!(local.host_header, "[::1]:8080");
    for url in ["ftp://host/x", "/relative", "http://", "not a url"] {
        assert_eq!(Target::parse(url).map(|_| ()), Err(Fault::BadUrl), "{url}");
    }
}

// A socket or TLS read failure is a lost connection. Other invalid bytes are a malformed answer.
#[test]
fn io_errors_map_to_faults() {
    let tls = io::Error::new(io::ErrorKind::InvalidData, rustls::Error::DecryptError);
    assert_eq!(io_fault(&tls), Fault::ConnectionLost);
    let chunk = io::Error::new(io::ErrorKind::InvalidData, "invalid chunk size");
    assert_eq!(io_fault(&chunk), Fault::MalformedResponse);
    assert_eq!(io_fault(&io::ErrorKind::ConnectionReset.into()), Fault::ConnectionLost);
}

// The request asks for no compression, so a compressed body never reaches the SSE parser.
#[tokio::test]
async fn compressed_response_is_malformed() {
    for (encoding, fault) in [
        (None, None),
        (Some("identity"), None),
        (Some("Identity "), None),
        (Some("gzip"), Some(Fault::MalformedResponse)),
        (Some("br"), Some(Fault::MalformedResponse)),
    ] {
        let server = Server {
            status: 200,
            body: CANNED_SSE.into(),
            headers: encoding.map(|value| ("content-encoding", value)).into_iter().collect(),
            ..Server::default()
        };
        let (seen, out) = exchange(server, &transport(None), None).await;
        assert_eq!(seen.encodings, ["identity"]);
        assert_eq!(out.err, fault, "{encoding:?}");
        if fault.is_none() {
            assert_eq!(out.head.unwrap().status, 200);
            assert_eq!(out.bytes, CANNED_SSE.as_bytes());
        } else {
            assert!(out.bytes.is_empty(), "{encoding:?}");
        }
    }
}

// A `HeaderMap` panics above its size limit, so the transport counts the headers and sends nothing.
#[tokio::test]
async fn too_many_headers_fail_before_send() {
    let many = vec![Header::from_static("x-many", "1"); MAX_HEADERS + 1];
    let valid = [Header::from_static("x-note", "valid")];
    let ((fault, bytes), (valid_fault, valid_bytes)) =
        tokio::join!(observe_http_bytes(&many), observe_http_bytes(&valid));
    assert_eq!(fault, Some(Fault::InvalidRequest));
    assert!(fault.is_some_and(Fault::sent_nothing));
    assert_eq!(bytes, 0, "the rejected request sent HTTP bytes");
    assert_eq!(valid_fault, None);
    assert!(valid_bytes != 0, "the observer missed a valid request");
}

/// Observe every connection during the window, including connections after an empty one.
async fn observe_http_bytes(headers: &[Header]) -> (Option<Fault>, usize) {
    let listener = TcpListener::bind("127.0.0.1:0").await.unwrap();
    let port = listener.local_addr().unwrap().port();
    let mut peer = tokio::spawn(async move {
        let mut reads = tokio::task::JoinSet::new();
        let cutoff = Instant::now() + Duration::from_secs(1);
        while Instant::now() < cutoff {
            let Ok(accepted) = tokio::time::timeout_at(cutoff, listener.accept()).await else {
                break;
            };
            let (mut stream, _) = accepted.unwrap();
            reads.spawn(async move {
                let mut bytes = [0; 4096];
                let read = tokio::time::timeout(Duration::from_secs(2), stream.read(&mut bytes)).await;
                let n = read.expect("observer read did not finish").unwrap();
                if n != 0 {
                    _ = stream
                        .write_all(b"HTTP/1.1 200 OK\r\nContent-Length: 0\r\nConnection: close\r\n\r\n")
                        .await;
                }
                n
            });
        }
        let mut results = Vec::new();
        while let Some(result) = reads.join_next().await {
            results.push(result);
        }
        results.into_iter().map(Result::unwrap).sum::<usize>()
    });
    let url = format!("http://127.0.0.1:{port}/messages");
    let request = Outgoing::new(&url, headers, b"{}");
    let transport = transport(None);
    let opened = tokio::time::timeout(Duration::from_secs(5), transport.open(&request, Some(after(1000)))).await;
    let observed = tokio::time::timeout(Duration::from_secs(5), &mut peer).await;
    if observed.is_err() {
        peer.abort();
        _ = peer.await;
    }
    (opened.unwrap().err(), observed.unwrap().unwrap())
}
