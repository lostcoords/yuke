//! The MCP server of the tests: one JSON-RPC message per line on stdin and stdout. It speaks version 2025-11-25,
//! and it answers a method that it lacks with Method not found.
//!
//! With `--http`, it listens on a free loopback port and writes the port as the first line of stdout. Each POST carries
//! one message. It answers a call as an event stream and each other request as JSON, with the session `s1`. Its tools:
//!
//! - `echo` answers the text of its `text` argument.
//! - `picture` answers an image and a text.
//! - `fail` answers an error result.
//! - `structured` answers only structured content.
//! - `exit` writes `exit` to stderr and ends the server without an answer.
//! - `wait` never answers.
//!
//! With `MCP_TEST_LOG`, the server writes one line to that file for each event: `initialize <version>`, `call <id>`,
//! or `cancelled <id>`. Over HTTP, it also writes `key <value>` for the `x-api-key` header of each POST, and
//! `delete <session> <key>` for the end of a session. It answers a request with the key `deny` with 401.
//!
//! With `MCP_TEST_OAUTH`, the endpoint `/mcp` needs a bearer token, and the server is an authorization server too. See
//! the `oauth` module.

use std::io::{BufRead, BufReader, Read, Write};
use std::net::{TcpListener, TcpStream};

use serde_json::{Value, json};

mod oauth;

fn main() {
    if std::env::args().any(|arg| arg == "--http") {
        serve_http();
        return;
    }
    let mut stdout = std::io::stdout();
    for line in std::io::stdin().lock().lines().map_while(Result::ok) {
        let Ok(message) = serde_json::from_str::<Value>(&line) else {
            continue;
        };
        if let Some(reply) = reply(&message)
            && writeln!(stdout, "{reply}").and_then(|()| stdout.flush()).is_err()
        {
            return;
        }
    }
}

/// Log `message`, and give its reply. A notification and a call that never answers have none.
fn reply(message: &Value) -> Option<Value> {
    let method = message["method"].as_str().unwrap_or_default();
    let params = &message["params"];
    match method {
        "initialize" => log(&format!("initialize {}", params["protocolVersion"])),
        "tools/call" => log(&format!("call {}", message["id"])),
        "notifications/cancelled" => log(&format!("cancelled {}", params["requestId"])),
        _ => {}
    }
    let id = message.get("id")?;
    let result = match method {
        "initialize" => json!({
            "protocolVersion": "2025-11-25",
            "capabilities": { "tools": {} },
            "serverInfo": { "name": "test", "version": "1.0.0" },
        }),
        "ping" => json!({}),
        "tools/list" => json!({ "tools": tools() }),
        "tools/call" => call(params)?,
        _ => {
            return Some(
                json!({ "jsonrpc": "2.0", "id": id, "error": { "code": -32_601, "message": "Method not found" } }),
            );
        }
    };
    Some(json!({ "jsonrpc": "2.0", "id": id, "result": result }))
}

/// Answer HTTP on a free loopback port, with one thread for each connection.
fn serve_http() {
    let Ok(listener) = TcpListener::bind("127.0.0.1:0") else {
        return;
    };
    let Ok(address) = listener.local_addr() else {
        return;
    };
    oauth::set_port(address.port());
    let mut stdout = std::io::stdout();
    if writeln!(stdout, "{}", address.port())
        .and_then(|()| stdout.flush())
        .is_err()
    {
        return;
    }
    for stream in listener.incoming().flatten() {
        std::thread::spawn(move || connection(stream));
    }
}

/// One HTTP request, with the headers that the server reads.
#[derive(Default)]
struct Request {
    start: String,
    key: Option<String>,
    session: Option<String>,
    authorization: Option<String>,
    body: Vec<u8>,
}

