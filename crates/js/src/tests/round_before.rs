//! These tests cover the `round.before` hook: its event, the chain of its answers, its plan, its failures, and its
//! cancel.

use std::time::Duration;

use yuke_ai::{Blob, Block, Media, Origin, Reasoning, ReasoningReplay, ReplayKind, Settings, ToolCall, ToolResult};
use yuke_engine::{CancellationToken, Hooks, RoundPlan, RoundStart};

use super::prompt::opened;
use super::windowed;
use super::{evaluate, wait_until};
use crate::ScriptSession;
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

/// The plan of the `round.before` hooks of `session` for a round of [`context`], with the temperature 0.5.
async fn plan(session: &ScriptSession) -> Result<RoundPlan, String> {
    let context = context();
    let settings = Settings::new().temperature(0.5);
    let round = RoundStart {
        context: &context,
        model: &windowed(Some(200_000)),
        settings: &settings,
        system: "",
        tools: &[],
        input_tokens: Some(1200),
    };
    let hooks = session.hooks(CancellationToken::new());
    tokio::time::timeout(Duration::from_secs(5), hooks.before_round(&round))
        .await
        .unwrap()
        .map_err(|error| error.to_string())
}

#[tokio::test]
async fn a_handler_gets_the_window_the_tokens_and_the_context_and_no_answer_keeps_the_round() {
    let (runtime, session, _reports) = opened(
        "a_handler_gets_the_window_the_tokens_and_the_context_and_no_answer_keeps_the_round",
        &[(
            "watch",
            "export function session(s) {
               s.hook('round.before', ({ window, inputTokens, contextTokens, blocks, blockTokens, context }) => {
                 const first = context();
                 first[0].user_text = 'changed';
                 const tokens = blockTokens();
                 globalThis.seen = JSON.stringify({ window, inputTokens, contextTokens, blocks, tokens, context: context() });
               });
             }",
        )],
    )
    .await;

    let plan = plan(&session).await.unwrap();

    assert!(plan.replace.is_none() && plan.model.is_none() && plan.settings.is_none());
    let seen = evaluate::<String>(&runtime, "return globalThis.seen;").await.unwrap();
    // Each call of `context` gives a new copy, so the change of the first copy is not in the second. The count holds
    // every block before the newest answer, so only the text `two` adds to it.
    assert_eq!(
        seen,
        r#"{"window":200000,"inputTokens":1200,"contextTokens":1201,"blocks":4,"tokens":[1,2,1,1],"context":[{"user_text":"one"},{"tool_call":{"callId":"c1","name":"read","arguments":"{}"}},{"tool_result":{"callId":"c1","content":"done","isError":false}},{"assistant_text":"two"}]}"#
    );
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
async fn a_later_handler_gets_the_replaced_context_and_the_plan_combines_the_replacements() {
    let (runtime, session, _reports) = opened(
        "a_later_handler_gets_the_replaced_context_and_the_plan_combines_the_replacements",
        &[
            (
                "first",
                "export function session(s) {
                   s.hook('round.before', () => ({ replace: { head: [{ user_text: 'summary' }], keep: 1 } }));
                 }",
            ),
            (
                "second",
                "export function session(s) {
                   s.hook('round.before', ({ contextTokens, blocks, blockTokens, context }) => {
                     globalThis.seen = JSON.stringify({ contextTokens, blocks, tokens: blockTokens(), context: context() });
                     return { replace: { head: [{ user_text: 'newer' }], keep: 2 } };
                   });
                 }",
            ),
        ],
    )
    .await;

    let plan = plan(&session).await.unwrap();

    let seen = evaluate::<String>(&runtime, "return globalThis.seen;").await.unwrap();
    // The count of the newest answer describes the context before the replacement, so each block counts.
    assert_eq!(
        seen,
        r#"{"contextTokens":3,"blocks":2,"tokens":[2,1],"context":[{"user_text":"summary"},{"assistant_text":"two"}]}"#
    );
    // The second keeps the head of the first and the text, so the plan keeps 1 block of the context before the round.
    let replace = plan.replace.unwrap();
    assert_eq!(*replace.head, [Block::user_text("newer"), Block::user_text("summary")]);
    assert_eq!(replace.keep, 1);
}

