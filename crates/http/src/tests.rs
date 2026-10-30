//! Loopback tests for [`Client`]: one real server and one real client per test.

use std::time::Duration;

use http::header::HeaderName;
use tokio::io::AsyncWriteExt;
use tokio::net::TcpListener;

use super::*;
use crate::testing::{Seen, Server, listen, read_request};

const TEST_USER_AGENT: &str = "http-test/0";

const BODY: &str = "data: one\n\ndata: two\n\n";

fn client(idle_timeout: Option<Duration>) -> Client {
    Client::new(ClientOptions {
        idle_timeout,
        user_agent: TEST_USER_AGENT.to_owned(),
    })
    .unwrap()
}

/// A `POST` of `{}` to `/messages` on the local server at `port`.
fn post(port: u16) -> Request {
    Request {
        body: Bytes::from_static(b"{}"),
        ..Request::new(Method::POST, format!("http://127.0.0.1:{port}/messages"))
    }
}

/// What the client observed of one request.
#[derive(Debug, Default)]
struct Out {
    status: Option<StatusCode>,
    headers: HeaderMap,
    bytes: Vec<u8>,
    error: Option<Error>,
}

/// Send `request`, and read the whole body.
async fn run(client: &Client, request: Request, deadline: Option<std::time::Instant>) -> Out {
    let mut out = Out::default();
    let mut body = match client.send(request, deadline).await {
        Ok(response) => {
            out.status = Some(response.status);
            out.headers = response.headers;
            response.body
        }
        Err(error) => {
            out.error = Some(error);
            return out;
        }
    };
    while let Some(chunk) = body.chunk().await {
        match chunk {
            Ok(bytes) => out.bytes.extend_from_slice(&bytes),
            Err(error) => {
                out.error = Some(error);
                break;
            }
        }
    }
    out
}

/// Run one server and one `POST` on a private loopback port.
async fn exchange(server: Server, client: &Client, deadline: Option<std::time::Instant>) -> (Seen, Out) {
    let (port, served) = listen(server).await;
    let out = run(client, post(port), deadline).await;
    (served.await.unwrap(), out)
}

fn after(ms: u64) -> std::time::Instant {
    std::time::Instant::now() + Duration::from_millis(ms)
}

#[tokio::test]
async fn a_request_sends_its_method_target_headers_and_body_and_the_body_streams() {
    let server = Server {
        status: 201,
        body: BODY.into(),
        headers: vec![("x-answer", "a"), ("x-answer", "b")],
        trickle: true,
        ..Server::default()
    };
    let (port, served) = listen(server).await;
    let mut request = Request::new(Method::PUT, format!("http://127.0.0.1:{port}/items?x=1"));
    for (name, value) in [("accept-language", "en"), ("accept-language", "es"), ("x-note", "café")] {
        let value = HeaderValue::from_bytes(value.as_bytes()).unwrap();
        request.headers.append(HeaderName::from_static(name), value);
    }
    request.body = Bytes::from_static(b"{\"a\":1}");

    let out = run(&client(None), request, None).await;
    let seen = served.await.unwrap();

    assert_eq!((seen.method.as_str(), seen.target.as_str()), ("PUT", "/items?x=1"));
    assert_eq!(seen.values("accept-language"), ["en", "es"]);
    assert_eq!(seen.values("x-note"), ["café"]);
    assert_eq!(seen.values("host"), [format!("127.0.0.1:{port}")]);
    assert_eq!(seen.values("user-agent"), [TEST_USER_AGENT]);
    assert_eq!(seen.values("connection"), ["close"]);
    assert_eq!(seen.values("content-length"), ["7"]);
    assert_eq!(seen.body, b"{\"a\":1}");
    assert_eq!(out.error, None);
    assert_eq!(out.status, Some(StatusCode::CREATED));
    let answers: Vec<_> = out.headers.get_all("x-answer").iter().collect();
    assert_eq!(answers, ["a", "b"]);
    assert_eq!(out.bytes, BODY.as_bytes());
}