/// Answer the requests of one connection until the client closes it.
fn connection(stream: TcpStream) {
    let Ok(mut writer) = stream.try_clone() else {
        return;
    };
    let mut reader = BufReader::new(stream);
    loop {
        let mut request = Request::default();
        let mut length = 0;
        if !matches!(reader.read_line(&mut request.start), Ok(1..)) {
            return;
        }
        loop {
            let mut line = String::new();
            if !matches!(reader.read_line(&mut line), Ok(1..)) {
                return;
            }
            let Some((name, value)) = line.trim_end().split_once(':') else {
                break;
            };
            let value = value.trim().to_owned();
            match name.to_ascii_lowercase().as_str() {
                "content-length" => length = value.parse().unwrap_or_default(),
                "x-api-key" => request.key = Some(value),
                "mcp-session-id" => request.session = Some(value),
                "authorization" => request.authorization = Some(value),
                _ => {}
            }
        }
        request.body = vec![0; length];
        if reader.read_exact(&mut request.body).is_err() {
            return;
        }
        let Some(answer) = respond(&request) else {
            // A call that never answers holds its connection until the client closes it.
            _ = std::io::copy(&mut reader, &mut std::io::sink());
            return;
        };
        if writer.write_all(answer.as_bytes()).is_err() {
            return;
        }
    }
}

/// The answer to `request`, or `None` for a call that never answers.
fn respond(request: &Request) -> Option<String> {
    let mut parts = request.start.split(' ');
    let (method, target) = (parts.next().unwrap_or_default(), parts.next().unwrap_or_default());
    if let Some(answer) = oauth::route(method, target, &request.body) {
        return Some(answer);
    }
    if let Some(answer) = oauth::challenge(request.authorization.as_deref()) {
        return Some(answer);
    }
    let key = request.key.as_deref().unwrap_or_default();
    if method == "DELETE" {
        log(&format!(
            "delete {} {key}",
            request.session.as_deref().unwrap_or_default()
        ));
    } else if !key.is_empty() {
        log(&format!("key {key}"));
    }
    if key == "deny" {
        return Some(http_answer("401 Unauthorized", "text/plain", "no access"));
    }
    let message = serde_json::from_slice::<Value>(&request.body).unwrap_or_default();
    match reply(&message) {
        Some(reply) if message["method"] == "tools/call" => Some(http_answer(
            "200 OK",
            "text/event-stream",
            &format!("data: {reply}\n\n"),
        )),
        Some(reply) => Some(http_answer("200 OK", "application/json", &reply.to_string())),
        None if message.get("id").is_some() => None,
        None => Some(http_answer("202 Accepted", "application/json", "")),
    }
}

/// An HTTP answer with `status`, the content type `kind`, and `body`, in the session `s1`.
fn http_answer(status: &str, kind: &str, body: &str) -> String {
    format!(
        "HTTP/1.1 {status}\r\ncontent-type: {kind}\r\nmcp-session-id: s1\r\ncontent-length: {}\r\n\r\n{body}",
        body.len()
    )
}

/// Add `line` to the file `MCP_TEST_LOG`, when it is set. A test that misses a line fails on its own.
fn log(line: &str) {
    let Ok(path) = std::env::var("MCP_TEST_LOG") else {
        return;
    };
    if let Ok(mut file) = std::fs::OpenOptions::new().create(true).append(true).open(path) {
        _ = writeln!(file, "{line}");
    }
}

/// The base64 PNG of one pixel.
const PIXEL: &str = "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mNkYPhfDwAChwGA60e6kgAAAABJRU5ErkJggg==";

fn tools() -> Value {
    let object = json!({ "type": "object", "properties": { "text": { "type": "string" } } });
    let tool =
        |name: &str, description: &str| json!({ "name": name, "description": description, "inputSchema": object });
    let mut echo = tool("echo", "Echo the text.");
    echo["title"] = json!("Echo");
    let mut picture = tool("picture", "Draw a picture.");
    picture["annotations"] = json!({ "title": "Picture" });
    json!([
        echo,
        picture,
        tool("fail", "Fail."),
        tool("structured", "Answer a structure."),
        tool("wait", "Wait forever."),
        tool("exit", "Exit."),
    ])
}

/// The result of a call, or `None` for a call that never answers.
fn call(params: &Value) -> Option<Value> {
    let text = |text: &str| json!({ "type": "text", "text": text });
    Some(match params["name"].as_str().unwrap_or_default() {
        "echo" => json!({ "content": [text(params["arguments"]["text"].as_str().unwrap_or_default())] }),
        // The PNG of one pixel.
        "picture" => json!({
            "content": [{ "type": "image", "data": PIXEL, "mimeType": "image/png" }, text("a picture")],
        }),
        "fail" => json!({ "content": [text("it broke")], "isError": true }),
        "structured" => json!({ "content": [], "structuredContent": { "answer": 42 } }),
        "exit" => {
            _ = writeln!(std::io::stderr(), "exit");
            std::process::exit(0)
        }
        _ => return None,
    })
}
