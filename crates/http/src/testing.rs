//! A loopback HTTP server for tests. Each [`Answer`] answers one request. One connection can carry several
//! requests, so a test sees whether the client reuses a connection.
#![expect(clippy::unwrap_used, reason = "a fixture fails its test by panicking")]

use std::fmt::Write as _;
use std::time::Duration;

use tokio::io::{AsyncReadExt, AsyncWriteExt};
use tokio::net::{TcpListener, TcpStream};
use tokio::task::JoinHandle;

/// The answer of the loopback server to one request.
#[derive(Debug, Default)]
pub struct Answer {
    /// The status of the answer.
    pub status: u16,
    /// The body of the answer, in chunked transfer encoding.
    pub body: Vec<u8>,
    /// Raw bytes that the server sends in place of a normal response, for a malformed or a truncated response.
    pub raw_response: Option<&'static [u8]>,
    /// The headers after the content type, in order.
    pub headers: Vec<(&'static str, &'static str)>,
    /// Send the body, then keep the stream open until the client closes it.
    pub stall: bool,
    /// Read the request, then send no head until the client closes the connection.
    pub silent: bool,
    /// Send each body byte as its own chunk, with a pause before each one.
    pub trickle: bool,
}

/// What the server read of the request.
#[derive(Debug, Default)]
pub struct Seen {
    /// The method.
    pub method: String,
    /// The path and the query.
    pub target: String,
    /// Each header line as a name in lowercase and a trimmed value, in order.
    pub headers: Vec<(String, String)>,
    /// The body.
    pub body: Vec<u8>,
    /// The connection that carried the request: 0 for the first connection, 1 for the next, and so on.
    pub connection: usize,
}

impl Seen {
    /// The values of the header `name` (in lowercase), in order.
    pub fn values(&self, name: &str) -> Vec<&str> {
        self.headers
            .iter()
            .filter(|(field, _)| field == name)
            .map(|(_, value)| value.as_str())
            .collect()
    }
}

/// Bind a loopback port, and answer one request on it with `answer`. Return the port and the task, which ends with
/// what the server read.
pub async fn listen(answer: Answer) -> (u16, JoinHandle<Seen>) {
    let (listener, port) = bind().await;
    (
        port,
        tokio::spawn(async move { serve_all(listener, vec![answer]).await.remove(0) }),
    )
}

/// Bind a loopback port, and answer the requests on it in order: the first answer goes to the first request, and so
/// on. A connection carries requests until the client closes it or asks for the close, and the last answer asks for
/// the close. Return the port and the task, which ends after the last answer with what the server read of each
/// request.
pub async fn serve(answers: Vec<Answer>) -> (u16, JoinHandle<Vec<Seen>>) {
    let (listener, port) = bind().await;
    (port, tokio::spawn(serve_all(listener, answers)))
}

/// A listener on a free loopback port, and the port.
async fn bind() -> (TcpListener, u16) {
    let listener = TcpListener::bind("127.0.0.1:0").await.unwrap();
    let port = listener.local_addr().unwrap().port();
    (listener, port)
}

/// Read one request head and its body, by its `content-length`. `None` means that the client closed the connection
/// before a new request.
pub(crate) async fn read_request(stream: &mut TcpStream) -> Option<Seen> {
    let mut bytes = Vec::new();
    let mut buf = [0u8; 4096];
    let head_end = loop {
        let n = stream.read(&mut buf).await.unwrap();
        if n == 0 {
            assert!(bytes.is_empty(), "the client closed before the end of its head");
            return None;
        }
        bytes.extend_from_slice(&buf[..n]);
        if let Some(at) = bytes.windows(4).position(|w| w == b"\r\n\r\n") {
            break at + 4;
        }
    };
    let head = std::str::from_utf8(&bytes[..head_end]).unwrap();
    let mut lines = head.split("\r\n");
    let mut start = lines.next().unwrap().split(' ');
    let mut seen = Seen {
        method: start.next().unwrap().to_owned(),
        target: start.next().unwrap().to_owned(),
        ..Seen::default()
    };
    for line in lines.filter(|line| !line.is_empty()) {
        let (name, value) = line.split_once(':').unwrap();
        seen.headers.push((name.to_ascii_lowercase(), value.trim().to_owned()));
    }
    let length: usize = seen
        .values("content-length")
        .first()
        .map_or(0, |value| value.parse().unwrap());
    while bytes.len() < head_end + length {
        let n = stream.read(&mut buf).await.unwrap();
        assert_ne!(n, 0, "the client closed before the end of its body");
        bytes.extend_from_slice(&buf[..n]);
    }
    seen.body = bytes[head_end..].to_vec();
    Some(seen)
}

/// Wait until the client closes the connection.
async fn wait_for_close(stream: &mut TcpStream) {
    let mut buf = [0u8; 64];
    while matches!(stream.read(&mut buf).await, Ok(n) if n != 0) {}
}

/// Answer one request with each of `answers`, and give what the server read of each request.
async fn serve_all(listener: TcpListener, answers: Vec<Answer>) -> Vec<Seen> {
    let mut seen = Vec::new();
    let mut connection = 0;
    while seen.len() < answers.len() {
        let (mut stream, _) = listener.accept().await.unwrap();
        while let Some(mut request) = read_request(&mut stream).await {
            request.connection = connection;
            let answer = &answers[seen.len()];
            // The last answer closes the connection, so the task ends without a wait for the client.
            let last = seen.len() + 1 == answers.len();
            let close = last || request.values("connection") == ["close"];
            let open = write_answer(&mut stream, answer, close).await;
            seen.push(request);
            if !open {
                break;
            }
        }
        connection += 1;
    }
    seen
}

/// Write `answer` to one request. With `close`, the answer asks for the close of the connection. Return whether the
/// connection stays open for the next request.
async fn write_answer(stream: &mut TcpStream, answer: &Answer, close: bool) -> bool {
    if let Some(bytes) = answer.raw_response {
        stream.write_all(bytes).await.unwrap();
        return false;
    }
    if answer.silent {
        wait_for_close(stream).await;
        return false;
    }
    let mut head = format!("HTTP/1.1 {} OK\r\n", answer.status);
    if close {
        head.push_str("connection: close\r\n");
    }
    head.push_str("content-type: text/event-stream\r\n");
    for (name, value) in &answer.headers {
        _ = write!(head, "{name}: {value}\r\n");
    }
    head.push_str("transfer-encoding: chunked\r\n\r\n");
    let mut out = head.into_bytes();
    if answer.trickle {
        if stream.write_all(&out).await.is_err() {
            return false;
        }
        for byte in &answer.body {
            tokio::time::sleep(Duration::from_millis(1)).await;
            if stream
                .write_all(&[b'1', b'\r', b'\n', *byte, b'\r', b'\n'])
                .await
                .is_err()
            {
                return false;
            }
        }
        out.clear();
    } else if !answer.body.is_empty() {
        out.extend_from_slice(format!("{:x}\r\n", answer.body.len()).as_bytes());
        out.extend_from_slice(&answer.body);
        out.extend_from_slice(b"\r\n");
    }
    if answer.stall {
        // A failed write means that the client already closed, as a stalled request expects.
        _ = stream.write_all(&out).await;
        wait_for_close(stream).await;
        return false;
    }
    // One write, so the end of the body arrives with its last bytes.
    out.extend_from_slice(b"0\r\n\r\n");
    stream.write_all(&out).await.is_ok() && !close
}
