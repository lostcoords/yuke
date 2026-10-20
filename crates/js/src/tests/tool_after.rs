//! These tests cover the `tool.after` hook: its chain, its answers, its media, its failures, and its cancel.

use std::time::Duration;

use yuke_ai::{Blob, Media, ToolCall, ToolDefinition, ToolResult};
use yuke_engine::{CancellationToken, Hooks};

use super::evaluate;
use super::prompt::opened;
use crate::ScriptSession;

fn call() -> ToolCall {
    ToolCall {
        call_id: "c1".to_owned(),
        name: "read".to_owned(),
        arguments: r#"{"path": "notes.md"}"#.to_owned(),
    }
}

/// A media item of `len` bytes with the media type `mime`. The digest tells the items apart.
fn media(mime: &str, digest: u8, len: usize) -> Media {
    Media::new(
        Blob {
            digest: [digest; 32],
            len,
        },
        mime,
    )
}

/// The result of [`call`]: a text, a png of 3 bytes, a jpeg of 5 bytes, and one loaded tool.
fn original() -> ToolResult {
    ToolResult {
        call_id: "c1".to_owned(),
        content: "secret: hunter2".to_owned(),
        is_error: false,
        media: vec![media("image/png", 1, 3), media("image/jpeg", 2, 5)],
        loaded: vec![ToolDefinition {
            name: "lint".to_owned(),
            description: "d".to_owned(),
            input_schema: "{}".to_owned(),
            defer_loading: true,
        }],
    }
}

/// The answer of the hooks of `session` for [`original`].
async fn after(session: &ScriptSession) -> Option<ToolResult> {
    let hooks = session.hooks(CancellationToken::new());
    tokio::time::timeout(Duration::from_secs(5), hooks.after_tool(&call(), &original()))
        .await
        .unwrap()
}

/// The error result that replaces [`original`] with `text`. It keeps the loaded tools.
fn failed(text: &str) -> ToolResult {
    ToolResult {
        content: text.to_owned(),
        is_error: true,
        media: Vec::new(),
        ..original()
    }
}

#[tokio::test]
async fn the_result_stays_when_no_handler_answers() {
    let (_runtime, session, _reports) = opened(
        "the_result_stays_when_no_handler_answers",
        &[(
            "quiet",
            "export function session(s) { s.hook('tool.after', () => undefined); }",
        )],
    )
    .await;

    assert_eq!(after(&session).await, None);
}

// An answer replaces only its own fields, so the media and the loaded tools of the result stay.
#[tokio::test]
async fn each_handler_gets_the_call_and_the_result_after_the_answers_before_it() {
    let (_runtime, session, _reports) = opened(
        "each_handler_gets_the_call_and_the_result_after_the_answers_before_it",
        &[
            (
                "redact",
                "export function session(s) {
                   s.hook('tool.after', ({ call, result }) => ({
                     text: `${call.id} ${call.name} ${call.arguments.path}: ${result.text.replace('hunter2', '***')}`,
                   }));
                 }",
            ),
            (
                "flag",
                "export function session(s) {
                   s.hook('tool.after', ({ call, result }) => ({ text: `${result.text} (${result.isError})`, isError: true }));
                 }",
            ),
        ],
    )
    .await;

    let expected = ToolResult {
        content: "c1 read notes.md: secret: *** (false)".to_owned(),
        is_error: true,
        ..original()
    };
    assert_eq!(after(&session).await, Some(expected));
}

