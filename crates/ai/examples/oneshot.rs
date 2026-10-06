//! Ask a question and print the model's answer.
#![expect(clippy::print_stdout, reason = "an example prints its answer")]

use ai::{Block, Effort, HttpOptions, HttpTransport, Request};

#[tokio::main(flavor = "current_thread")]
async fn main() -> Result<(), Box<dyn std::error::Error>> {
    let key = std::env::var("OPENAI_API_KEY")?;
    let target = ai::catalog::resolve("openai/gpt-6-astra", ai::route::Credential::ApiKey(key.into()))?;
    let http = HttpTransport::new(HttpOptions::new("ai-example"))?;

    let blocks = [Block::user_text("Explain Rust in one sentence.")];
    let request = Request::new(&blocks).max_output_tokens(4096).effort(Effort::Low);
    let response = ai::generate(&http, &target, request).await?;
    println!("{}", response.completion.text());
    Ok(())
}
