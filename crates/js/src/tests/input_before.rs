//! These tests cover the `input.before` hook: its event, its chain, and each answer.

use std::time::Duration;

use tokio::sync::mpsc;
use yuke_agent::{InputDecision, InputHook};
use yuke_ai::{Blob, Block, Media};
use yuke_engine::CancellationToken;
use yuke_protocol::{Input, InputId, InputKind, InputSource, NoticeLevel, PendingInput};

use super::prompt::opened_with_host;
use super::{evaluate, next_notice};
use crate::{Report, ScriptSession};

/// An input of the user with the text `text`.
fn typed(text: &str) -> PendingInput {
    PendingInput {
        id: InputId(1),
        input: Input::new(InputSource::User, InputKind::Message, vec![Block::user_text(text)]).unwrap(),
    }
}

/// The decision of the `input.before` hooks of `session` for `input`.
async fn decide(session: &ScriptSession, input: &PendingInput) -> InputDecision {
    let hooks = session.hooks(CancellationToken::new());
    tokio::time::timeout(Duration::from_secs(5), hooks.before_input(input))
        .await
        .unwrap()
        .unwrap()
}

/// The next notice of `reports`, as its source, level, and message.
async fn notice(reports: &mut mpsc::UnboundedReceiver<Report>) -> (String, NoticeLevel, String) {
    let notice = next_notice(reports).await;
    (notice.source, notice.level, notice.message)
}

#[tokio::test]
async fn an_input_without_an_answer_stays_as_it_is() {
    let (_runtime, session, _host, _reports) = opened_with_host(
        "an_input_without_an_answer_stays_as_it_is",
        &[(
            "quiet",
            "export function session(s) { s.hook('input.before', () => undefined); }",
        )],
    )
    .await;

    assert_eq!(decide(&session, &typed("hi")).await, InputDecision::Keep);
}

#[tokio::test]
async fn a_replace_feeds_the_next_handler_and_the_model_reads_the_last_blocks() {
    let (runtime, session, _host, _reports) = opened_with_host(
        "a_replace_feeds_the_next_handler_and_the_model_reads_the_last_blocks",
        &[
            (
                "first",
                "export function session(s) {
                   s.hook('input.before', ({ source, kind, blocks }) => {
                     globalThis.first = JSON.stringify({ source, kind, blocks });
                     return { replace: { blocks: [{ user_text: 'expanded' }] } };
                   });
                 }",
            ),
            (
                "second",
                "export function session(s) {
                   s.hook('input.before', ({ blocks }) => { globalThis.second = JSON.stringify(blocks); });
                 }",
            ),
        ],
    )
    .await;

    let decision = decide(&session, &typed("/skill:pdf")).await;

    assert_eq!(decision, InputDecision::Replace(vec![Block::user_text("expanded")]));
    assert_eq!(
        evaluate::<Vec<String>>(&runtime, "return [globalThis.first, globalThis.second];")
            .await
            .unwrap(),
        [
            r#"{"source":{"kind":"user"},"kind":"message","blocks":[{"user_text":"/skill:pdf"}]}"#,
            r#"[{"user_text":"expanded"}]"#,
        ]
    );
}

#[tokio::test]
async fn a_block_removes_the_input_with_a_notice_and_later_handlers_do_not_run() {
    let (runtime, session, _host, mut reports) = opened_with_host(
        "a_block_removes_the_input_with_a_notice_and_later_handlers_do_not_run",
        &[
            (
                "guard",
                "export function session(s) { s.hook('input.before', () => ({ block: 'it names a secret' })); }",
            ),
            (
                "later",
                "export function session(s) { s.hook('input.before', () => { globalThis.later = true; }); }",
            ),
        ],
    )
    .await;

    let decision = decide(&session, &typed("my key is 123")).await;

    assert_eq!(decision, InputDecision::Remove);
    assert_eq!(
        notice(&mut reports).await,
        (
            "guard".to_owned(),
            NoticeLevel::Warn,
            "the plugin blocked the input: it names a secret".to_owned()
        )
    );
    assert!(
        !evaluate::<bool>(&runtime, "return globalThis.later === true;")
            .await
            .unwrap()
    );
}

