use std::borrow::Cow;

use yuke_ai::{Block, Completion, Content, FinishReason, Partial, Reasoning, ToolCall, ToolResult, Usage};
use yuke_testing::origin;

use super::{Action, Answer, Commit, Outcome, Replaced, TurnEnd, TurnState};
use crate::model::RoundError;

/// Each block of `context` as one line.
fn lines(context: &[Block]) -> Vec<String> {
    context
        .iter()
        .map(|block| match block {
            Block::UserText(text) => format!("user {text}"),
            Block::AssistantText(text) => format!("assistant {text}"),
            Block::Reasoning(reasoning) => format!("reasoning {}", reasoning.text),
            Block::ToolCall(call) => format!("call {}", call.call_id),
            Block::ToolResult(result) if result.is_error => format!("error {} {}", result.call_id, result.content),
            Block::ToolResult(result) => format!("result {} {}", result.call_id, result.content),
            Block::Media(media) => format!("media {}", media.mime),
        })
        .collect()
}

/// The names of the calls that `action` asks to run.
fn called_names(action: Action<'_>) -> Vec<String> {
    match action {
        Action::CallTools(commit) => commit
            .blocks
            .iter()
            .filter_map(|block| match block {
                Block::ToolCall(call) => Some(call.name.clone()),
                _ => None,
            })
            .collect(),
        other => panic!("expected tool calls, got {other:?}"),
    }
}

fn answer(text: &str) -> Completion {
    Completion {
        content: vec![Content::Text(text.to_owned())],
        finish_reason: FinishReason::Stop,
        raw_finish_reason: "end_turn".to_owned(),
        usage: Usage::default(),
    }
}

/// An answer with two calls between text and reasoning blocks.
fn tool_answer(finish_reason: FinishReason) -> Completion {
    Completion {
        content: vec![
            Content::Text("Let me check.".to_owned()),
            Content::Reasoning(Reasoning {
                text: "Two files.".to_owned(),
                replay: None,
            }),
            Content::ToolCall(ToolCall {
                call_id: "c1".to_owned(),
                name: "read".to_owned(),
                arguments: "{}".to_owned(),
            }),
            Content::Text("And the other.".to_owned()),
            Content::ToolCall(ToolCall {
                call_id: "c2".to_owned(),
                name: "write".to_owned(),
                arguments: "{}".to_owned(),
            }),
        ],
        finish_reason,
        raw_finish_reason: finish_reason.as_str().to_owned(),
        usage: Usage::default(),
    }
}

#[test]
fn send_after_a_round_sends_another_request_without_input() {
    let mut context = Vec::new();
    let mut turn_state = TurnState::new(&mut context, None);
    let _ = turn_state.send(vec![Block::user_text("one")]);
    let _ = turn_state.model_finished(answer("done"), origin());

    assert!(matches!(turn_state.send(Vec::new()), Action::Send(_)));

    assert_eq!(lines(&context), ["user one", "assistant done"]);
}

#[test]
fn tool_call_answer_asks_for_its_calls_and_the_results_and_new_input_join_the_next_request() {
    let mut context = Vec::new();
    let mut turn_state = TurnState::new(&mut context, None);
    let _ = turn_state.send(vec![Block::user_text("one")]);

    let action = turn_state.model_finished(tool_answer(FinishReason::ToolCalls), origin());
    assert_eq!(called_names(action), ["read", "write"]);

    let results = vec![
        ToolResult::success("c1", "file text"),
        ToolResult::success("c2", "written"),
    ];
    let action = turn_state.tools_finished(results);
    assert!(matches!(
        action,
        Action::AfterRound {
            finish_reason: None,
            ..
        }
    ));
    assert!(matches!(
        turn_state.proceed(vec![Block::user_text("also run the tests")]),
        Action::Send(_)
    ));
    assert_eq!(
        lines(&context),
        [
            "user one",
            "assistant Let me check.",
            "reasoning Two files.",
            "call c1",
            "assistant And the other.",
            "call c2",
            "result c1 file text",
            "result c2 written",
            "user also run the tests",
        ]
    );
}

