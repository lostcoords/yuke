//! Call each method of the store once: create a session, add an input, save a commit, and read the session again.
//! A program usually gives the store to a `yuke_agent::Session`, which runs the turns and saves each commit.
#![expect(clippy::print_stdout, reason = "an example prints what the store saved")]

use yuke_agent::{Access, Store};
use yuke_engine::{Commit, Outcome, TurnEnd};
use yuke_protocol::{ModelReference, SessionSettings};
use yuke_store::SqliteStore;

#[tokio::main(flavor = "current_thread")]
async fn main() -> Result<(), Box<dyn std::error::Error>> {
    // Open the database in the folder, or create it.
    let folder = std::env::temp_dir().join("yuke-store-example");
    let store = SqliteStore::open(&folder).await?;
    println!("store: {}", folder.display());

    // Create a session. This process owns the session until `opened.lease` drops.
    let settings = SessionSettings {
        model: ModelReference {
            provider: "minimax".to_owned(),
            model: "MiniMax-M3".to_owned(),
        },
        settings: yuke_ai::Settings::new(),
        cwd: std::env::current_dir()?,
    };
    let opened = store.create_session(&settings).await?;
    let id = opened.id;

    // Any caller can add input. The input stays pending until a commit consumes it.
    let hello = [yuke_ai::Block::user_text("hello")];
    let input = store.accept_input(id, &hello).await?;
    println!("pending after accept_input: {}", store.pending(id).await?.len());

    // The owner saves each commit of a turn. This commit takes the input and ends the turn.
    let commit = Commit {
        replaced: None,
        blocks: std::borrow::Cow::Borrowed(&hello),
        answer: None,
        end: Some(TurnEnd::Outcome(Outcome::Stopped)),
    };
    let event_number = store.commit(id, &commit, &[input]).await?;
    println!("commit event: {}", event_number.0);
    println!("pending after commit: {}", store.pending(id).await?.len());
    drop(opened);

    // A read takes no lock. It gives the settings, the context, and whether a turn is open.
    let read = store.open(id, Access::Read).await?;
    println!("model: {}/{}", read.settings.model.provider, read.settings.model.model);
    println!("context: {:?}", read.context);
    println!("turn open: {}", read.turn_open);
    Ok(())
}