// An item keeps its original by its id, so the item itself, a copy, and its id alone each keep it.
#[tokio::test]
async fn an_answer_keeps_reorders_removes_and_adds_media() {
    // The answer adds this source of the plugin as a file.
    let source = "export function session(s) {
               s.hook('tool.after', ({ call, result }) => ({
                 text: result.media.map((item) => `${item.id} ${item.mimeType} ${item.size}`).join(', '),
                 media: [
                   result.media[1],
                   { ...result.media[0] },
                   { id: result.media[1].id },
                   { mimeType: 'image/gif', bytes: new Uint8Array([1, 2]) },
                   { mimeType: 'text/plain', path: 'pics/index.ts' },
                 ],
               }));
             }";
    let (_runtime, session, _reports) =
        opened("an_answer_keeps_reorders_removes_and_adds_media", &[("pics", source)]).await;

    let changed = after(&session).await.unwrap();

    assert_eq!(changed.content, "0 image/png 3, 1 image/jpeg 5");
    let shapes: Vec<_> = changed
        .media
        .iter()
        .map(|item| (item.mime.as_str(), item.blob.digest[0], item.blob.len))
        .collect();
    // The test host stores each new item with the digest 7.
    assert_eq!(
        shapes,
        [
            ("image/jpeg", 2, 5),
            ("image/png", 1, 3),
            ("image/jpeg", 2, 5),
            ("image/gif", 7, 2),
            ("text/plain", 7, source.len())
        ]
    );
}

// Two items can hold the same bytes, so each item has its own id.
#[tokio::test]
async fn an_answer_keeps_the_second_of_two_items_with_the_same_bytes() {
    let (_runtime, session, _reports) = opened(
        "an_answer_keeps_the_second_of_two_items_with_the_same_bytes",
        &[(
            "pick",
            "export function session(s) {
               s.hook('tool.after', ({ result }) => ({ media: [{ id: result.media[1].id }] }));
             }",
        )],
    )
    .await;
    let result = ToolResult {
        media: vec![media("image/png", 1, 3), media("image/webp", 1, 3)],
        ..original()
    };

    let hooks = session.hooks(CancellationToken::new());
    let changed = hooks.after_tool(&call(), &result).await.unwrap();

    assert_eq!(changed.media, [media("image/webp", 1, 3)]);
}

// The handlers of a run are fixed at its start, also for the plugins after the one that changes them.
#[tokio::test]
async fn a_change_of_the_handlers_during_a_run_changes_only_the_next_run() {
    let (_runtime, session, _reports) = opened(
        "a_change_of_the_handlers_during_a_run_changes_only_the_next_run",
        &[
            (
                "first",
                "export function session(s) { s.hook('tool.after', () => { globalThis.swap(); }); }",
            ),
            (
                "second",
                "export function session(s) {
                   let remove = s.hook('tool.after', ({ result }) => ({ text: `${result.text} old` }));
                   globalThis.swap = () => {
                     remove();
                     remove = s.hook('tool.after', ({ result }) => ({ text: `${result.text} new` }));
                   };
                 }",
            ),
        ],
    )
    .await;

    let first = after(&session).await.unwrap();
    let second = after(&session).await.unwrap();

    assert_eq!(first.content, "secret: hunter2 old");
    assert_eq!(second.content, "secret: hunter2 new");
}

// The engine asks for the calls of a parallel group together, so the runs of two calls overlap.
#[tokio::test]
async fn each_of_two_overlapping_calls_gets_its_own_answer() {
    let (_runtime, session, _reports) = opened(
        "each_of_two_overlapping_calls_gets_its_own_answer",
        &[(
            "slow",
            "export function session(s) {
               s.hook('tool.after', async ({ call, result }) => {
                 await new Promise((resolve) => setTimeout(resolve, call.id === 'first' ? 30 : 0));
                 return { text: `${call.id}: ${result.text}` };
               });
             }",
        )],
    )
    .await;
    let hooks = session.hooks(CancellationToken::new());
    let calls = ["first", "second"].map(|id| ToolCall {
        call_id: id.to_owned(),
        ..call()
    });
    let results = ["first", "second"].map(|id| ToolResult {
        call_id: id.to_owned(),
        content: format!("text of {id}"),
        ..original()
    });

    let (first, second) = tokio::time::timeout(Duration::from_secs(5), async {
        tokio::join!(
            hooks.after_tool(&calls[0], &results[0]),
            hooks.after_tool(&calls[1], &results[1])
        )
    })
    .await
    .unwrap();

    assert_eq!(first.unwrap().content, "first: text of first");
    assert_eq!(second.unwrap().content, "second: text of second");
}

