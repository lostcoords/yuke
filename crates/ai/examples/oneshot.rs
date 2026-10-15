//! Ask a question and print the model's answer.
#![expect(clippy::print_stdout, reason = "an example prints its answer")]

use yuke_ai::{Block, Effort, HttpOptions, HttpTransport, Options, Request, Settings};

#[tokio::main(flavor = "current_thread")]
async fn main() -> Result<(), Box<dyn std::error::Error>> {
    let key = std::env::var("OPENAI_API_KEY")?;
    let target = yuke_ai::catalog::resolve("openai/gpt-6-astra")?;
    let credential = yuke_ai::route::Credential::ApiKey(key.into());
    let http = HttpTransport::new(HttpOptions::new("ai-example"))?;

    let blocks = [Block::user_text("Explain Rust in one sentence.")];
    let settings = Settings::new().max_output_tokens(4096).effort(Effort::Low);
    let request = Request::new(&blocks).settings(&settings);
    let response = yuke_ai::generate(&http, &target, &credential, request, Options::default()).await?;
    println!("{}", response.completion.text());
    Ok(())
}
