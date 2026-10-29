//! Loopback tests of the provider rules over [`Client`]: one real server and one real client per test.

use std::time::Duration;

use tokio::io::{AsyncReadExt, AsyncWriteExt};
use tokio::net::TcpListener;
use tokio::time::Instant;
use yuke_http::ClientOptions;
use yuke_http::testing::{Seen, Server, listen};

use super::*;

const TEST_USER_AGENT: &str = "ai-test/0";

const CANNED_SSE: &str = "data: {\"type\":\"message_start\",\"message\":{\"usage\":{\"input_tokens\":1}}}\n\n\
                          data: {\"type\":\"message_stop\"}\n\n";

/// The headers every request sends. Repeated lines of a list-valued header keep their order.
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

/// What the client observed of one request.
#[derive(Debug, Default)]
struct ClientOut {
    head: Option<Head>,
    bytes: Vec<u8>,
    err: Option<Fault>,
}

/// Open the request and read the whole body. The request input drops before the body is read.
async fn run_client(client: &Client, port: u16) -> ClientOut {
    let mut out = ClientOut::default();
    let opened = {
        let url = format!("http://127.0.0.1:{port}/messages");
        let headers = source_headers();
        let body = b"{}".to_vec();
        let request = Outgoing::from_parts(&url, &headers, [&body, &[], &[]]);
        client.open(&request, None).await
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

fn client() -> Client {
    Client::new(ClientOptions {
        idle_timeout: None,
        user_agent: TEST_USER_AGENT.to_owned(),
    })
    .unwrap()
}

/// Run one server and one client request on a private loopback port.
async fn exchange(server: Server, client: &Client) -> (Seen, ClientOut) {
    let (port, served) = listen(server).await;
    let out = run_client(client, port).await;
    (served.await.unwrap(), out)
}

fn after(ms: u64) -> std::time::Instant {
    std::time::Instant::now() + Duration::from_millis(ms)
}

#[tokio::test]
async fn streams_sse_body() {
    for client in [client(), Client::new(ClientOptions::new(TEST_USER_AGENT)).unwrap()] {
        let server = Server {
            status: 200,
            body: CANNED_SSE.into(),
            ..Server::default()
        };
        let (seen, out) = exchange(server, &client).await;
        assert_eq!(out.err, None);
        assert_eq!(out.head.unwrap().status, 200);
        assert_eq!(out.bytes, CANNED_SSE.as_bytes());
        assert_eq!(seen.values("user-agent"), [TEST_USER_AGENT]);
        assert_eq!(seen.values("accept-language"), ["en", "es"]);
        assert_eq!(seen.values("x-note"), ["café"]);
        assert_eq!(seen.values("content-type"), ["application/json"]);
        assert_eq!(seen.values("accept"), ["text/event-stream"]);
        assert_eq!(seen.values("accept-encoding"), ["identity"]);
        assert_eq!(seen.method, "POST");
    }
}

/// Run one server and one exchange of a form `body` with an answer limit of `max_answer` bytes.
async fn exchange_once(server: Server, body: &[u8], max_answer: usize) -> (Seen, Result<Answer, Fault>) {
    let (port, served) = listen(server).await;
    let url = format!("http://127.0.0.1:{port}/oauth2/token");
    let request = ExchangeRequest {
        url: &url,
        content_type: "application/x-www-form-urlencoded",
        body,
        max_answer,
    };
    let answer = client().exchange(&request, None).await;
    (served.await.unwrap(), answer)
}

#[tokio::test]
async fn an_exchange_sends_its_type_and_body_and_reads_the_whole_answer() {
    let server = Server {
        status: 400,
        body: br#"{"error":"authorization_pending"}"#.to_vec(),
        headers: vec![("request-id", "req_1")],
        trickle: true,
        ..Server::default()
    };

    let (seen, answer) = exchange_once(server, b"grant_type=refresh_token", 1024).await;

    let answer = answer.unwrap();
    assert_eq!(answer.head.status, 400);
    assert_eq!(answer.head.request_id.as_deref(), Some("req_1"));
    assert_eq!(answer.body, br#"{"error":"authorization_pending"}"#);
    assert_eq!(seen.values("content-type"), ["application/x-www-form-urlencoded"]);
    assert_eq!(seen.values("accept"), ["application/json"]);
    assert_eq!(seen.body, b"grant_type=refresh_token");
}

#[tokio::test]
async fn an_exchange_answer_over_its_limit_fails() {
    let server = || Server {
        status: 200,
        body: b"0123456789".to_vec(),
        ..Server::default()
    };

    let (_, fits) = exchange_once(server(), b"", 10).await;
    let (_, large) = exchange_once(server(), b"", 9).await;

    assert_eq!(fits.unwrap().body, b"0123456789");
    assert_eq!(large, Err(Fault::AnswerTooLarge));
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
    let (_, out) = exchange(server, &client()).await;
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
        let (_, out) = exchange(server, &client()).await;
        assert_eq!(out.err, None);
        let head = out.head.unwrap();
        assert_eq!(head.request_id.as_deref(), request_id);
        assert_eq!(head.retry_after_ms, retry_after_ms);
        assert_eq!(head.should_retry, should_retry);
    }
}

#[tokio::test]
async fn redirect_is_refused() {
    // The client must reject a 302 response to another origin to keep the key private.
    let server = Server {
        status: 302,
        headers: vec![("location", "http://evil.example/steal")],
        ..Server::default()
    };
    let (_, out) = exchange(server, &client()).await;
    assert_eq!(out.err, Some(Fault::RedirectRefused));
    assert_eq!(out.bytes, b"");
    // A 304 has no redirect target, so it is a response.
    let server = Server {
        status: 304,
        ..Server::default()
    };
    let (_, out) = exchange(server, &client()).await;
    assert_eq!(out.err, None);
    assert_eq!(out.head.unwrap().status, 304);
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
        let (_, out) = exchange(server, &client()).await;
        assert_eq!(out.err, fault, "{encoding:?}");
        if fault.is_none() {
            assert_eq!(out.head.unwrap().status, 200);
            assert_eq!(out.bytes, CANNED_SSE.as_bytes());
        } else {
            assert!(out.bytes.is_empty(), "{encoding:?}");
        }
    }
}

// A `HeaderMap` holds at most 32768 names, so more names fail the request, and it sends nothing.
#[tokio::test]
async fn too_many_headers_fail_before_send() {
    let many: Vec<Header> = (0..40_000)
        .map(|index| Header::new(format!("x-{index}"), "1"))
        .collect();
    let valid = [Header::from_static("x-note", "valid")];
    let ((fault, bytes), (valid_fault, valid_bytes)) =
        tokio::join!(observe_http_bytes(&many), observe_http_bytes(&valid));
    assert_eq!(fault, Some(Fault::InvalidRequest));
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
    let request = Outgoing::from_parts(&url, headers, [b"{}", &[], &[]]);
    let client = client();
    let opened = tokio::time::timeout(Duration::from_secs(5), client.open(&request, Some(after(1000)))).await;
    let observed = tokio::time::timeout(Duration::from_secs(5), &mut peer).await;
    if observed.is_err() {
        peer.abort();
        _ = peer.await;
    }
    (opened.unwrap().err(), observed.unwrap().unwrap())
}

// The retry policy reads the fault, so each client error becomes the fault of the same name.
#[test]
fn each_client_error_becomes_the_fault_of_its_name() {
    for error in [
        Error::InvalidRequest,
        Error::BadUrl,
        Error::DnsFailed,
        Error::ConnectFailed,
        Error::ConnectTimeout,
        Error::CertificateRejected,
        Error::TlsSetupFailed,
        Error::IdleTimeout,
        Error::RequestTimeout,
        Error::ConnectionLost,
        Error::MalformedResponse,
    ] {
        assert_eq!(format!("{:?}", fault_of(error)), format!("{error:?}"));
    }
}

// A body error reaches the stream of the provider as its fault.
#[tokio::test]
async fn a_truncated_body_is_a_lost_connection() {
    let server = Server {
        raw_response: Some(b"HTTP/1.1 200 OK\r\nContent-Length: 4\r\nConnection: close\r\n\r\nx"),
        ..Server::default()
    };
    let (_, out) = exchange(server, &client()).await;
    assert_eq!(out.head.unwrap().status, 200);
    assert_eq!(out.err, Some(Fault::ConnectionLost));
}