#[tokio::test]
async fn the_client_owns_the_framing_and_the_user_agent_of_a_request_wins() {
    // A wrong length makes both sides wait for bytes, so the idle timeout ends such a failure.
    let client = client(Some(Duration::from_secs(1)));
    let mut seen = Vec::new();
    for (method, body) in [
        (Method::GET, ""),
        (Method::POST, ""),
        (Method::DELETE, ""),
        (Method::PUT, "abc"),
    ] {
        let (port, served) = listen(Server {
            status: 200,
            ..Server::default()
        })
        .await;
        let mut request = Request::new(method, format!("http://127.0.0.1:{port}/"));
        request.headers.insert(USER_AGENT, HeaderValue::from_static("mine"));
        // The client sends a whole body, so it removes the framing of the caller.
        request.headers.insert(CONTENT_LENGTH, HeaderValue::from_static("9"));
        request
            .headers
            .insert(TRANSFER_ENCODING, HeaderValue::from_static("gzip"));
        request.body = Bytes::from(body);
        assert_eq!(run(&client, request, None).await.error, None);
        seen.push(served.await.unwrap());
    }

    let lengths: Vec<Vec<&str>> = seen.iter().map(|seen| seen.values("content-length")).collect();
    assert_eq!(lengths, [vec![], vec!["0"], vec![], vec!["3"]]);
    assert_eq!(seen[3].body, b"abc");
    for seen in &seen {
        assert_eq!(seen.values("transfer-encoding"), Vec::<&str>::new());
        assert_eq!(seen.values("user-agent"), ["mine"]);
    }
}

#[tokio::test]
async fn a_redirect_and_a_compressed_body_reach_the_caller_as_they_are() {
    let (seen, out) = exchange(
        Server {
            status: 302,
            headers: vec![("location", "http://other.example/x")],
            ..Server::default()
        },
        &client(None),
        None,
    )
    .await;
    assert_eq!(seen.values("accept-encoding"), Vec::<&str>::new());
    assert_eq!(out.error, None);
    assert_eq!(out.status, Some(StatusCode::FOUND));
    assert_eq!(out.headers["location"], "http://other.example/x");

    let (_, out) = exchange(
        Server {
            status: 200,
            body: b"\x1f\x8b raw".to_vec(),
            headers: vec![("content-encoding", "gzip")],
            ..Server::default()
        },
        &client(None),
        None,
    )
    .await;
    assert_eq!(out.error, None);
    assert_eq!(out.bytes, b"\x1f\x8b raw");
}

#[tokio::test]
async fn stalled_body_hits_idle_timeout() {
    // The server sends the head, then keeps the stream open with no body until the client closes it.
    let server = Server {
        status: 200,
        stall: true,
        ..Server::default()
    };
    let (_, out) = exchange(server, &client(Some(Duration::from_millis(50))), None).await;
    assert_eq!(out.error, Some(Error::IdleTimeout));
    assert_eq!(out.status, Some(StatusCode::OK));
}

#[tokio::test]
async fn silent_peer_hits_idle_timeout() {
    let server = Server {
        status: 200,
        silent: true,
        ..Server::default()
    };
    let (_, out) = exchange(server, &client(Some(Duration::from_millis(50))), None).await;
    assert_eq!(out.error, Some(Error::IdleTimeout));
}

#[tokio::test]
async fn request_deadline_wins_over_longer_idle_timeout() {
    for idle in [None, Some(Duration::from_secs(30))] {
        let server = Server {
            status: 200,
            stall: true,
            ..Server::default()
        };
        let (_, out) = exchange(server, &client(idle), Some(after(50))).await;
        assert_eq!(out.error, Some(Error::RequestTimeout));
        assert_eq!(out.status, Some(StatusCode::OK));
    }
}

