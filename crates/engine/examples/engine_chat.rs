//! Chat through the engine. The answer text prints while it streams. Press Ctrl-C to cancel an answer. Press Ctrl-D
//! to exit.
#![expect(
    clippy::print_stdout,
    clippy::print_stderr,
    reason = "an example prints the conversation"
)]
#![expect(
    clippy::expect_used,
    reason = "an example stops when it cannot write to the terminal"
)]

use std::io::{BufRead, Write};
use std::time::Duration;

use async_trait::async_trait;
use yuke_ai::{Block, HttpOptions, HttpTransport};
use yuke_engine::{CancellationToken, Driver, Observer, Outcome, Timer, TurnEvent};

/// Print each piece of answer text when it arrives.
struct PrintText;

impl Observer for PrintText {
    fn event(&self, event: &TurnEvent<'_>) {
        if let TurnEvent::Model(yuke_ai::Event::TextDelta(delta)) = event {
            print!("{}", delta.text);
            std::io::stdout().flush().expect("Couldn't flush");
        }
    }
}

/// The system prompt of each request.
const SYSTEM: &str = "You are a concise assistant. Answer in at most three sentences.";

/// The note that tells the model about a cancel. It goes first in the input of the next turn.
const INTERRUPTED: &str = "[The user interrupted the previous answer.]";

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
    let target = yuke_ai::catalog::resolve("minimax/MiniMax-M3", yuke_ai::route::Credential::ApiKey(key.into()))?;
    let http = HttpTransport::new(HttpOptions::new("engine-example"))?;

    let settings = yuke_ai::Settings::new().system(SYSTEM);
    let driver = Driver::new(&http, &target, &TokioTimer).settings(&settings);
    let mut history = Vec::new();
    let observer = PrintText;

    let mut cancelled = false;

    print!("You> ");
    std::io::stdout().flush()?;
    for line in std::io::stdin().lock().lines() {
        print!("AI> ");
        // A cancelled token cannot be reset, so each turn gets a new token.
        let cancellation_token = CancellationToken::new();

        let ctrl_c = tokio::spawn({
            let cancellation_token = cancellation_token.clone();
            async move {
                if tokio::signal::ctrl_c().await.is_ok() {
                    cancellation_token.cancel();
                }
            }
        });

        let mut input = Vec::new();
        if std::mem::take(&mut cancelled) {
            input.push(Block::user_text(INTERRUPTED));
        }
        input.push(Block::user_text(line?));
        let outcome = driver
            .turn(&mut history, input)
            .observer(&observer)
            .cancellation_token(cancellation_token)
            .run()
            .await;
        ctrl_c.abort();

        match outcome {
            // this is handled by the observer
            Ok(Outcome::Completed { .. } | Outcome::Stopped) => println!(),
            Ok(Outcome::Cancelled) => {
                println!(" [cancelled]");
                cancelled = true;
            }
            Err(error) => eprintln!("{error}"),
        }

        print!("You> ");
        std::io::stdout().flush()?;
    }
    Ok(())
}
