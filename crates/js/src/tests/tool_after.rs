//! These tests cover the `tool.after` hook: its chain, its answers, its media, its failures, and its cancel.

use std::time::Duration;

use yuke_ai::{Blob, Media, ToolCall, ToolDefinition, ToolResult};
use yuke_engine::{CancellationToken, Hooks};

use super::opened;
use super::{evaluate, wait_until};
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

// An answer replaces only its own fields, so the media and the loaded tools of the result stay.
#[tokio::test]
async fn an_answer_keeps_the_media_and_the_loaded_tools_of_the_result() {
    let (_runtime, session, _reports) = opened(
        "an_answer_keeps_the_media_and_the_loaded_tools_of_the_result",
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
        wait_until(&runtime, "return globalThis.started === true;").await;
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
        wait_until(&runtime, "return typeof globalThis.release === 'function';").await;
        session.close().await.unwrap();
        evaluate::<()>(&runtime, "globalThis.release();").await.unwrap();
    };

    let (changed, ()) = tokio::join!(changed, close);

    assert_eq!(changed, None);
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
