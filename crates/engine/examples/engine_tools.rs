//! Give the model one tool. The observer prints each call and its result, and it keeps the answer text.
#![expect(clippy::print_stdout, reason = "an example prints its answer")]

use std::sync::atomic::{AtomicU32, Ordering};
use std::sync::{Mutex, PoisonError};
use std::time::Duration;

use async_trait::async_trait;
use yuke_ai::{Block, HttpOptions, HttpTransport};
use yuke_engine::{
    Concurrency, Driver, Observer, Timer, Tool, ToolContent, ToolContext, Toolset, TurnEvent, parse_arguments,
};

/// Return the text in uppercase. The tool parses its arguments into a struct first.
struct Uppercase;

/// The arguments of [`Uppercase`].
#[derive(serde::Deserialize)]
struct UppercaseArguments {
    text: String,
}

#[async_trait]
impl Tool for Uppercase {
    // Each call only reads its arguments, so the calls of one answer can run together.
    fn concurrency(&self) -> Concurrency {
        Concurrency::Parallel
    }

    async fn call(&self, arguments: &str, _: &ToolContext<'_>) -> Result<ToolContent, String> {
        let arguments: UppercaseArguments = parse_arguments(arguments)?;
        Ok(arguments.text.to_uppercase().into())
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
    let model = yuke_engine::Model {
        target: yuke_ai::catalog::resolve("minimax/MiniMax-M3")?,
        source: std::sync::Arc::new(yuke_ai::route::Credential::ApiKey(key.into())),
    };
    let http = HttpTransport::new(HttpOptions::new("engine-example"))?;
    let mut toolset = Toolset::new();
    toolset.add(
        yuke_ai::ToolDefinition {
            name: "uppercase".to_owned(),
            description: "Convert text to uppercase.".to_owned(),
            input_schema: r#"{"type":"object","properties":{"text":{"type":"string"}},"required":["text"]}"#.to_owned(),
            defer_loading: false,
        },
        Uppercase,
    )?;
    let driver = Driver::new(&http, &model, &TokioTimer).toolset(&toolset);
    let mut context = Vec::new();
    let transcript = Transcript::default();

    let input = vec![Block::user_text(
        "Use the uppercase tool on 'Hello, Rust!' and report its result.",
    )];
    driver.turn(&mut context, input).observer(&transcript).run().await?;
    let answer = transcript.answer.into_inner().unwrap_or_else(PoisonError::into_inner);
    println!("{answer} ({} tool runs)", transcript.tool_runs.into_inner());
    Ok(())
}

/// Print each call and its result, and keep the answer text.
#[derive(Default)]
struct Transcript {
    answer: Mutex<String>,
    tool_runs: AtomicU32,
}

impl Observer for Transcript {
    fn event(&self, event: &TurnEvent<'_>) {
        match event {
            TurnEvent::ToolStarted { call, .. } => println!("call {} {}", call.name, call.arguments),
            TurnEvent::ToolFinished { result, .. } => {
                println!("result {}", result.content);
                self.tool_runs.fetch_add(1, Ordering::Relaxed);
            }
            TurnEvent::Model(yuke_ai::Event::TextDelta(delta)) => {
                self.answer
                    .lock()
                    .unwrap_or_else(PoisonError::into_inner)
                    .push_str(delta.text);
            }
            _ => {}
        }
    }
}
