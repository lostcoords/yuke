//! Stream chat replies while they arrive, and keep each finished one in the context.
#![expect(clippy::print_stdout, clippy::print_stderr, reason = "an example prints the chat")]

use std::io::{BufRead, Write};

use yuke_ai::{Block, Effort, Encoder, Event, HttpOptions, HttpTransport, Options, Reply, Request, Settings};

#[tokio::main(flavor = "current_thread")]
async fn main() -> Result<(), Box<dyn std::error::Error>> {
    let key = std::env::var("OPENAI_API_KEY")?;
    let target = yuke_ai::catalog::resolve("openai/gpt-6-astra", yuke_ai::route::Credential::ApiKey(key.into()))?;
    let http = HttpTransport::new(HttpOptions::new("ai-example"))?;
    // The encoder keeps the encoding of each request, so the next turn writes only what changed.
    let mut encoder = Encoder::new();
    let mut context: Vec<Block> = Vec::new();
    let settings = Settings::new().max_output_tokens(4096).effort(Effort::Low);

    println!("Type /quit to exit.");
    let mut lines = std::io::stdin().lock().lines();
    loop {
        print!("You> ");
        std::io::stdout().flush()?;
        let Some(line) = lines.next().transpose()? else { break };
        let prompt = line.trim();
        if prompt == "/quit" {
            break;
        }
        if prompt.is_empty() {
            continue;
        }
        context.push(Block::user_text(prompt));

        let request = Request::new(&context).settings(&settings);
        let mut reply = Reply::open(&http, &encoder.encode(&target, request)?, Options::default()).await;
        print!("AI> ");
        while let Some(Ok(event)) = reply.next().await {
            if let Event::TextDelta(delta) | Event::RefusalDelta(delta) = event {
                print!("{}", delta.text);
                std::io::stdout().flush()?;
            }
        }
        println!();

        match reply.finish().await {
            Ok(response) => context.extend(response.completion.into_blocks()),
            // This chat drops a failed reply. Another application could keep `error.partial` as text.
            Err(error) => eprintln!("{error}"),
        }
    }
    Ok(())
}
