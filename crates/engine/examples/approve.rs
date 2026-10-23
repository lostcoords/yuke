//! Ask for approval on stdin before each tool call. Stop the turn after a fixed number of rounds. Enter `y` to run a
//! call.
#![expect(clippy::print_stdout, reason = "an example prints its answer")]
#![expect(
    clippy::expect_used,
    reason = "an example stops when it cannot write to the terminal"
)]

use std::io::Write;
use std::sync::atomic::{AtomicBool, AtomicU32, Ordering};
use std::time::Duration;

use async_trait::async_trait;
use yuke_ai::{Block, FinishReason, ToolCall};
use yuke_engine::{
    Driver, Hooks, Observer, Outcome, RoundDecision, Timer, Tool, ToolContent, ToolContext, ToolDecision, Toolset,
    TurnEvent, parse_arguments,
};

/// The number of rounds before the hooks stop the turn.
const ROUND_LIMIT: u32 = 5;

/// Return the `text` argument in uppercase.
struct Uppercase;

/// The arguments of [`Uppercase`].
#[derive(serde::Deserialize)]
struct UppercaseArguments {
    text: String,
}

#[async_trait]
impl Tool for Uppercase {
    async fn call(&self, arguments: &str, _: &ToolContext<'_>) -> Result<ToolContent, String> {
        let arguments: UppercaseArguments = parse_arguments(arguments)?;
        Ok(arguments.text.to_uppercase().into())
    }
}

/// Ask the user before each call. Count the rounds.
#[derive(Default)]
struct Approve {
    rounds: AtomicU32,
}

#[async_trait]
impl Hooks for Approve {
    async fn before_tool(&self, call: &ToolCall) -> ToolDecision {
        print!("run {} {}? [y/n] ", call.name, call.arguments);
        std::io::stdout().flush().expect("Couldn't flush");
        let answer = tokio::task::spawn_blocking(|| {
            let mut line = String::new();
            std::io::stdin().read_line(&mut line).map(|_| line)
        })
        .await;

        // A failed read blocks the call, so an error never runs a tool.
        match answer {
            Ok(Ok(line)) if line.trim() == "y" => ToolDecision::Run,
            _ => ToolDecision::Block("The user blocked this call.".to_owned()),
        }
    }

    async fn after_round(
        &self,
        _: &[Block],
        _: Option<FinishReason>,
    ) -> Result<RoundDecision, Box<dyn std::error::Error + Send + Sync>> {
        if self.rounds.fetch_add(1, Ordering::Relaxed) + 1 >= ROUND_LIMIT {
            Ok(RoundDecision::Stop)
        } else {
            Ok(RoundDecision::Proceed)
        }
    }
}

/// Print the answer text when it arrives. End the open line before a call, so the approval prompt starts a line.
#[derive(Default)]
struct PrintText {
    line_open: AtomicBool,
}

impl Observer for PrintText {
    fn event(&self, event: &TurnEvent<'_>) {
        match event {
            TurnEvent::Model(yuke_ai::Event::TextDelta(delta)) => {
                print!("{}", delta.text);
                std::io::stdout().flush().expect("Couldn't flush");
                self.line_open.store(true, Ordering::Relaxed);
            }
            TurnEvent::ToolStarted { .. } if self.line_open.swap(false, Ordering::Relaxed) => println!(),
            _ => {}
        }
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
        context_window: None,
    };
    let http = yuke_http::Client::new(yuke_http::ClientOptions::new("engine-example"))?;
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
    let hooks = Approve::default();
    let driver = Driver::new(&http, &model, &TokioTimer).toolset(&toolset).hooks(&hooks);
    let mut context = Vec::new();
    let observer = PrintText::default();

    let input = vec![Block::user_text(
        "Use the uppercase tool on 'Hello, Rust!' and report its result.",
    )];
    let outcome = driver.turn(&mut context, input).observer(&observer).run().await?;

    match outcome {
        Outcome::Completed { .. } => println!(),
        Outcome::Stopped => println!("\nstopped after {ROUND_LIMIT} rounds"),
        Outcome::Cancelled => println!("\ncancelled"),
    }
    Ok(())
}
