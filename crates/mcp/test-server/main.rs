//! The MCP server of the tests: one JSON-RPC message per line on stdin and stdout. Its tools:
//!
//! - `echo` answers the text of its `text` argument.
//! - `picture` answers an image and a text.
//! - `fail` answers an error result.
//! - `structured` answers only structured content.
//! - `exit` ends the server without an answer.
//! - `wait` never answers. A `notifications/cancelled` for it writes `cancelled <id>` to the file `MCP_TEST_LOG`.

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
        if method == "notifications/cancelled"
            && let Ok(path) = std::env::var("MCP_TEST_LOG")
        {
            let id = &message["params"]["requestId"];
            let written = std::fs::write(path, format!("cancelled {id}"));
            if written.is_err() {
                return;
            }
        }
        let Some(id) = message.get("id") else {
            continue;
        };
        let result = match method {
            "initialize" => json!({
                "protocolVersion": message["params"]["protocolVersion"],
                "capabilities": { "tools": {} },
                "serverInfo": { "name": "test", "version": "1.0.0" },
            }),
            "tools/list" => json!({ "tools": tools() }),
            "tools/call" => match call(&message["params"]) {
                Some(result) => result,
                None => continue,
            },
            _ => json!({}),
        };
        let reply = json!({ "jsonrpc": "2.0", "id": id, "result": result });
        if writeln!(stdout, "{reply}").and_then(|()| stdout.flush()).is_err() {
            return;
        }
    }
}

fn tools() -> Value {
    let object = json!({ "type": "object", "properties": { "text": { "type": "string" } } });
    let tool =
        |name: &str, description: &str| json!({ "name": name, "description": description, "inputSchema": object });
    json!([
        tool("echo", "Echo the text."),
        tool("picture", "Draw a picture."),
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
        // The data is the base64 of the bytes `png!`.
        "picture" => json!({
            "content": [{ "type": "image", "data": "cG5nIQ==", "mimeType": "image/png" }, text("a picture")],
        }),
        "fail" => json!({ "content": [text("it broke")], "isError": true }),
        "structured" => json!({ "content": [], "structuredContent": { "answer": 42 } }),
        "exit" => std::process::exit(0),
        _ => return None,
    })
}
