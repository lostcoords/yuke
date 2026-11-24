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

use std::io::{BufRead, BufReader, Read, Write};
use std::net::{TcpListener, TcpStream};

use serde_json::{Value, json};

fn main() {
    if std::env::args().any(|arg| arg == "--http") {
        serve_http();
        return;
    }
    let stdin = std::io::stdin();
    let mut stdout = std::io::stdout();
    for line in stdin.lock().lines() {
        let Ok(line) = line else {
            return;
        };
        let Ok(message) = serde_json::from_str::<Value>(&line) else {
            continue;
        };
        let reply = match reply(&message) {
            Ok(Some(reply)) => reply,
            Ok(None) => continue,
            Err(_) => return,
        };
        if writeln!(stdout, "{reply}").and_then(|()| stdout.flush()).is_err() {
            return;
        }
    }
}

/// Log `message`, and give its reply. A notification and a call that never answers have none.
fn reply(message: &Value) -> std::io::Result<Option<Value>> {
    let method = message["method"].as_str().unwrap_or_default();
    let params = &message["params"];
    match method {
        "initialize" => log(&format!("initialize {}", params["protocolVersion"]))?,
        "tools/call" => log(&format!("call {}", message["id"]))?,
        "notifications/cancelled" => log(&format!("cancelled {}", params["requestId"]))?,
        _ => {}
    }
    let Some(id) = message.get("id") else {
        return Ok(None);
    };
    let answer = match method {
        "initialize" => Ok(json!({
            "protocolVersion": "2025-11-25",
            "capabilities": { "tools": {} },
            "serverInfo": { "name": "test", "version": "1.0.0" },
        })),
        "ping" => Ok(json!({})),
        "tools/list" => Ok(json!({ "tools": tools() })),
        "tools/call" => match call(params) {
            Some(result) => Ok(result),
            None => return Ok(None),
        },
        _ => Err(json!({ "code": -32_601, "message": "Method not found" })),
    };
    Ok(Some(match answer {
        Ok(result) => json!({ "jsonrpc": "2.0", "id": id, "result": result }),
        Err(error) => json!({ "jsonrpc": "2.0", "id": id, "error": error }),
    }))
}

/// Answer HTTP on a free loopback port, with one thread for each connection.
fn serve_http() {
    let Ok(listener) = TcpListener::bind("127.0.0.1:0") else {
        return;
    };
    let Ok(address) = listener.local_addr() else {
        return;
    };
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

/// Answer the requests of one connection until the client closes it.
fn connection(stream: TcpStream) {
    let Ok(mut writer) = stream.try_clone() else {
        return;
    };
    let mut reader = BufReader::new(stream);
    loop {
        let mut start = String::new();
        if !matches!(reader.read_line(&mut start), Ok(1..)) {
            return;
        }
        let (mut length, mut key, mut session) = (0, None, None);
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
                "x-api-key" => key = Some(value),
                "mcp-session-id" => session = Some(value),
                _ => {}
            }
        }
        let mut body = vec![0; length];
        if reader.read_exact(&mut body).is_err() {
            return;
        }
        let key = key.unwrap_or_default();
        let logged = if start.starts_with("DELETE") {
            log(&format!("delete {} {key}", session.unwrap_or_default()))
        } else if key.is_empty() {
            Ok(())
        } else {
            log(&format!("key {key}"))
        };
        if logged.is_err() {
            return;
        }
        if key == "deny" {
            _ = writer.write_all(http_answer("401 Unauthorized", "text/plain", "no access").as_bytes());
            continue;
        }
        let message = serde_json::from_slice::<Value>(&body).unwrap_or_default();
        let answer = match reply(&message) {
            Ok(Some(reply)) if message["method"] == "tools/call" => {
                let body = format!("data: {reply}\n\n");
                http_answer("200 OK", "text/event-stream", &body)
            }
            Ok(Some(reply)) => http_answer("200 OK", "application/json", &reply.to_string()),
            // A call that never answers holds its connection until the client closes it.
            Ok(None) if message.get("id").is_some() => {
                _ = std::io::copy(&mut reader, &mut std::io::sink());
                return;
            }
            Ok(None) => http_answer("202 Accepted", "application/json", ""),
            Err(_) => return,
        };
        if writer.write_all(answer.as_bytes()).is_err() {
            return;
        }
    }
}

/// An HTTP answer with `status`, the content type `kind`, and `body`, in the session `s1`.
fn http_answer(status: &str, kind: &str, body: &str) -> String {
    format!(
        "HTTP/1.1 {status}\r\ncontent-type: {kind}\r\nmcp-session-id: s1\r\ncontent-length: {}\r\n\r\n{body}",
        body.len()
    )
}

/// Add `line` to the file `MCP_TEST_LOG`, when it is set.
fn log(line: &str) -> std::io::Result<()> {
    let Ok(path) = std::env::var("MCP_TEST_LOG") else {
        return Ok(());
    };
    let mut file = std::fs::OpenOptions::new().create(true).append(true).open(path)?;
    writeln!(file, "{line}")
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
        // The server exits after a failed write too.
        "exit" => match writeln!(std::io::stderr(), "exit") {
            Ok(()) | Err(_) => std::process::exit(0),
        },
        _ => return None,
    })
}
