//! Give the model one tool. The observer prints each call and its result, and it keeps the answer text.
#![expect(clippy::print_stdout, reason = "an example prints its answer")]

use std::time::Duration;

use ai::{Block, HttpOptions, HttpTransport};
use async_trait::async_trait;
use engine::{CancellationToken, Conversation, Driver, Observer, Timer, Tool, Toolset, TurnEvent};

/// Return the argument text in uppercase.
struct Uppercase;

#[async_trait]
impl Tool for Uppercase {
    async fn call(&self, arguments: &str, _: &CancellationToken) -> Result<String, String> {
        Ok(arguments.to_uppercase())
    }
}

/// Wait with the Tokio timer.
struct TokioTimer;

#[async_trait]
impl Timer for TokioTimer {
    async fn sleep(&self, duration: Duration) {
        tokio::time::sleep(duration).await;
    }
}

#[tokio::main(flavor = "current_thread")]
async fn main() -> Result<(), Box<dyn std::error::Error>> {
    let key = std::env::var("MINIMAX_API_KEY")?;
    let target = ai::catalog::resolve("minimax/MiniMax-M3", ai::route::Credential::ApiKey(key.into()))?;
    let http = HttpTransport::new(HttpOptions::new("engine-example"))?;
    let mut toolset = Toolset::new();
    toolset.add(
        ai::ToolDefinition::new(
            "uppercase",
            "Convert text to uppercase.",
            r#"{"type":"object","properties":{"text":{"type":"string"}},"required":["text"]}"#,
        ),
        Uppercase,
    )?;
    let driver = Driver::new(&http, &target, &TokioTimer).toolset(&toolset);
    let mut conversation = Conversation::new();
    let mut transcript = Transcript::default();

    let input = vec![Block::user_text(
        "Use the uppercase tool on 'Hello, Rust!' and report its result.",
    )];
    driver
        .turn(&mut conversation, input)
        .observer(&mut transcript)
        .run()
        .await?;
    println!("{} ({} tool runs)", transcript.answer, transcript.tool_runs);
    Ok(())
}

/// Print each call and its result, and keep the answer text.
#[derive(Default)]
struct Transcript {
    answer: String,
    tool_runs: u32,
}

impl Observer for Transcript {
    fn event(&mut self, event: &TurnEvent<'_>) {
        match event {
            TurnEvent::ToolStarted(call) => println!("call {} {}", call.name, call.arguments),
            TurnEvent::ToolFinished(result) => {
                println!("result {}", result.content);
                self.tool_runs += 1;
            }
            TurnEvent::Model(ai::Event::TextDelta(delta)) => self.answer.push_str(delta.text),
            _ => {}
        }
    }
}