#[test]
fn stop_finish_with_tool_calls_runs_them() {
    let mut context = Vec::new();
    let mut turn_state = TurnState::new(&mut context, None);
    let _ = turn_state.send(vec![Block::user_text("one")]);

    let action = turn_state.model_finished(tool_answer(FinishReason::Stop), origin());

    assert_eq!(called_names(action), ["read", "write"]);
}

#[test]
fn length_finish_runs_no_tool_and_asks_the_model_again() {
    let mut context = Vec::new();
    let mut turn_state = TurnState::new(&mut context, None);
    let _ = turn_state.send(vec![Block::user_text("one")]);

    let action = turn_state.model_finished(tool_answer(FinishReason::Length), origin());
    assert!(matches!(
        action,
        Action::AfterRound {
            finish_reason: None,
            ..
        }
    ));
    assert!(matches!(turn_state.proceed(Vec::new()), Action::Send(_)));

    let not_run = "was not executed: the response hit the output token limit, so its arguments may be truncated.";
    assert_eq!(
        lines(&context),
        [
            "user one".to_owned(),
            "assistant Let me check.".to_owned(),
            "reasoning Two files.".to_owned(),
            "call c1".to_owned(),
            "assistant And the other.".to_owned(),
            "call c2".to_owned(),
            format!("error c1 Tool call \"read\" {not_run}"),
            format!("error c2 Tool call \"write\" {not_run}"),
        ]
    );
}

#[test]
fn content_filter_finish_runs_no_tool_and_ends_the_turn() {
    let mut context = Vec::new();
    let mut turn_state = TurnState::new(&mut context, None);
    let _ = turn_state.send(vec![Block::user_text("one")]);
    let _ = turn_state.model_finished(tool_answer(FinishReason::ContentFilter), origin());

    assert!(matches!(
        turn_state.proceed(Vec::new()),
        Action::Done {
            result: Ok(Outcome::Completed {
                finish_reason: FinishReason::ContentFilter
            }),
            ..
        }
    ));
    let results: Vec<(&str, bool)> = context
        .iter()
        .filter_map(|block| match block {
            Block::ToolResult(result) if result.content.ends_with("finish reason content_filter.") => {
                Some((result.call_id.as_str(), result.is_error))
            }
            _ => None,
        })
        .collect();
    assert_eq!(results, [("c1", true), ("c2", true)]);
}

#[test]
fn cancelled_request_keeps_its_text_and_gives_each_call_an_error_result() {
    let mut context = Vec::new();
    let mut turn_state = TurnState::new(&mut context, None);
    let _ = turn_state.send(vec![Block::user_text("one")]);

    let action = turn_state.model_cancelled(vec![
        Partial::Text("Let me check.".to_owned()),
        Partial::ToolCall(ToolCall {
            call_id: "c1".to_owned(),
            name: "read".to_owned(),
            arguments: "{}".to_owned(),
        }),
    ]);

    assert!(matches!(
        action,
        Action::Done {
            result: Ok(Outcome::Cancelled),
            ..
        }
    ));
    assert_eq!(
        context,
        [
            Block::user_text("one"),
            Block::assistant_text("Let me check."),
            Block::ToolCall(ToolCall {
                call_id: "c1".to_owned(),
                name: "read".to_owned(),
                arguments: "{}".to_owned()
            }),
            Block::ToolResult(ToolResult::error(
                "c1",
                "Tool call \"read\" was not executed: the user cancelled the turn."
            )),
        ]
    );
}

// The protocol sends a commit as this JSON. The SQLite store saves the parts of a commit in columns instead.
// A transparent error gives its cause only through `source`. The saved text must keep that cause.
#[test]
fn a_failed_turn_saves_the_causes_of_its_error() {
    let error = RoundError::Model(yuke_ai::Error::Encode(yuke_ai::EncodeError::BlobRead {
        digest: [0; 32],
        source: Box::new(std::io::Error::other("the disk is gone")),
    }));

    let commit = Commit::end(&[], Err(&error));

    let expected = format!(
        "the blob store failed to read the attachment blob {}: the disk is gone",
        "0".repeat(64)
    );
    assert_eq!(commit.end, Some(TurnEnd::Failed(expected)));
}

