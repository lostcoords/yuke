//! Chat through the engine. The answer text prints while it streams. Press Ctrl-D to exit.
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

use ai::{Block, HttpOptions, HttpTransport};
use async_trait::async_trait;
use engine::{Conversation, Driver, Observer, Outcome, Timer, TurnEvent};

/// Print each piece of answer text when it arrives.
struct PrintText;

impl Observer for PrintText {
    fn event(&mut self, event: &TurnEvent<'_>) {
        if let TurnEvent::Model(ai::Event::TextDelta(delta)) = event {
            print!("{}", delta.text);
            std::io::stdout().flush().expect("Couldn't flush");
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
    let target = ai::catalog::resolve("minimax/MiniMax-M3", ai::route::Credential::ApiKey(key.into()))?;
    let http = HttpTransport::new(HttpOptions::new("engine-example"))?;
    let mut driver = Driver::new(&http, &target, &TokioTimer);
    let mut conversation = Conversation::new();
    let mut observer = PrintText;

    print!("You> ");
    std::io::stdout().flush()?;
    for line in std::io::stdin().lock().lines() {
        print!("AI> ");
        match driver
            .run(
                &mut conversation,
                vec![Block::user_text(line?)],
                &mut observer,
                &mut Vec::new(),
            )
            .await
        {
            Outcome::Completed { .. } | Outcome::Stopped => println!(),
            Outcome::Failed(error) => eprintln!("{error}"),
        }
        print!("You> ");
        std::io::stdout().flush()?;
    }
    Ok(())
}