// No leg starts once the deadline passed, so the request never leaves. The error names the deadline.
#[tokio::test]
async fn expired_deadline_fails_before_send() {
    let listener = TcpListener::bind("127.0.0.1:0").await.unwrap();
    let port = listener.local_addr().unwrap().port();
    let out = run(
        &client(Some(Duration::from_secs(300))),
        post(port),
        Some(std::time::Instant::now()),
    )
    .await;
    assert_eq!(out.error, Some(Error::RequestTimeout));
    // An expired request opens no connection.
    let accepted = tokio::time::timeout(Duration::from_millis(50), listener.accept()).await;
    assert!(accepted.is_err(), "the client connected after its deadline");
}

// The handshake never ends, so the idle deadline passes before the request leaves.
#[tokio::test]
async fn stalled_handshake_is_a_connect_timeout() {
    let listener = TcpListener::bind("127.0.0.1:0").await.unwrap();
    let port = listener.local_addr().unwrap().port();
    let peer = tokio::spawn(async move {
        let (stream, _) = listener.accept().await.unwrap();
        tokio::time::sleep(Duration::from_secs(5)).await;
        drop(stream);
    });
    let request = Request::new(Method::POST, format!("https://127.0.0.1:{port}/messages"));
    let error = client(Some(Duration::from_millis(50))).send(request, None).await.err();
    assert_eq!(error, Some(Error::ConnectTimeout));
    peer.abort();
}

#[tokio::test]
async fn silent_peer_hits_request_deadline() {
    let server = Server {
        status: 200,
        silent: true,
        ..Server::default()
    };
    let (_, out) = exchange(server, &client(None), Some(after(50))).await;
    assert_eq!(out.error, Some(Error::RequestTimeout));
}

#[tokio::test]
async fn content_length_body_reads_to_its_end() {
    let server = Server {
        raw_response: Some(b"HTTP/1.1 200 OK\r\nContent-Length: 4\r\nConnection: close\r\n\r\nbody"),
        ..Server::default()
    };
    let (_, out) = exchange(server, &client(None), None).await;
    assert_eq!(out.error, None);
    assert_eq!(out.status, Some(StatusCode::OK));
    assert_eq!(out.bytes, b"body");
}

#[tokio::test]
async fn malformed_or_truncated_body_fails() {
    let cases: [(&'static [u8], Error); 3] = [
        (
            b"HTTP/1.1 200 OK\r\nContent-Length: 4\r\nConnection: close\r\n\r\nx",
            Error::ConnectionLost,
        ),
        (
            b"HTTP/1.1 200 OK\r\nTransfer-Encoding: chunked\r\nConnection: close\r\n\r\n1\rX",
            Error::MalformedResponse,
        ),
        (
            b"HTTP/1.1 200 OK\r\nTransfer-Encoding: chunked\r\nConnection: close\r\n\r\n3\r\nx",
            Error::ConnectionLost,
        ),
    ];
    for (bytes, cause) in cases {
        let server = Server {
            raw_response: Some(bytes),
            ..Server::default()
        };
        let (_, out) = exchange(server, &client(None), None).await;
        assert_eq!(out.error, Some(cause), "{}", String::from_utf8_lossy(bytes));
        assert_eq!(out.status, Some(StatusCode::OK));
    }
}

// A drop is the cancellation of Rust: the send future and the body each own the connection, so a drop closes it.
#[tokio::test]
async fn a_dropped_send_or_body_closes_the_connection() {
    for body_wait in [false, true] {
        let server = Server {
            status: 200,
            silent: !body_wait,
            stall: body_wait,
            ..Server::default()
        };
        // The server returns only once the client closed the connection.
        let (port, served) = listen(server).await;
        let client = client(Some(Duration::from_secs(30)));
        if body_wait {
            let mut response = client.send(post(port), None).await.unwrap();
            assert_eq!(response.status, StatusCode::OK);
            let read = tokio::time::timeout(Duration::from_millis(50), response.body.chunk()).await;
            assert!(read.is_err(), "the stalled body returned a chunk");
            drop(response);
        } else {
            let sent = tokio::time::timeout(Duration::from_millis(50), client.send(post(port), None)).await;
            assert!(sent.is_err(), "the silent peer answered a head");
        }
        tokio::time::timeout(Duration::from_secs(5), served)
            .await
            .unwrap()
            .unwrap();
    }
}

#[tokio::test]
async fn one_client_sends_concurrently() {
    let client = client(Some(Duration::from_secs(5)));
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
                "HTTP/1.1 200 OK\r\nConnection: close\r\nContent-Length: {}\r\n\r\n{BODY}",
                BODY.len()
            );
            stream.write_all(response.as_bytes()).await.unwrap();
        });
    }
    let clients = futures_join(ports.iter().map(|&port| run(&client, post(port), None)));
    // No server answers until all eight requests arrive, so requests in series cannot pass.
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
    let (outputs, served) = outcome.expect("not every request finished before the bound");
    for server in served {
        server.unwrap();
    }
    for out in outputs {
        assert_eq!(out.error, None);
        assert_eq!(out.status, Some(StatusCode::OK));
        assert_eq!(out.bytes, BODY.as_bytes());
    }
}

