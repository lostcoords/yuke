//! Give the model a tool, run any calls it returns, then ask it to summarize the results.
#![expect(clippy::print_stdout, reason = "an example prints its answer")]

use yuke_ai::{
    Block, Effort, FinishReason, HttpOptions, HttpTransport, Request, ToolCall, ToolChoice, ToolDefinition, ToolResult,
};

const SCHEMA: &str = r#"{
  "type": "object",
  "properties": {
    "text": { "type": "string" }
  },
  "required": ["text"],
  "additionalProperties": false
}"#;

#[tokio::main(flavor = "current_thread")]
async fn main() -> Result<(), Box<dyn std::error::Error>> {
    let key = std::env::var("OPENAI_API_KEY")?;
    let target = yuke_ai::catalog::resolve("openai/gpt-6-astra", yuke_ai::route::Credential::ApiKey(key.into()))?;
    let http = HttpTransport::new(HttpOptions::new("ai-example"))?;
    let tools = [ToolDefinition::new(
        "uppercase_ascii",
        "Convert ASCII letters in text to uppercase. Leave other characters unchanged.",
        SCHEMA,
    )];

    let mut conversation = vec![Block::user_text(
        "Use uppercase_ascii on 'Hello, Rust!' and report its result.",
    )];
    let request = Request::new(&conversation)
        .tools(&tools)
        .max_output_tokens(4096)
        .effort(Effort::Low);
    let first = yuke_ai::generate(&http, &target, request).await?.completion;

    // Only a `ToolCalls` finish proves complete calls. After a `Length` finish, a call can hold cut-off arguments.
    if first.finish_reason != FinishReason::ToolCalls {
        println!("{}", first.text());
        return Ok(());
    }
    let results: Vec<ToolResult> = first.tool_calls().map(execute).collect();

    // Replay the whole assistant turn, then answer each call.
    conversation.extend(first.into_blocks());
    conversation.extend(results.into_iter().map(Block::from));

    // Send the tool results back, but don't allow another round of tool calls.
    let request = Request::new(&conversation)
        .tools(&tools)
        .tool_choice(ToolChoice::None)
        .max_output_tokens(4096)
        .effort(Effort::Low);
    let last = yuke_ai::generate(&http, &target, request).await?.completion;
    println!("{}", last.text());
    Ok(())
}

/// Run one call. An error result tells the model what went wrong.
fn execute(call: &ToolCall) -> ToolResult {
    if call.name != "uppercase_ascii" {
        return ToolResult::error(&call.call_id, "Unknown tool.");
    }
    let arguments: serde_json::Value = match serde_json::from_str(&call.arguments) {
        Ok(arguments) => arguments,
        Err(error) => return ToolResult::error(&call.call_id, error.to_string()),
    };
    match arguments.get("text").and_then(serde_json::Value::as_str) {
        Some(text) => ToolResult::success(&call.call_id, text.to_ascii_uppercase()),
        None => ToolResult::error(&call.call_id, "Expected an object with one string field named text."),
    }
}
