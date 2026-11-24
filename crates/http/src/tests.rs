//! Loopback tests for [`Client`]: one real server and one real client per test.

use std::time::Duration;

use http::header::HeaderName;
use tokio::io::AsyncWriteExt;
use tokio::net::TcpListener;

use super::*;
use crate::testing::{Answer, Seen, listen, read_request, serve};

const TEST_USER_AGENT: &str = "http-test/0";

const BODY: &str = "data: one\n\ndata: two\n\n";

fn client() -> Client {
    Client::new(HeaderValue::from_static(TEST_USER_AGENT))
}

/// A `POST` of `{}` to `/messages` on the local server at `port`.
fn post(port: u16) -> Request {
    Request {
        body: vec![Bytes::from_static(b"{}")],
        ..Request::new(Method::POST, format!("http://127.0.0.1:{port}/messages"))
    }
}

/// `request` with the idle timeout `idle_timeout` and the deadline `deadline`.
fn limited(request: Request, idle_timeout: Option<Duration>, deadline: Option<std::time::Instant>) -> Request {
    Request {
        idle_timeout,
        deadline,
        ..request
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
async fn run(client: &Client, request: Request) -> Out {
    let mut out = Out::default();
    let mut body = match client.send(request).await {
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

/// Run one server and one `POST` with `idle_timeout` and `deadline` on a private loopback port.
async fn exchange(
    server: Answer,
    client: &Client,
    idle_timeout: Option<Duration>,
    deadline: Option<std::time::Instant>,
) -> (Seen, Out) {
    let (port, served) = listen(server).await;
    let out = run(client, limited(post(port), idle_timeout, deadline)).await;
    (served.await.unwrap(), out)
}

fn after(ms: u64) -> std::time::Instant {
    std::time::Instant::now() + Duration::from_millis(ms)
}

#[tokio::test]
async fn a_request_sends_its_method_target_headers_and_body_and_the_body_streams() {
    let server = Answer {
        status: 201,
        body: BODY.into(),
        headers: vec![("x-answer", "a"), ("x-answer", "b")],
        trickle: true,
        ..Answer::default()
    };
    let (port, served) = listen(server).await;
    let mut request = Request::new(Method::PUT, format!("http://127.0.0.1:{port}/items?x=1"));
    for (name, value) in [("accept-language", "en"), ("accept-language", "es"), ("x-note", "café")] {
        let value = HeaderValue::from_bytes(value.as_bytes()).unwrap();
        request.headers.append(HeaderName::from_static(name), value);
    }
    request.body = vec![Bytes::from_static(b"{\"a\":"), Bytes::new(), Bytes::from_static(b"1}")];

    let out = run(&client(), request).await;
    let seen = served.await.unwrap();

    assert_eq!((seen.method.as_str(), seen.target.as_str()), ("PUT", "/items?x=1"));
    assert_eq!(seen.values("accept-language"), ["en", "es"]);
    assert_eq!(seen.values("x-note"), ["café"]);
    assert_eq!(seen.values("host"), [format!("127.0.0.1:{port}")]);
    assert_eq!(seen.values("user-agent"), [TEST_USER_AGENT]);
    assert_eq!(seen.values("connection"), Vec::<&str>::new());
    assert_eq!(seen.values("content-length"), ["7"]);
    assert_eq!(seen.body, b"{\"a\":1}");
    assert_eq!(out.error, None);
    assert_eq!(out.status, Some(StatusCode::CREATED));
    let answers: Vec<_> = out.headers.get_all("x-answer").iter().collect();
    assert_eq!(answers, ["a", "b"]);
    assert_eq!(out.bytes, BODY.as_bytes());
}

fn answer() -> Answer {
    Answer {
        status: 200,
        body: BODY.into(),
        ..Answer::default()
    }
}

/// The connection that carried each request that the server read.
async fn connections(served: tokio::task::JoinHandle<Vec<Seen>>) -> Vec<usize> {
    served.await.unwrap().iter().map(|seen| seen.connection).collect()
}

#[tokio::test]
async fn requests_in_a_row_to_one_host_share_one_connection() {
    let (port, served) = serve(vec![answer(), answer(), answer()]).await;
    let client = client();

    for _ in 0..3 {
        assert_eq!(run(&client, post(port)).await.bytes, BODY.as_bytes());
    }

    assert_eq!(connections(served).await, [0, 0, 0]);
}

// A stream reader stops after its last event and drops the body before it reads the end.
#[tokio::test]
async fn a_body_dropped_after_its_last_byte_gives_its_connection_back() {
    let (port, served) = serve(vec![answer(), answer()]).await;
    let client = client();

    let mut response = client.send(post(port)).await.unwrap();
    let mut bytes = Vec::new();
    while bytes.len() < BODY.len() {
        bytes.extend_from_slice(&response.body.chunk().await.unwrap().unwrap());
    }
    drop(response);
    assert_eq!(run(&client, post(port)).await.bytes, BODY.as_bytes());

    assert_eq!(connections(served).await, [0, 0]);
}

#[tokio::test]
async fn an_unread_body_that_arrived_whole_gives_its_connection_back() {
    let (port, served) = serve(vec![answer(), answer()]).await;
    let client = client();

    // The server writes the head and the body at once, so the body arrives with the head.
    drop(client.send(post(port)).await.unwrap());
    assert_eq!(run(&client, post(port)).await.bytes, BODY.as_bytes());

    assert_eq!(connections(served).await, [0, 0]);
}

#[tokio::test]
async fn an_answer_with_no_body_gives_its_connection_back() {
    let listener = TcpListener::bind("127.0.0.1:0").await.unwrap();
    let port = listener.local_addr().unwrap().port();
    let peer = tokio::spawn(async move {
        let (mut stream, _) = listener.accept().await.unwrap();
        for _ in 0..2 {
            read_request(&mut stream).await.unwrap();
            stream
                .write_all(b"HTTP/1.1 202 Accepted\r\ncontent-length: 0\r\n\r\n")
                .await
                .unwrap();
        }
    });
    let client = client();

    // The caller drops the answer unread, as the sender of a notification does.
    drop(client.send(post(port)).await.unwrap());
    // The peer accepts one connection only, so a second connection gets no answer.
    let second = tokio::time::timeout(Duration::from_secs(5), client.send(post(port))).await;

    assert_eq!(
        second
            .expect("the first connection carried the second request")
            .unwrap()
            .status,
        StatusCode::ACCEPTED
    );
    peer.await.unwrap();
}

#[tokio::test]
async fn a_connection_idle_for_longer_than_the_limit_is_not_used() {
    let (port, served) = serve(vec![answer(), answer()]).await;
    let client = client();

    assert_eq!(run(&client, post(port)).await.bytes, BODY.as_bytes());
    tokio::time::pause();
    tokio::time::advance(Duration::from_secs(61)).await;
    tokio::time::resume();
    assert_eq!(run(&client, post(port)).await.bytes, BODY.as_bytes());

    assert_eq!(connections(served).await, [0, 1]);
}

/// The answer of a peer to the first request on a connection, which keeps the connection open.
const KEEP_OPEN: &[u8] = b"HTTP/1.1 200 OK\r\ncontent-length: 2\r\n\r\nok";

#[tokio::test]
async fn a_connection_that_the_peer_closed_while_idle_gives_way_to_a_new_one() {
    let listener = TcpListener::bind("127.0.0.1:0").await.unwrap();
    let port = listener.local_addr().unwrap().port();
    let (close, close_asked) = tokio::sync::oneshot::channel();
    let (closed, close_seen) = tokio::sync::oneshot::channel();
    let peer = tokio::spawn(async move {
        let (mut first, _) = listener.accept().await.unwrap();
        read_request(&mut first).await.unwrap();
        first.write_all(KEEP_OPEN).await.unwrap();
        // The close comes after the client put the connection in its pool.
        close_asked.await.unwrap();
        drop(first);
        closed.send(()).unwrap();
        let (mut second, _) = listener.accept().await.unwrap();
        read_request(&mut second).await.unwrap();
        second.write_all(KEEP_OPEN).await.unwrap();
    });
    let client = client();

    assert_eq!(run(&client, post(port)).await.bytes, b"ok");
    close.send(()).unwrap();
    close_seen.await.unwrap();
    // tokio sees the close only when its I/O driver runs. A real request comes long after the close of an idle
    // connection.
    tokio::time::sleep(Duration::from_millis(20)).await;
    let out = run(&client, post(port)).await;

    assert_eq!((out.error, out.bytes), (None, b"ok".to_vec()));
    peer.await.unwrap();
}

#[tokio::test]
async fn a_request_that_left_on_a_reused_connection_is_never_sent_again() {
    let listener = TcpListener::bind("127.0.0.1:0").await.unwrap();
    let port = listener.local_addr().unwrap().port();
    let peer = tokio::spawn(async move {
        let (mut stream, _) = listener.accept().await.unwrap();
        read_request(&mut stream).await.unwrap();
        stream.write_all(KEEP_OPEN).await.unwrap();
        // The second request arrives, and the connection ends with no answer.
        read_request(&mut stream).await.unwrap();
        drop(stream);
        // A repeat of the request would open a new connection.
        tokio::time::timeout(Duration::from_millis(200), listener.accept())
            .await
            .is_ok()
    });
    let client = client();

    assert_eq!(run(&client, post(port)).await.bytes, b"ok");
    let out = run(&client, post(port)).await;

    assert_eq!(out.error, Some(Error::ConnectionLost));
    assert!(!peer.await.unwrap(), "the client sent the request again");
}

#[tokio::test]
async fn the_client_owns_the_framing_and_the_user_agent_of_a_request_wins() {
    // A wrong length makes both sides wait for bytes, so the idle timeout ends such a failure.
    let client = client();
    let mut seen = Vec::new();
    for (method, body) in [
        (Method::GET, ""),
        (Method::POST, ""),
        (Method::DELETE, ""),
        (Method::PUT, "abc"),
    ] {
        let (port, served) = listen(Answer {
            status: 200,
            ..Answer::default()
        })
        .await;
        let mut request = Request::new(method, format!("http://127.0.0.1:{port}/"));
        request.headers.insert(USER_AGENT, HeaderValue::from_static("mine"));
        // The client sends a whole body, so it removes the framing of the caller.
        request.headers.insert(CONTENT_LENGTH, HeaderValue::from_static("9"));
        request
            .headers
            .insert(TRANSFER_ENCODING, HeaderValue::from_static("gzip"));
        request.body = vec![Bytes::from(body)];
        request.idle_timeout = Some(Duration::from_secs(1));
        assert_eq!(run(&client, request).await.error, None);
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
        Answer {
            status: 302,
            headers: vec![("location", "http://other.example/x")],
            ..Answer::default()
        },
        &client(),
        None,
        None,
    )
    .await;
    assert_eq!(seen.values("accept-encoding"), Vec::<&str>::new());
    assert_eq!(out.error, None);
    assert_eq!(out.status, Some(StatusCode::FOUND));
    assert_eq!(out.headers["location"], "http://other.example/x");

    let (_, out) = exchange(
        Answer {
            status: 200,
            body: b"\x1f\x8b raw".to_vec(),
            headers: vec![("content-encoding", "gzip")],
            ..Answer::default()
        },
        &client(),
        None,
        None,
    )
    .await;
    assert_eq!(out.error, None);
    assert_eq!(out.bytes, b"\x1f\x8b raw");
}

#[tokio::test]
async fn stalled_body_hits_idle_timeout() {
    // The server sends the head, then keeps the stream open with no body until the client closes it.
    let server = Answer {
        status: 200,
        stall: true,
        ..Answer::default()
    };
    let (_, out) = exchange(server, &client(), Some(Duration::from_millis(50)), None).await;
    assert_eq!(out.error, Some(Error::IdleTimeout));
    assert_eq!(out.status, Some(StatusCode::OK));
}

#[tokio::test]
async fn silent_peer_hits_idle_timeout() {
    let server = Answer {
        status: 200,
        silent: true,
        ..Answer::default()
    };
    let (_, out) = exchange(server, &client(), Some(Duration::from_millis(50)), None).await;
    assert_eq!(out.error, Some(Error::IdleTimeout));
}

#[tokio::test]
async fn request_deadline_wins_over_longer_idle_timeout() {
    for idle in [None, Some(Duration::from_secs(30))] {
        let server = Answer {
            status: 200,
            stall: true,
            ..Answer::default()
        };
        let (_, out) = exchange(server, &client(), idle, Some(after(50))).await;
        assert_eq!(out.error, Some(Error::RequestTimeout));
        assert_eq!(out.status, Some(StatusCode::OK));
    }
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
    let error = client()
        .send(limited(request, Some(Duration::from_millis(50)), None))
        .await
        .err();
    assert_eq!(error, Some(Error::ConnectTimeout));
    peer.abort();
}

#[tokio::test]
async fn silent_peer_hits_request_deadline() {
    let server = Answer {
        status: 200,
        silent: true,
        ..Answer::default()
    };
    let (_, out) = exchange(server, &client(), None, Some(after(50))).await;
    assert_eq!(out.error, Some(Error::RequestTimeout));
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
        let server = Answer {
            raw_response: Some(bytes),
            ..Answer::default()
        };
        let (_, out) = exchange(server, &client(), None, None).await;
        assert_eq!(out.error, Some(cause), "{}", String::from_utf8_lossy(bytes));
        assert_eq!(out.status, Some(StatusCode::OK));
    }
}

// A drop is the cancellation of Rust: the send future and the body each own the connection, so a drop closes it.
#[tokio::test]
async fn a_dropped_send_or_body_closes_the_connection() {
    for body_wait in [false, true] {
        let server = Answer {
            status: 200,
            silent: !body_wait,
            stall: body_wait,
            ..Answer::default()
        };
        // The server returns only once the client closed the connection.
        let (port, served) = listen(server).await;
        let client = client();
        let request = || limited(post(port), Some(Duration::from_secs(30)), None);
        if body_wait {
            let mut response = client.send(request()).await.unwrap();
            assert_eq!(response.status, StatusCode::OK);
            let read = tokio::time::timeout(Duration::from_millis(50), response.body.chunk()).await;
            assert!(read.is_err(), "the stalled body returned a chunk");
            drop(response);
        } else {
            let sent = tokio::time::timeout(Duration::from_millis(50), client.send(request())).await;
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
    let client = client();
    let gate = Arc::new(tokio::sync::Barrier::new(8));
    let mut ports = Vec::new();
    let mut servers = tokio::task::JoinSet::new();
    for _ in 0..8 {
        let listener = TcpListener::bind("127.0.0.1:0").await.unwrap();
        ports.push(listener.local_addr().unwrap().port());
        let gate = gate.clone();
        servers.spawn(async move {
            let (mut stream, _) = listener.accept().await.unwrap();
            read_request(&mut stream).await.unwrap();
            gate.wait().await;
            let response = format!(
                "HTTP/1.1 200 OK\r\nConnection: close\r\nContent-Length: {}\r\n\r\n{BODY}",
                BODY.len()
            );
            stream.write_all(response.as_bytes()).await.unwrap();
        });
    }
    // No server answers until all eight requests arrive, so requests in series cannot pass.
    let outcome = tokio::time::timeout(
        Duration::from_secs(5),
        Box::pin(async {
            let (first, second, third, fourth, fifth, sixth, seventh, eighth) = tokio::join!(
                run(&client, post(ports[0])),
                run(&client, post(ports[1])),
                run(&client, post(ports[2])),
                run(&client, post(ports[3])),
                run(&client, post(ports[4])),
                run(&client, post(ports[5])),
                run(&client, post(ports[6])),
                run(&client, post(ports[7])),
            );
            let outputs = [first, second, third, fourth, fifth, sixth, seventh, eighth];
            let mut served = Vec::new();
            while let Some(result) = servers.join_next().await {
                served.push(result);
            }
            (outputs, served)
        }),
    )
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

/// Send to `url` with an idle timeout of 5 seconds, and return the error.
async fn send_error(url: &str) -> Option<Error> {
    let request = Request::new(Method::POST, url);
    client()
        .send(limited(request, Some(Duration::from_secs(5)), None))
        .await
        .err()
}

// Each case fails before the request leaves, and the error names the step that failed.
#[tokio::test]
async fn a_failed_send_names_the_dns_or_the_connect() {
    // Nothing listens on port 1. A freed ephemeral port can go to a parallel test before the connect.
    let error = send_error("http://127.0.0.1:1/messages").await;
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

fn ipv6(last: u16) -> SocketAddr {
    SocketAddr::from(([0x2001, 0xdb8, 0, 0, 0, 0, 0, last], 443))
}

fn ipv4(last: u8) -> SocketAddr {
    SocketAddr::from(([192, 0, 2, last], 443))
}

#[test]
fn interleave_alternates_the_families_from_the_first_address() {
    assert_eq!(
        interleave([ipv6(1), ipv6(2), ipv6(3), ipv4(1), ipv4(2)]),
        [ipv6(1), ipv4(1), ipv6(2), ipv4(2), ipv6(3)]
    );
    assert_eq!(interleave([ipv4(1), ipv4(2), ipv6(1)]), [ipv4(1), ipv6(1), ipv4(2)]);
    assert_eq!(interleave([ipv4(1), ipv4(2)]), [ipv4(1), ipv4(2)]);
    assert_eq!(interleave([]), []);
}

/// How one fake connection attempt ends.
#[derive(Clone, Copy)]
enum Fate {
    /// It opens after the milliseconds.
    Opens(u64),
    /// It fails after the milliseconds.
    Refused(u64),
    /// It never ends.
    Silent,
}

/// Race `ipv6(1)` and then `ipv4(1)` with fake attempts that end as `fate` says, and return the winner and the time it
/// took.
async fn race_two(fate: impl Fn(SocketAddr) -> Fate) -> (Option<SocketAddr>, Duration) {
    let start = Instant::now();
    let racing = race([ipv6(1), ipv4(1)], |address| {
        let fate = fate(address);
        async move {
            match fate {
                Fate::Opens(ms) => tokio::time::sleep(Duration::from_millis(ms)).await,
                Fate::Refused(ms) => {
                    tokio::time::sleep(Duration::from_millis(ms)).await;
                    return Err(io::ErrorKind::ConnectionRefused.into());
                }
                Fate::Silent => std::future::pending().await,
            }
            Ok(address)
        }
    });
    // A race that waits for an attempt that never ends fails the test, and does not hang it.
    let winner = tokio::time::timeout(Duration::from_secs(60), racing)
        .await
        .expect("the race ends");
    (winner, start.elapsed())
}

#[tokio::test(start_paused = true)]
async fn a_silent_address_costs_the_attempt_delay_and_not_the_system_timeout() {
    let fate = |address: SocketAddr| {
        if address.is_ipv6() {
            Fate::Silent
        } else {
            Fate::Opens(0)
        }
    };
    assert_eq!(race_two(fate).await, (Some(ipv4(1)), Duration::from_millis(250)));
}

#[tokio::test(start_paused = true)]
async fn a_refused_address_starts_the_next_at_once() {
    let fate = |address: SocketAddr| {
        if address.is_ipv6() {
            Fate::Refused(10)
        } else {
            Fate::Opens(0)
        }
    };
    assert_eq!(race_two(fate).await, (Some(ipv4(1)), Duration::from_millis(10)));
}

#[tokio::test(start_paused = true)]
async fn an_earlier_attempt_keeps_running_and_wins_when_it_opens_first() {
    let fate = |address: SocketAddr| {
        if address.is_ipv6() {
            Fate::Opens(400)
        } else {
            Fate::Silent
        }
    };
    assert_eq!(race_two(fate).await, (Some(ipv6(1)), Duration::from_millis(400)));
}

#[tokio::test(start_paused = true)]
async fn a_race_where_each_address_fails_opens_nothing() {
    assert_eq!(
        race_two(|_| Fate::Refused(50)).await,
        (None, Duration::from_millis(100))
    );
}

#[tokio::test(start_paused = true)]
async fn the_winner_of_a_race_closes_the_attempts_that_lost() {
    /// Counts its own drop.
    struct Attempt(Arc<std::sync::atomic::AtomicUsize>);
    impl Drop for Attempt {
        fn drop(&mut self) {
            self.0.fetch_add(1, std::sync::atomic::Ordering::Relaxed);
        }
    }
    let dropped = Arc::new(std::sync::atomic::AtomicUsize::new(0));
    let winner = race([ipv6(1), ipv4(1)], |address| {
        let attempt = Attempt(Arc::clone(&dropped));
        async move {
            if address.is_ipv6() {
                std::future::pending::<()>().await;
            }
            drop(attempt);
            Ok(address)
        }
    })
    .await;
    assert_eq!(winner, Some(ipv4(1)));
    // The winner drops its own guard, and the race drops the silent attempt.
    assert_eq!(dropped.load(std::sync::atomic::Ordering::Relaxed), 2);
}

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
    let client = client();
    for _ in 0..2 {
        let request = Request::new(Method::POST, "https://127.0.0.1:9/messages");
        let error = client.send(request).await.err();
        assert_eq!(error, Some(Error::TlsSetupFailed));
    }
    let server = Answer {
        status: 200,
        body: BODY.into(),
        ..Answer::default()
    };
    let (_, out) = exchange(server, &client, None, None).await;
    assert_eq!(out.error, None);
}

#[cfg(target_os = "linux")]
#[test]
fn ssl_cert_dir_names_the_exact_roots() {
    // A child process keeps the root-store settings apart from the other tests. Its variable holds the expected result.
    const FOLDER_CHILD: &str = "HTTP_TEST_FOLDER_CHILD";

    if let Ok(expected) = std::env::var(FOLDER_CHILD) {
        assert_eq!(client().tls().is_ok(), expected == "roots");
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

// A test root and a server certificate for 127.0.0.1 that the root signed. The key belongs to the server certificate.
const TEST_ROOT: &str = "-----BEGIN CERTIFICATE-----\nMIIBTTCB9KADAgECAgkAkvlkYLCR9qYwCgYIKoZIzj0EAwIwGTEXMBUGA1UEAwwO\neXVrZSB0ZXN0IHJvb3QwIBcNMjYxMTA0MDg0MDUwWhgPMjEyNjEwMTEwODQwNTBa\nMBkxFzAVBgNVBAMMDnl1a2UgdGVzdCByb290MFkwEwYHKoZIzj0CAQYIKoZIzj0D\nAQcDQgAEvJs2A5BJybNDPGYo2Wg7jU123ITXN8SgtoVG1ulkIM4DzvZtjyJ6atGJ\n348fQEscA5T/e9YoHCIrEvTl8fvgAKMjMCEwDwYDVR0TAQH/BAUwAwEB/zAOBgNV\nHQ8BAf8EBAMCAgQwCgYIKoZIzj0EAwIDSAAwRQIhALhtvWGrB80h1G0g208bHDNT\nR86FZ2jZuRRe+4t3EpLiAiBW/ebDm+qC4hhvk5LBvAGW6/Az6z3eJjBQN8Fo/Yhv\n7g==\n-----END CERTIFICATE-----\n";
const TEST_SERVER_CERTIFICATE: &str = "-----BEGIN CERTIFICATE-----\nMIIBbDCCARKgAwIBAgIJAMwS4tTs0d6yMAoGCCqGSM49BAMCMBkxFzAVBgNVBAMM\nDnl1a2UgdGVzdCByb290MCAXDTI2MTEwNDA4NDA1MFoYDzIxMjYxMDExMDg0MDUw\nWjAUMRIwEAYDVQQDDAkxMjcuMC4wLjEwWTATBgcqhkjOPQIBBggqhkjOPQMBBwNC\nAATHubM1nPCMEtWOgq6R+A+qa6CRD0M8/R3Sxjn0mX8I1L2kYuorctjekDaIf448\nSlqYQNlHDyxafCBOu0mi+MbZo0YwRDAPBgNVHREECDAGhwR/AAABMAwGA1UdEwEB\n/wQCMAAwDgYDVR0PAQH/BAQDAgeAMBMGA1UdJQQMMAoGCCsGAQUFBwMBMAoGCCqG\nSM49BAMCA0gAMEUCIC0sblwbN4PLuOPNFXOqhVpicXsA+qqEVI7imuTAc8VnAiEA\nz2DaaMCV6Texom4GdE4MEK3vFJJXHJz1A6TDdTsS2Co=\n-----END CERTIFICATE-----\n";
const TEST_SERVER_KEY: &str = "-----BEGIN PRIVATE KEY-----\nMIGHAgEAMBMGByqGSM49AgEGCCqGSM49AwEHBG0wawIBAQQgbsZofkPG+78UBJHF\nIaSQYtPEmK8qMkTECacdfs/u8PKhRANCAATHubM1nPCMEtWOgq6R+A+qa6CRD0M8\n/R3Sxjn0mX8I1L2kYuorctjekDaIf448SlqYQNlHDyxafCBOu0mi+MbZ\n-----END PRIVATE KEY-----\n";

#[tokio::test]
async fn ssl_cert_file_decides_whether_a_handshake_succeeds() {
    use rustls::pki_types::pem::PemObject;
    use rustls::pki_types::{CertificateDer, PrivateKeyDer};
    use tokio::io::AsyncReadExt;

    // A child process keeps the root-store settings apart from the other tests. The variable holds the expected result.
    const HANDSHAKE_CHILD: &str = "HTTP_TEST_HANDSHAKE_CHILD";

    let Ok(expected) = std::env::var(HANDSHAKE_CHILD) else {
        let folder = std::env::temp_dir().join(format!("yuke-http-handshake-{}", std::process::id()));
        std::fs::create_dir_all(&folder).unwrap();
        // A bad section loses only itself. A file with only the server certificate lacks the root that signed it.
        let bad_section = format!("-----BEGIN CERTIFICATE-----\n!\n-----END CERTIFICATE-----\n{TEST_ROOT}");
        for (name, roots, expected) in [
            ("root", TEST_ROOT, "trusted"),
            ("bad-section", bad_section.as_str(), "trusted"),
            ("other", TEST_SERVER_CERTIFICATE, "rejected"),
        ] {
            let file = folder.join(format!("{name}.pem"));
            std::fs::write(&file, roots).unwrap();
            let status = std::process::Command::new(std::env::current_exe().unwrap())
                .args(["--exact", "tests::ssl_cert_file_decides_whether_a_handshake_succeeds"])
                .env(HANDSHAKE_CHILD, expected)
                .env("SSL_CERT_FILE", file)
                .env_remove("SSL_CERT_DIR")
                .stdout(std::process::Stdio::null())
                .status()
                .unwrap();
            assert!(status.success(), "{expected}");
        }
        std::fs::remove_dir_all(&folder).unwrap();
        return;
    };

    let provider = Arc::new(rustls::crypto::aws_lc_rs::default_provider());
    let config = rustls::ServerConfig::builder_with_provider(provider)
        .with_safe_default_protocol_versions()
        .unwrap()
        .with_no_client_auth()
        .with_single_cert(
            vec![CertificateDer::from_pem_slice(TEST_SERVER_CERTIFICATE.as_bytes()).unwrap()],
            PrivateKeyDer::from_pem_slice(TEST_SERVER_KEY.as_bytes()).unwrap(),
        )
        .unwrap();
    let acceptor = tokio_rustls::TlsAcceptor::from(Arc::new(config));
    let listener = TcpListener::bind("127.0.0.1:0").await.unwrap();
    let port = listener.local_addr().unwrap().port();
    let server = tokio::spawn(async move {
        let (tcp, _) = listener.accept().await.unwrap();
        // The client ends a rejected handshake, so only a trusted one reaches the request.
        let Ok(mut stream) = acceptor.accept(tcp).await else {
            return;
        };
        let mut seen = Vec::new();
        while !seen.ends_with(b"{}") {
            assert_ne!(stream.read_buf(&mut seen).await.unwrap(), 0);
        }
        stream
            .write_all(b"HTTP/1.1 200 OK\r\ncontent-length: 2\r\n\r\nok")
            .await
            .unwrap();
        stream.shutdown().await.unwrap();
    });

    let request = Request {
        body: vec![Bytes::from_static(b"{}")],
        ..Request::new(Method::POST, format!("https://127.0.0.1:{port}/messages"))
    };
    let out = run(&client(), request).await;
    if expected == "trusted" {
        assert_eq!(out.error, None);
        assert_eq!(out.status, Some(StatusCode::OK));
        assert_eq!(out.bytes, b"ok");
    } else {
        assert_eq!(out.error, Some(Error::CertificateRejected));
    }
    server.await.unwrap();
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