/// Poll every future on this task until all finish, so the sends share one thread as yuke's sessions do.
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

/// Send to `url` with an idle timeout of 5 seconds, and return the error.
async fn send_error(url: &str) -> Option<Error> {
    let request = Request::new(Method::POST, url);
    client(Some(Duration::from_secs(5))).send(request, None).await.err()
}

// Each case fails before the request leaves, and the error names the step that failed.
#[tokio::test]
async fn a_failed_send_names_the_dns_or_the_connect() {
    let listener = TcpListener::bind("127.0.0.1:0").await.unwrap();
    let port = listener.local_addr().unwrap().port();
    drop(listener);
    let error = send_error(&format!("http://127.0.0.1:{port}/messages")).await;
    assert_eq!(error, Some(Error::ConnectFailed));
    // The `.invalid` top-level name never resolves (RFC 2606).
    let error = send_error("http://host.invalid/messages").await;
    assert_eq!(error, Some(Error::DnsFailed));

    // A plain HTTP peer answers the TLS hello with bytes that are no handshake.
    let listener = TcpListener::bind("127.0.0.1:0").await.unwrap();
    let port = listener.local_addr().unwrap().port();
    let peer = tokio::spawn(async move {
        let (mut stream, _) = listener.accept().await.unwrap();
        _ = stream.write_all(b"HTTP/1.1 400 Bad Request\r\n\r\n").await;
    });
    let error = send_error(&format!("https://127.0.0.1:{port}/messages")).await;
    assert_eq!(error, Some(Error::ConnectFailed));
    peer.await.unwrap();
}

// Linux reads certificate-file settings. macOS uses the system certificate store.
#[cfg(target_os = "linux")]
#[tokio::test]
async fn missing_root_certificates_fail_only_https() {
    // A child process keeps the root-store settings apart from the other tests.
    const NO_ROOTS_CHILD: &str = "HTTP_TEST_NO_ROOTS_CHILD";

    if std::env::var_os(NO_ROOTS_CHILD).is_none() {
        // A named file with no root and a named file that does not exist both leave no root, never the system roots.
        for file in ["/dev/null", "/nonexistent/yuke-test-roots.pem"] {
            let status = std::process::Command::new(std::env::current_exe().unwrap())
                .args(["--exact", "tests::missing_root_certificates_fail_only_https"])
                .env(NO_ROOTS_CHILD, "1")
                .env("SSL_CERT_FILE", file)
                .env_remove("SSL_CERT_DIR")
                .stdout(std::process::Stdio::null())
                .status()
                .unwrap();
            assert!(status.success(), "{file}");
        }
        return;
    }
    let client = client(None);
    for _ in 0..2 {
        let request = Request::new(Method::POST, "https://127.0.0.1:9/messages");
        let error = client.send(request, None).await.err();
        assert_eq!(error, Some(Error::TlsSetupFailed));
    }
    let server = Server {
        status: 200,
        body: BODY.into(),
        ..Server::default()
    };
    let (_, out) = exchange(server, &client, None).await;
    assert_eq!(out.error, None);
}