#[tokio::test]
async fn a_throw_or_an_answer_of_another_shape_gives_an_error_result_that_names_the_plugin() {
    let cases = [
        ("throw new Error('no redaction today');", "Error: no redaction today"),
        (
            "return { text: 1 };",
            "TypeError: the text of the answer is not a string",
        ),
        (
            "return { isError: 'yes' };",
            "TypeError: the isError of the answer is not a boolean",
        ),
        (
            "return { txt: 'x' };",
            "TypeError: the answer has the unknown field 'txt'",
        ),
        ("return 'x';", "TypeError: the answer is not an object"),
        ("return null;", "TypeError: the answer is not an object"),
        (
            "return { media: [{ id: '00' }] };",
            "TypeError: the answer media[0].id names no media item of the result",
        ),
        (
            "return { media: [result.media[0], { ...result.media[0], mimeType: 'image/gif' }] };",
            "TypeError: the answer media[1].mimeType differs from the kept item",
        ),
        (
            "return { media: [{ ...result.media[1], size: 1 }] };",
            "TypeError: the answer media[0].size differs from the kept item",
        ),
        (
            "return { media: [{ ...result.media[0], path: 'a.png' }] };",
            "TypeError: the answer media[0] has the unknown field 'path'",
        ),
    ];
    for (index, (body, error)) in cases.into_iter().enumerate() {
        let (_runtime, session, _reports) = opened(
            &format!("a_throw_or_an_answer_of_another_shape_gives_an_error_result_that_names_the_plugin_{index}"),
            &[(
                "check",
                &format!(
                    "export function session(s) {{ s.hook('tool.after', ({{ call, result }}) => {{ {body} }}); }}"
                ),
            )],
        )
        .await;

        let expected = format!("tool.after of plugin check failed: {error}");
        assert_eq!(after(&session).await, Some(failed(&expected)), "{body}");
    }
}

// A handler that changes the event or the result in place would skip the checks of an answer.
#[tokio::test]
async fn a_change_of_the_event_the_result_or_its_media_throws_and_gives_an_error_result() {
    for (index, body) in [
        "result.text = 'x';",
        "result.media.pop();",
        "result.media[0].size = 1;",
        "event.result = {};",
    ]
    .into_iter()
    .enumerate()
    {
        let (_runtime, session, _reports) = opened(
            &format!("a_change_of_the_event_the_result_or_its_media_throws_and_gives_an_error_result_{index}"),
            &[(
                "editor",
                &format!(
                    "export function session(s) {{ s.hook('tool.after', (event) => {{ const {{ result }} = event; {body} }}); }}"
                ),
            )],
        )
        .await;

        let changed = after(&session).await.unwrap();

        assert!(
            changed
                .content
                .starts_with("tool.after of plugin editor failed: TypeError: "),
            "{body}: {}",
            changed.content
        );
        assert!(changed.is_error && changed.media.is_empty(), "{body}");
    }
}

#[tokio::test]
async fn a_new_media_item_that_cannot_be_read_gives_an_error_result() {
    let (_runtime, session, _reports) = opened(
        "a_new_media_item_that_cannot_be_read_gives_an_error_result",
        &[(
            "pics",
            "export function session(s) {
               s.hook('tool.after', () => ({ media: [{ mimeType: 'image/png', path: 'missing.png' }] }));
             }",
        )],
    )
    .await;

    let changed = after(&session).await.unwrap();

    assert!(
        changed
            .content
            .starts_with("the tool.after hooks failed: missing.png: "),
        "{}",
        changed.content
    );
    assert!(changed.is_error && changed.media.is_empty());
}

