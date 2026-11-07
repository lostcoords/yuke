//! Ask a model of a local OpenAI-compatible server through a target that the program writes, without the catalog.
//! `MODEL` names the model. `BASE_URL` overrides the default base URL of Ollama.
#![expect(clippy::print_stdout, reason = "an example prints its answer")]

use yuke_ai::route::{Credential, Route};
use yuke_ai::{Block, ChatWire, Options, Request, Settings, Target, Wire};

#[tokio::main(flavor = "current_thread")]
async fn main() -> Result<(), Box<dyn std::error::Error>> {
    let model = std::env::var("MODEL")?;
    let base_url = std::env::var("BASE_URL").unwrap_or_else(|_| "http://localhost:11434/v1".to_owned());
    // A route without a credential header takes `Credential::None`.
    let target = Target {
        model: model.into(),
        route: Route {
            base_url: base_url.into(),
            ..Route::default()
        },
        wire: Wire::OpenaiChat(ChatWire::default()),
        tool_search: false,
    };
    let http = yuke_http::Client::new(yuke_http::ClientOptions::new("ai-example"))?;

    let blocks = [Block::user_text("Explain Rust in one sentence.")];
    let settings = Settings::new().max_output_tokens(512);
    let request = Request::new(&blocks).settings(&settings);
    let response = yuke_ai::generate(&http, &target, &Credential::None, request, Options::default()).await?;
    println!("{}", response.completion.text());
    Ok(())
}