#[cfg(target_os = "linux")]
#[test]
fn ssl_cert_dir_names_the_exact_roots() {
    // A child process keeps the root-store settings apart from the other tests. Its variable holds the expected result.
    const FOLDER_CHILD: &str = "HTTP_TEST_FOLDER_CHILD";

    if let Ok(expected) = std::env::var(FOLDER_CHILD) {
        assert_eq!(client(None).tls().is_ok(), expected == "roots");
        return;
    }
    let base = std::env::temp_dir().join(format!("yuke-http-roots-{}", std::process::id()));
    let (filled, empty) = (base.join("filled"), base.join("empty"));
    std::fs::create_dir_all(&filled).unwrap();
    std::fs::create_dir_all(&empty).unwrap();
    let bundle = openssl_probe::probe().cert_file.unwrap();
    std::fs::copy(bundle, filled.join("roots.pem")).unwrap();
    // A folder with roots supplies them. An empty folder leaves no root, never the system roots.
    for (folder, expected) in [(&filled, "roots"), (&empty, "none")] {
        let status = std::process::Command::new(std::env::current_exe().unwrap())
            .args(["--exact", "tests::ssl_cert_dir_names_the_exact_roots"])
            .env(FOLDER_CHILD, expected)
            .env("SSL_CERT_DIR", folder)
            .env_remove("SSL_CERT_FILE")
            .stdout(std::process::Stdio::null())
            .status()
            .unwrap();
        assert!(status.success(), "{expected}");
    }
    std::fs::remove_dir_all(&base).unwrap();
}

// The connector wraps the rustls error in the I/O error, and a rejected certificate gets an error of its own.
#[test]
fn a_rejected_certificate_is_its_own_error() {
    let refused = io::Error::new(
        io::ErrorKind::InvalidData,
        rustls::Error::InvalidCertificate(rustls::CertificateError::Expired),
    );
    let other = io::Error::new(io::ErrorKind::InvalidData, rustls::Error::DecryptError);

    assert_eq!(handshake_error(&refused), Error::CertificateRejected);
    assert_eq!(handshake_error(&other), Error::ConnectFailed);
}

#[test]
fn invalid_user_agent_is_rejected() {
    let options = ClientOptions::new("bad\r\n");
    assert!(matches!(Client::new(options), Err(InvalidUserAgent)));
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
    let named = Target::parse("http://user@host:9/x").unwrap();
    assert_eq!((named.host.as_str(), named.port), ("host", 9));
    assert_eq!(named.host_header, "host:9");
    for url in [
        "ftp://host/x",
        "/relative",
        "http://",
        "not a url",
        "http://host:bad/x",
        "http://host:/x",
        "http://host:70000/x",
    ] {
        assert_eq!(Target::parse(url).map(|_| ()), Err(Error::BadUrl), "{url}");
    }
}

// A socket or TLS read failure is a lost connection. Other invalid bytes are a malformed response.
#[test]
fn io_errors_map_to_errors() {
    let tls = io::Error::new(io::ErrorKind::InvalidData, rustls::Error::DecryptError);
    assert_eq!(io_error(&tls), Error::ConnectionLost);
    let chunk = io::Error::new(io::ErrorKind::InvalidData, "invalid chunk size");
    assert_eq!(io_error(&chunk), Error::MalformedResponse);
    assert_eq!(io_error(&io::ErrorKind::ConnectionReset.into()), Error::ConnectionLost);
}
