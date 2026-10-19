//! These tests cover the `tool.after` hook: its chain, its patches, its media, its failures, and its cancel.

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
async fn patch(session: &ScriptSession) -> Option<ToolResult> {
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
async fn the_result_stays_when_no_handler_patches_it() {
    let (_runtime, session, _reports) = opened(
        "the_result_stays_when_no_handler_patches_it",
        &[(
            "quiet",
            "export function session(s) { s.hook('tool.after', () => undefined); }",
        )],
    )
    .await;

    assert_eq!(patch(&session).await, None);
}

// A patch replaces only its own fields, so the media and the loaded tools of the result stay.
#[tokio::test]
async fn each_handler_gets_the_call_and_the_result_after_the_patches_before_it() {
    let (_runtime, session, _reports) = opened(
        "each_handler_gets_the_call_and_the_result_after_the_patches_before_it",
        &[
            (
                "redact",
                "export function session(s) {
                   s.hook('tool.after', (call, result) => ({
                     text: `${call.id} ${call.name} ${call.arguments.path}: ${result.text.replace('hunter2', '***')}`,
                   }));
                 }",
            ),
            (
                "flag",
                "export function session(s) {
                   s.hook('tool.after', (call, result) => ({ text: `${result.text} (${result.isError})`, isError: true }));
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
    assert_eq!(patch(&session).await, Some(expected));
}

#[tokio::test]
async fn a_patch_keeps_reorders_removes_and_adds_media() {
    // The patch adds this source of the plugin as a file.
    let source = "export function session(s) {
               s.hook('tool.after', (call, result) => ({
                 text: result.media.map((item) => `${item.mimeType} ${item.size}`).join(', '),
                 media: [
                   result.media[1],
                   { mimeType: 'image/gif', bytes: new Uint8Array([1, 2]) },
                   { mimeType: 'text/plain', path: 'pics/index.ts' },
                 ],
               }));
             }";
    let (_runtime, session, _reports) =
        opened("a_patch_keeps_reorders_removes_and_adds_media", &[("pics", source)]).await;

    let patched = patch(&session).await.unwrap();

    assert_eq!(patched.content, "image/png 3, image/jpeg 5");
    let shapes: Vec<_> = patched
        .media
        .iter()
        .map(|item| (item.mime.as_str(), item.blob.digest[0], item.blob.len))
        .collect();
    // The test host stores each new item with the digest 7.
    assert_eq!(
        shapes,
        [
            ("image/jpeg", 2, 5),
            ("image/gif", 7, 2),
            ("text/plain", 7, source.len())
        ]
    );
}

// A kept item crosses as a number, so a field of `Object.prototype` cannot make a new item look kept.
#[tokio::test]
async fn a_new_media_item_stays_new_when_a_plugin_adds_kept_to_the_object_prototype() {
    let (_runtime, session, _reports) = opened(
        "a_new_media_item_stays_new_when_a_plugin_adds_kept_to_the_object_prototype",
        &[(
            "polluter",
            "export function session(s) {
               s.hook('tool.after', () => {
                 Object.prototype.kept = 0;
                 return { media: [{ mimeType: 'image/gif', bytes: new Uint8Array([1, 2]) }] };
               });
             }",
        )],
    )
    .await;

    let patched = patch(&session).await.unwrap();

    let shapes: Vec<_> = patched
        .media
        .iter()
        .map(|item| (item.mime.as_str(), item.blob.digest[0], item.blob.len))
        .collect();
    assert_eq!(shapes, [("image/gif", 7, 2)]);
}

// The engine asks for the calls of a parallel group together, so the runs of two calls overlap.
#[tokio::test]
async fn each_of_two_overlapping_calls_gets_its_own_patch() {
    let (_runtime, session, _reports) = opened(
        "each_of_two_overlapping_calls_gets_its_own_patch",
        &[(
            "slow",
            "export function session(s) {
               s.hook('tool.after', async (call, result) => {
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
        ("return { text: 1 };", "TypeError: the patch text is not a string"),
        (
            "return { isError: 'yes' };",
            "TypeError: the patch isError is not a boolean",
        ),
        (
            "return { txt: 'x' };",
            "TypeError: the patch has the unknown field 'txt'",
        ),
        ("return 'x';", "TypeError: the patch is not an object"),
        ("return null;", "TypeError: the patch is not an object"),
        (
            "return { media: [{ ...result.media[0] }] };",
            "TypeError: the patch media[0] has the unknown field 'size'",
        ),
    ];
    for (index, (body, error)) in cases.into_iter().enumerate() {
        let (_runtime, session, _reports) = opened(
            &format!("a_throw_or_an_answer_of_another_shape_gives_an_error_result_that_names_the_plugin_{index}"),
            &[(
                "check",
                &format!("export function session(s) {{ s.hook('tool.after', (call, result) => {{ {body} }}); }}"),
            )],
        )
        .await;

        let expected = format!("the tool.after hook of plugin check failed: {error}");
        assert_eq!(patch(&session).await, Some(failed(&expected)), "{body}");
    }
}

// A handler that changes the result in place would skip the checks of a patch.
#[tokio::test]
async fn a_change_of_the_result_or_its_media_throws_and_gives_an_error_result() {
    for (index, body) in ["result.text = 'x';", "result.media.pop();", "result.media[0].size = 1;"]
        .into_iter()
        .enumerate()
    {
        let (_runtime, session, _reports) = opened(
            &format!("a_change_of_the_result_or_its_media_throws_and_gives_an_error_result_{index}"),
            &[(
                "editor",
                &format!("export function session(s) {{ s.hook('tool.after', (call, result) => {{ {body} }}); }}"),
            )],
        )
        .await;

        let patched = patch(&session).await.unwrap();

        assert!(
            patched
                .content
                .starts_with("the tool.after hook of plugin editor failed: TypeError: "),
            "{body}: {}",
            patched.content
        );
        assert!(patched.is_error && patched.media.is_empty(), "{body}");
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

    let patched = patch(&session).await.unwrap();

    assert!(
        patched
            .content
            .starts_with("the tool.after hooks failed: missing.png: "),
        "{}",
        patched.content
    );
    assert!(patched.is_error && patched.media.is_empty());
}

#[tokio::test]
async fn a_cancel_aborts_the_signal_and_keeps_the_original_result() {
    let (runtime, session, _reports) = opened(
        "a_cancel_aborts_the_signal_and_keeps_the_original_result",
        &[(
            "slow",
            "export function session(s) {
               s.hook('tool.after', (call) => new Promise((resolve) => {
                 call.signal.addEventListener('abort', () => {
                   globalThis.aborted = call.signal.reason.name;
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

    let (patched, ()) = tokio::time::timeout(Duration::from_secs(5), async {
        tokio::join!(hooks.after_tool(&call, &result), cancel)
    })
    .await
    .unwrap();
    let aborted = evaluate::<Option<String>>(&runtime, "return globalThis.aborted;")
        .await
        .unwrap();

    assert_eq!(patched, None);
    assert_eq!(aborted.as_deref(), Some("AbortError"));
}

// A close during a handler ends the turn, so a late patch of the closed session does not count.
#[tokio::test]
async fn a_patch_that_comes_after_the_close_of_the_session_does_not_count() {
    let (runtime, session, _reports) = opened(
        "a_patch_that_comes_after_the_close_of_the_session_does_not_count",
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
    let patched = patch(&session);
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

    let (patched, ()) = tokio::join!(patched, close);

    assert_eq!(patched, None);
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

    let patched = patch(&session).await;
    let ran = evaluate::<Vec<String>>(&runtime, "return globalThis.ran;")
        .await
        .unwrap();

    assert_eq!(patched, None);
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
