//! The MCP server of the tests: one JSON-RPC message per line on stdin and stdout. It speaks the versions with
//! `initialize`, and it answers a method that it lacks with Method not found. Its tools:
//!
//! - `echo` answers the text of its `text` argument.
//! - `picture` answers an image and a text.
//! - `huge` answers an image one byte over the media limit of yuke.
//! - `fail` answers an error result.
//! - `structured` answers only structured content.
//! - `exit` writes `exit` to stderr and ends the server without an answer.
//! - `wait` never answers.
//!
//! With `MCP_TEST_LOG`, the server adds a line to that file for the version that the client asks for
//! (`initialize <version>`) and for each cancel (`cancelled <id>`).

use std::io::{BufRead, Write};

use serde_json::{Value, json};

fn main() {
    let stdin = std::io::stdin();
    let mut stdout = std::io::stdout();
    for line in stdin.lock().lines() {
        let Ok(line) = line else {
            return;
        };
        let Ok(message) = serde_json::from_str::<Value>(&line) else {
            continue;
        };
        let method = message["method"].as_str().unwrap_or_default();
        let params = &message["params"];
        let logged = match method {
            "initialize" => log(&format!("initialize {}", params["protocolVersion"])),
            "notifications/cancelled" => log(&format!("cancelled {}", params["requestId"])),
            _ => Ok(()),
        };
        if logged.is_err() {
            return;
        }
        let Some(id) = message.get("id") else {
            continue;
        };
        let answer = match method {
            "initialize" => {
                // A server answers the version of the client when it speaks it, and else its newest version.
                let asked = params["protocolVersion"].as_str().unwrap_or_default();
                let version = VERSIONS
                    .into_iter()
                    .find(|version| *version == asked)
                    .unwrap_or(VERSIONS[0]);
                Ok(json!({
                    "protocolVersion": version,
                    "capabilities": { "tools": {} },
                    "serverInfo": { "name": "test", "version": "1.0.0" },
                }))
            }
            "ping" => Ok(json!({})),
            "tools/list" => Ok(json!({ "tools": tools() })),
            "tools/call" => match call(params) {
                Some(result) => Ok(result),
                None => continue,
            },
            _ => Err(json!({ "code": -32_601, "message": "Method not found" })),
        };
        let reply = match answer {
            Ok(result) => json!({ "jsonrpc": "2.0", "id": id, "result": result }),
            Err(error) => json!({ "jsonrpc": "2.0", "id": id, "error": error }),
        };
        if writeln!(stdout, "{reply}").and_then(|()| stdout.flush()).is_err() {
            return;
        }
    }
}

/// Add `line` to the file `MCP_TEST_LOG`, when it is set.
fn log(line: &str) -> std::io::Result<()> {
    let Ok(path) = std::env::var("MCP_TEST_LOG") else {
        return Ok(());
    };
    let mut file = std::fs::OpenOptions::new().create(true).append(true).open(path)?;
    writeln!(file, "{line}")
}

/// The protocol versions with `initialize`, newest first.
const VERSIONS: [&str; 4] = ["2025-11-25", "2025-06-18", "2025-03-26", "2024-11-05"];

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
        tool("huge", "Draw a huge picture."),
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
        // The base64 of 3 * 1_310_720 + 1 zero bytes: one byte over the 5 MiB of base64 that yuke takes.
        "huge" => json!({
            "content": [{ "type": "image", "data": "A".repeat(4 * 1_310_720) + "AA==", "mimeType": "image/png" }],
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