#[tokio::test]
async fn handled_removes_the_input_with_no_notice() {
    let (runtime, session, _host, mut reports) = opened_with_host(
        "handled_removes_the_input_with_no_notice",
        &[(
            "commands",
            "export function session(s) {
               s.hook('input.before', () => ({ handled: true }));
               s.notify('info', 'ready');
             }",
        )],
    )
    .await;

    let decision = decide(&session, &typed("/compact")).await;
    evaluate::<()>(&runtime, "return;").await.unwrap();

    assert_eq!(decision, InputDecision::Remove);
    assert_eq!(notice(&mut reports).await.2, "ready");
    assert!(reports.try_recv().is_err(), "a handled input sends no notice");
}

#[tokio::test]
async fn a_failed_handler_removes_the_input_and_the_notice_names_the_plugin() {
    let (_runtime, session, _host, mut reports) = opened_with_host(
        "a_failed_handler_removes_the_input_and_the_notice_names_the_plugin",
        &[(
            "broken",
            "export function session(s) { s.hook('input.before', () => { throw new Error('boom'); }); }",
        )],
    )
    .await;

    let thrown = decide(&session, &typed("hi")).await;
    let (_, level, message) = notice(&mut reports).await;

    assert_eq!(thrown, InputDecision::Remove);
    assert_eq!(level, NoticeLevel::Error);
    assert_eq!(message, "input.before of plugin broken failed: Error: boom");
}

#[tokio::test]
async fn an_empty_replace_removes_the_input() {
    let (_runtime, session, _host, mut reports) = opened_with_host(
        "an_empty_replace_removes_the_input",
        &[(
            "wrong",
            "export function session(s) { s.hook('input.before', () => ({ replace: { blocks: [] } })); }",
        )],
    )
    .await;

    let decision = decide(&session, &typed("hi")).await;

    assert_eq!(decision, InputDecision::Remove);
    assert!(
        notice(&mut reports)
            .await
            .2
            .ends_with("the blocks of the replace are not a list with a block"),
        "the notice names the shape"
    );
}

#[tokio::test]
async fn a_replace_keeps_a_media_block_and_stores_a_new_media_item() {
    let (runtime, session, host, _reports) = opened_with_host(
        "a_replace_keeps_a_media_block_and_stores_a_new_media_item",
        &[(
            "media",
            "export function session(s) {
               s.hook('input.before', (event) => ({
                 replace: { blocks: [...event.blocks, { mimeType: 'image/png', bytes: new Uint8Array([1, 2, 3]) }] },
               }));
               // A later handler sees the bytes of the new item.
               s.hook('input.before', (event) => { globalThis.size = event.blocks[1].bytes.length; });
             }",
        )],
    )
    .await;
    let held = Media::new(
        Blob {
            digest: [9; 32],
            len: 4,
        },
        "image/jpeg",
    );
    let input = PendingInput {
        id: InputId(1),
        input: Input::new(InputSource::User, InputKind::Message, vec![Block::Media(held.clone())]).unwrap(),
    };

    let decision = decide(&session, &input).await;

    let InputDecision::Replace(blocks) = decision else {
        panic!("{decision:?}")
    };
    assert_eq!(blocks.len(), 2);
    assert_eq!(blocks[0], Block::Media(held));
    assert!(matches!(&blocks[1], Block::Media(media) if media.mime == "image/png" && media.blob.len == 3));
    assert_eq!(*host.media.lock().unwrap(), [vec![1, 2, 3]]);
    assert_eq!(evaluate::<u32>(&runtime, "return globalThis.size;").await.unwrap(), 3);
}

#[tokio::test]
async fn a_notification_shows_its_plugin_source_and_its_kind() {
    let (runtime, session, _host, _reports) = opened_with_host(
        "a_notification_shows_its_plugin_source_and_its_kind",
        &[(
            "watch",
            "export function session(s) {
               s.hook('input.before', ({ source, kind }) => { globalThis.seen = `${source.kind} ${source.name} ${kind}`; });
             }",
        )],
    )
    .await;
    let input = PendingInput {
        id: InputId(1),
        input: Input::notification("host:jobs", "job 1 ended", "the job ended"),
    };

    decide(&session, &input).await;

    assert_eq!(
        evaluate::<String>(&runtime, "return globalThis.seen;").await.unwrap(),
        "plugin host:jobs notification"
    );
}
