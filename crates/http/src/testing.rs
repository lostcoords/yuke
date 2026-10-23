//! A loopback HTTP server for tests. It accepts one connection, reads one request, and sends the response that a
//! [`Server`] defines.
#![expect(
    clippy::unwrap_used,
    clippy::missing_panics_doc,
    reason = "a fixture fails its test by panicking"
)]

use std::fmt::Write as _;
use std::time::Duration;

use tokio::io::{AsyncReadExt, AsyncWriteExt};
use tokio::net::{TcpListener, TcpStream};
use tokio::task::JoinHandle;

/// The response that one loopback server sends.
#[derive(Debug, Default)]
pub struct Server {
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

/// Bind a loopback port, and answer one connection on it as `server` says. Return the port and the task, which ends
/// with what the server read.
pub async fn listen(server: Server) -> (u16, JoinHandle<Seen>) {
    let listener = TcpListener::bind("127.0.0.1:0").await.unwrap();
    let port = listener.local_addr().unwrap().port();
    (port, tokio::spawn(serve_once(listener, server)))
}

/// Read one request head and its body, by its `content-length`.
pub(crate) async fn read_request(stream: &mut TcpStream) -> Seen {
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
    // A failed write means that the client already closed, as a stalled request expects.
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