#[tokio::test]
async fn a_cancel_aborts_the_signal_and_keeps_the_original_result() {
    let (runtime, session, _reports) = opened(
        "a_cancel_aborts_the_signal_and_keeps_the_original_result",
        &[(
            "slow",
            "export function session(s) {
               s.hook('tool.after', ({ signal }) => new Promise((resolve) => {
                 signal.addEventListener('abort', () => {
                   globalThis.aborted = signal.reason.name;
                   resolve({ text: 'too late' });
                 });
                 globalThis.started = true;
               }));
             }",
        )],
    )
    .await;
    let token = CancellationToken::new();
    let hooks = session.hooks(token.clone());
    let (call, result) = (call(), original());
    let cancel = async {
        while !evaluate::<bool>(&runtime, "return globalThis.started === true;")
            .await
            .unwrap()
        {
            tokio::time::sleep(Duration::from_millis(5)).await;
        }
        token.cancel();
    };

    let (changed, ()) = tokio::time::timeout(Duration::from_secs(5), async {
        tokio::join!(hooks.after_tool(&call, &result), cancel)
    })
    .await
    .unwrap();
    let aborted = evaluate::<Option<String>>(&runtime, "return globalThis.aborted;")
        .await
        .unwrap();

    assert_eq!(changed, None);
    assert_eq!(aborted.as_deref(), Some("AbortError"));
}

// A close during a handler ends the turn, so a late answer of the closed session does not count.
#[tokio::test]
async fn an_answer_that_comes_after_the_close_of_the_session_does_not_count() {
    let (runtime, session, _reports) = opened(
        "an_answer_that_comes_after_the_close_of_the_session_does_not_count",
        &[(
            "late",
            "export function session(s) {
               s.hook('tool.after', () => new Promise((resolve) => {
                 globalThis.release = () => resolve({ text: 'too late' });
               }));
             }",
        )],
    )
    .await;
    let changed = after(&session);
    let close = async {
        while !evaluate::<bool>(&runtime, "return typeof globalThis.release === 'function';")
            .await
            .unwrap()
        {
            tokio::time::sleep(Duration::from_millis(5)).await;
        }
        session.close().await.unwrap();
        evaluate::<()>(&runtime, "globalThis.release();").await.unwrap();
    };

    let (changed, ()) = tokio::join!(changed, close);

    assert_eq!(changed, None);
}

// A handler of a failed session never runs.
#[tokio::test]
async fn a_removed_handler_and_the_handler_of_a_failed_session_do_not_run() {
    let (runtime, session, _reports) = opened(
        "a_removed_handler_and_the_handler_of_a_failed_session_do_not_run",
        &[
            (
                "removed",
                "globalThis.ran = [];
                 export function session(s) { s.hook('tool.after', () => { globalThis.ran.push('removed'); })(); }",
            ),
            (
                "failed",
                "export async function session(s) {
                   s.hook('tool.after', () => { globalThis.ran.push('failed'); });
                   await null;
                   throw new Error('broken');
                 }",
            ),
        ],
    )
    .await;

    let changed = after(&session).await;
    let ran = evaluate::<Vec<String>>(&runtime, "return globalThis.ran;")
        .await
        .unwrap();

    assert_eq!(changed, None);
    assert_eq!(ran, Vec::<String>::new());
}

// A hook that cannot answer never shows the original result.
#[tokio::test]
async fn the_result_is_an_error_when_the_javascript_thread_has_ended() {
    let (runtime, session, _reports) = opened(
        "the_result_is_an_error_when_the_javascript_thread_has_ended",
        &[("quiet", "export function session(s) {}")],
    )
    .await;
    let hooks = session.hooks(CancellationToken::new());
    tokio::time::timeout(Duration::from_secs(5), runtime.shutdown())
        .await
        .unwrap()
        .unwrap();

    assert_eq!(
        hooks.after_tool(&call(), &original()).await,
        Some(failed("the tool.after hooks failed: the JavaScript thread has ended"))
    );
}