#[tokio::test]
async fn a_keep_past_the_context_keeps_all_of_it_and_an_empty_head_keeps_only_the_kept_blocks() {
    let cases = [
        // A keep past the length keeps the whole context after the first head.
        (
            ("[{ user_text: 'summary' }]", 1),
            ("[{ user_text: 'newer' }]", 9),
            vec![Block::user_text("newer"), Block::user_text("summary")],
            1,
        ),
        // An empty head after a replacement drops the head before it.
        (("[{ user_text: 'summary' }]", 1), ("[]", 1), Vec::new(), 1),
        // A later smaller keep cuts into the blocks that the first one kept.
        (
            ("[]", 3),
            ("[{ user_text: 'newer' }]", 1),
            vec![Block::user_text("newer")],
            1,
        ),
    ];
    for (index, ((first_head, first_keep), (second_head, second_keep), head, keep)) in cases.into_iter().enumerate() {
        let plugin = |head: &str, keep: usize| {
            format!(
                "export function session(s) {{
                   s.hook('round.before', () => ({{ replace: {{ head: {head}, keep: {keep} }} }}));
                 }}"
            )
        };
        let (_runtime, session, _reports) = opened(
            &format!("a_keep_past_the_context_keeps_all_of_it_and_an_empty_head_keeps_only_the_kept_blocks_{index}"),
            &[
                ("first", &plugin(first_head, first_keep)),
                ("second", &plugin(second_head, second_keep)),
            ],
        )
        .await;

        let replace = plan(&session).await.unwrap().replace.unwrap();

        assert_eq!((&*replace.head, replace.keep), (head.as_slice(), keep), "case {index}");
    }
}

#[tokio::test]
async fn a_later_model_or_setting_wins_and_the_settings_change_the_settings_of_the_round() {
    let (_runtime, session, _reports) = opened(
        "a_later_model_or_setting_wins_and_the_settings_change_the_settings_of_the_round",
        &[
            (
                "first",
                "export function session(s) {
                   s.hook('round.before', () => ({
                     model: { provider: 'test', model: 'unknown-model' },
                     settings: { temperature: 0.1, topP: 0.9 },
                   }));
                 }",
            ),
            (
                "second",
                "export function session(s) {
                   s.hook('round.before', () => ({
                     model: { provider: 'test', model: 'other-model' },
                     settings: { temperature: 0.2, reasoning: { effort: 'high' } },
                   }));
                 }",
            ),
        ],
    )
    .await;

    let plan = plan(&session).await.unwrap();

    assert_eq!(plan.model.unwrap().target.model, "other-model");
    let settings = plan.settings.unwrap();
    assert_eq!((settings.temperature, settings.top_p), (Some(0.2), Some(0.9)));
    assert_eq!(settings.reasoning.effort, Some(yuke_ai::Effort::High));
    assert!(plan.replace.is_none());
}

#[tokio::test]
async fn a_bad_answer_fails_the_turn_and_names_the_plugin() {
    let cases = [
        (
            "return { replace: { head: [{ user_text: 'summary' }], keep: 2 } };",
            "the replacement contains the result of call c1 without its call",
        ),
        (
            "return { model: { provider: 'test', model: 'missing' } };",
            "no model test/missing",
        ),
        (
            "return { replace: { head: [{ text: 'x' }], keep: 0 } };",
            "the head is not a list of blocks: ",
        ),
        (
            "return { settings: { temperature: 'hot' } };",
            "the settings are not valid: ",
        ),
        (
            "return { settings: { maxOutputToken: 100 } };",
            "the settings have the unknown field 'maxOutputToken'",
        ),
        (
            "return { settings: { temperature: NaN } };",
            "TypeError: the answer holds a number that is not finite",
        ),
        (
            "return { replace: { head: [], keep: -1 } };",
            "TypeError: the keep of the replace is not a whole number",
        ),
        (
            "return { replace: { head: [], keep: 0, tail: 1 } };",
            "TypeError: the replace of the answer has the unknown field 'tail'",
        ),
        (
            "return { model: 'other' };",
            "TypeError: the model of the answer is not an object",
        ),
        ("throw new Error('no plan');", "Error: no plan"),
    ];
    for (index, (body, error)) in cases.into_iter().enumerate() {
        let (_runtime, session, _reports) = opened(
            &format!("a_bad_answer_fails_the_turn_and_names_the_plugin_{index}"),
            &[(
                "planner",
                &format!("export function session(s) {{ s.hook('round.before', () => {{ {body} }}); }}"),
            )],
        )
        .await;

        let failure = plan(&session).await.err().unwrap();

        let prefix = format!("round.before of plugin planner failed: {error}");
        assert!(failure.starts_with(&prefix), "{body}: {failure}");
    }
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
