//! These tests cover the `round.before` hook: its event, the chain of its answers, its plan, its failures, and its
//! cancel.

use std::time::Duration;

use yuke_ai::{Blob, Block, Media, Origin, Reasoning, ReasoningReplay, ReplayKind, Settings, ToolCall, ToolResult};
use yuke_engine::{CancellationToken, Hooks, RoundStart};

use super::opened;
use super::windowed;
use super::{evaluate, wait_until};
use crate::native::ai::{block_tokens, context_tokens};

/// A context of 4 blocks: the input, a call and its result, and a text.
fn context() -> Vec<Block> {
    vec![
        Block::user_text("one"),
        Block::ToolCall(ToolCall {
            call_id: "c1".to_owned(),
            name: "read".to_owned(),
            arguments: "{}".to_owned(),
        }),
        Block::ToolResult(ToolResult::success("c1", "done")),
        Block::assistant_text("two"),
    ]
}

#[test]
fn an_estimate_charges_each_media_item_and_the_larger_part_of_reasoning() {
    let media = Media::new(
        Blob {
            digest: [0; 32],
            len: 3,
        },
        "image/png",
    );
    let mut result = ToolResult::success("c1", "abcd");
    result.media = vec![media.clone(), media.clone()];
    let reasoning = |text: &str, state: &str| {
        Block::Reasoning(Reasoning {
            text: text.to_owned(),
            replay: Some(ReasoningReplay {
                origin: Origin {
                    model: "m".to_owned(),
                    base_url: "https://example.test".to_owned(),
                },
                kind: ReplayKind::AnthropicSignature,
                data: state.to_owned(),
            }),
        })
    };

    assert_eq!(block_tokens(&Block::Media(media)), 1600);
    assert_eq!(block_tokens(&Block::ToolResult(result)), 1 + 2 * 1600);
    assert_eq!(block_tokens(&reasoning("12345678", &"s".repeat(40))), 10);
    assert_eq!(block_tokens(&reasoning(&"t".repeat(40), "")), 10);
}

#[test]
fn a_count_adds_the_whole_newest_answer_and_the_blocks_after_it() {
    let call = Block::ToolCall(ToolCall {
        call_id: "c1".to_owned(),
        name: "read".to_owned(),
        arguments: "{}".to_owned(),
    });
    // The answer is the text and the call. The result and the input come after it.
    let context = [
        Block::user_text("aaaaaaaa"),
        Block::assistant_text("bbbb"),
        call,
        Block::ToolResult(ToolResult::success("c1", "cccc")),
        Block::user_text("dddd"),
    ];

    assert_eq!(context_tokens(&context, Some(100)), 100 + 1 + 2 + 1 + 1);
    assert_eq!(context_tokens(&context, None), 2 + 1 + 2 + 1 + 1);
    assert_eq!(context_tokens(&context[..1], Some(100)), 100 + 2);
}

#[tokio::test]
async fn a_cancel_aborts_the_signal_and_the_hook_keeps_the_round_at_once() {
    let (runtime, session, _reports) = opened(
        "a_cancel_aborts_the_signal_and_the_hook_keeps_the_round_at_once",
        &[(
            "slow",
            "export function session(s) {
               s.hook('round.before', ({ signal }) => {
                 globalThis.started = true;
                 signal.addEventListener('abort', () => { globalThis.aborted = signal.reason.name; });
                 return new Promise(() => {});
               });
             }",
        )],
    )
    .await;
    let token = CancellationToken::new();
    let hooks = session.hooks(token.clone());
    let context = context();
    let settings = Settings::new();
    let round = RoundStart {
        context: &context,
        model: &windowed(None),
        settings: &settings,
        system: "",
        tools: &[],
        input_tokens: None,
    };

    let cancel = async {
        wait_until(&runtime, "return globalThis.started === true;").await;
        token.cancel();
    };
    let (planned, ()) = tokio::join!(
        tokio::time::timeout(Duration::from_secs(5), hooks.before_round(&round)),
        cancel
    );

    let planned = planned.unwrap().unwrap();
    assert!(planned.replace.is_none() && planned.model.is_none() && planned.settings.is_none());
    let aborted = evaluate::<String>(&runtime, "return globalThis.aborted ?? 'none';")
        .await
        .unwrap();
    assert_eq!(aborted, "AbortError");
}