#[test]
fn a_commit_reads_back_from_its_json() {
    let head = [Block::user_text("summary")];
    let blocks = [Block::assistant_text("a")];
    let cases = [
        (
            Commit {
                replaced: Some(Replaced {
                    head: Cow::Borrowed(&head),
                    keep: 2,
                }),
                blocks: Cow::Borrowed(&blocks),
                answer: Some(Answer {
                    origin: yuke_ai::Origin {
                        model: "m".to_owned(),
                        base_url: "https://h".to_owned(),
                    },
                    usage: Usage {
                        input: Some(1),
                        output: Some(2),
                        reasoning: Some(3),
                        cache_read: Some(4),
                        cache_write: Some(5),
                    },
                    finish_reason: FinishReason::Stop,
                }),
                end: Some(TurnEnd::Outcome(Outcome::Completed {
                    finish_reason: FinishReason::ToolCalls,
                })),
            },
            r#"{"replaced":{"head":[{"user_text":"summary"}],"keep":2},"blocks":[{"assistant_text":"a"}],"answer":{"origin":{"model":"m","baseUrl":"https://h"},"usage":{"input":1,"output":2,"reasoning":3,"cacheRead":4,"cacheWrite":5},"finishReason":"stop"},"end":{"outcome":{"completed":{"finishReason":"tool_calls"}}}}"#,
        ),
        (
            Commit {
                replaced: None,
                blocks: Cow::Borrowed(&[]),
                answer: None,
                end: Some(TurnEnd::Failed("the request failed".to_owned())),
            },
            r#"{"replaced":null,"blocks":[],"answer":null,"end":{"failed":"the request failed"}}"#,
        ),
        (
            Commit {
                replaced: None,
                blocks: Cow::Borrowed(&[]),
                answer: None,
                end: Some(TurnEnd::Outcome(Outcome::Cancelled)),
            },
            r#"{"replaced":null,"blocks":[],"answer":null,"end":{"outcome":"cancelled"}}"#,
        ),
    ];
    for (commit, json) in cases {
        assert_eq!(serde_json::to_string(&commit).unwrap(), json);
        assert_eq!(serde_json::from_str::<Commit<'static>>(json).unwrap(), commit);
    }
}

/// A call `id` and its result.
fn pair(id: &str) -> [Block; 2] {
    [
        Block::ToolCall(ToolCall {
            call_id: id.to_owned(),
            name: "read".to_owned(),
            arguments: "{}".to_owned(),
        }),
        Block::ToolResult(ToolResult::success(id, "done")),
    ]
}

#[test]
fn a_replacement_check_refuses_a_result_without_an_earlier_call() {
    let [call, result] = pair("c1");
    let context = [
        Block::user_text("one"),
        call.clone(),
        result.clone(),
        Block::assistant_text("two"),
    ];
    let reversed = [result.clone(), call.clone()];
    let summary = [Block::user_text("summary")];
    // The call of `context` is the third block from the end, so `keep: 2` cuts it from its result.
    let cases: [(&[Block], &[Block], usize, bool); 6] = [
        (&context, &summary, 2, false),
        (&context, &summary, 3, true),
        (&context, &summary, 1, true),
        (&[], std::slice::from_ref(&result), 0, false),
        (&[], &[call.clone(), result.clone()], 0, true),
        (&reversed, &[], 2, false),
    ];
    for (context, head, keep, valid) in cases {
        let replaced = Replaced {
            head: Cow::Borrowed(head),
            keep,
        };
        assert_eq!(replaced.check(context).is_ok(), valid, "{head:?} {keep} {context:?}");
    }
    let cut = Replaced {
        head: Cow::Borrowed(&summary),
        keep: 2,
    };
    assert_eq!(
        cut.check(&context),
        Err("the replacement contains the result of call c1 without its call".to_owned())
    );
}
