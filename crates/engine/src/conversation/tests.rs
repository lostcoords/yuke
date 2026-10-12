use std::borrow::Cow;

use yuke_ai::route::{Credential, Route};
use yuke_ai::{
    AnthropicWire, AttemptError, AttemptInfo, Block, Completion, Content, Encoder, Failure, FinishReason, Partial,
    ProviderKind, Reasoning, Request, Response, Target, ToolCall, ToolResult, Usage, Wire,
};

use super::{Action, Answer, Commit, Conversation, Outcome, Replaced, TurnEnd};

/// The origin of the test target.
fn origin() -> yuke_ai::Origin {
    yuke_ai::Origin {
        model: "test-model".to_owned(),
        base_url: "https://example.test/v1".to_owned(),
    }
}

/// The body that a request of `context` encodes to for an Anthropic target.
fn body(context: &[Block]) -> String {
    let target = Target {
        model: "test-model".into(),
        route: Route {
            base_url: "https://example.test/v1".into(),
            ..Route::default()
        },
        credential: Credential::None,
        wire: Wire::AnthropicMessages(AnthropicWire {
            max_tokens: 64,
            cache: false,
        }),
        tool_search: false,
    };
    let mut encoder = Encoder::new();
    let encoded = encoder.encode(&target, Request::new(context)).unwrap();
    String::from_utf8(encoded.http.body().flatten().copied().collect()).unwrap()
}

/// Assert that each of `texts` appears as a JSON string in `body`, in order.
fn assert_in_order(body: &str, texts: &[&str]) {
    let positions: Vec<Option<usize>> = texts.iter().map(|text| body.find(&format!("\"{text}\""))).collect();
    assert!(positions.iter().all(Option::is_some), "{body}");
    assert!(positions.is_sorted(), "{body}");
}

/// The names of the calls that `action` asks to run.
fn called_names(action: Action<'_>) -> Vec<String> {
    match action {
        Action::CallTools(calls, _) => calls.into_iter().map(|call| call.name.clone()).collect(),
        other => panic!("expected tool calls, got {other:?}"),
    }
}

fn answer(text: &str) -> Response {
    Response {
        info: AttemptInfo::default(),
        completion: Completion {
            content: vec![Content::Text(text.to_owned())],
            finish_reason: FinishReason::Stop,
            raw_finish_reason: "end_turn".to_owned(),
            usage: Usage::default(),
        },
    }
}

/// An answer with two calls between text and reasoning blocks.
fn tool_answer(finish_reason: FinishReason) -> Response {
    Response {
        info: AttemptInfo::default(),
        completion: Completion {
            content: vec![
                Content::Text("Let me check.".to_owned()),
                Content::Reasoning(Reasoning {
                    text: "Two files.".to_owned(),
                    replay: None,
                }),
                Content::ToolCall(ToolCall::new("c1", "read", "{}")),
                Content::Text("And the other.".to_owned()),
                Content::ToolCall(ToolCall::new("c2", "write", "{}")),
            ],
            finish_reason,
            raw_finish_reason: finish_reason.as_str().to_owned(),
            usage: Usage::default(),
        },
    }
}

#[test]
fn second_turn_sends_the_first_turn_context() {
    let mut context = Vec::new();
    let mut conversation = Conversation::new(&mut context);
    let _ = conversation.start(vec![Block::user_text("one")]);
    let _ = conversation.model_finished(Ok(answer("first answer")), origin());
    let _ = conversation.stop();

    let mut conversation = Conversation::new(&mut context);
    assert!(matches!(
        conversation.start(vec![Block::user_text("two")]),
        Action::Send(_)
    ));

    assert_in_order(&body(&context), &["one", "first answer", "two"]);
}

#[test]
fn a_final_answer_without_input_completes_the_turn() {
    let mut context = Vec::new();
    let mut conversation = Conversation::new(&mut context);
    let _ = conversation.start(vec![Block::user_text("one")]);
    assert!(matches!(
        conversation.model_finished(Ok(answer("done")), origin()),
        Action::AfterRound {
            finish_reason: Some(FinishReason::Stop),
            ..
        }
    ));

    assert!(matches!(
        conversation.proceed(Vec::new()),
        Action::Done {
            result: Ok(Outcome::Completed {
                finish_reason: FinishReason::Stop
            }),
            ..
        }
    ));
}

#[test]
fn continue_turn_sends_another_request_without_input() {
    let mut context = Vec::new();
    let mut conversation = Conversation::new(&mut context);
    let _ = conversation.start(vec![Block::user_text("one")]);
    let _ = conversation.model_finished(Ok(answer("done")), origin());

    assert!(matches!(conversation.continue_turn(Vec::new()), Action::Send(_)));

    assert_in_order(&body(&context), &["one", "done"]);
}

#[test]
fn failed_attempt_adds_no_assistant_block() {
    let mut context = Vec::new();
    let mut conversation = Conversation::new(&mut context);
    let _ = conversation.start(vec![Block::user_text("one")]);
    let failure = AttemptError {
        cause: Failure::Provider(ProviderKind::ServerError),
        info: AttemptInfo::default(),
        partial: vec![Partial::Text("cut".to_owned())],
    };

    let action = conversation.model_finished(Err(failure.into()), origin());

    assert!(matches!(action, Action::Done { result: Err(_), .. }));
    assert_eq!(context, [Block::user_text("one")]);
}

#[test]
fn tool_call_answer_asks_for_its_calls_and_the_results_and_new_input_join_the_next_request() {
    let mut context = Vec::new();
    let mut conversation = Conversation::new(&mut context);
    let _ = conversation.start(vec![Block::user_text("one")]);

    let action = conversation.model_finished(Ok(tool_answer(FinishReason::ToolCalls)), origin());
    assert_eq!(called_names(action), ["read", "write"]);

    let results = vec![
        ToolResult::success("c1", "file text"),
        ToolResult::success("c2", "written"),
    ];
    let action = conversation.tools_finished(results);
    assert!(matches!(
        action,
        Action::AfterRound {
            finish_reason: None,
            ..
        }
    ));
    assert!(matches!(
        conversation.proceed(vec![Block::user_text("also run the tests")]),
        Action::Send(_)
    ));
    assert_in_order(
        &body(&context),
        &["one", "c1", "c2", "file text", "written", "also run the tests"],
    );
}

#[test]
fn stop_finish_with_tool_calls_runs_them() {
    let mut context = Vec::new();
    let mut conversation = Conversation::new(&mut context);
    let _ = conversation.start(vec![Block::user_text("one")]);

    let action = conversation.model_finished(Ok(tool_answer(FinishReason::Stop)), origin());

    assert_eq!(called_names(action), ["read", "write"]);
}

#[test]
fn length_finish_runs_no_tool_and_asks_the_model_again() {
    let mut context = Vec::new();
    let mut conversation = Conversation::new(&mut context);
    let _ = conversation.start(vec![Block::user_text("one")]);

    let action = conversation.model_finished(Ok(tool_answer(FinishReason::Length)), origin());
    assert!(matches!(
        action,
        Action::AfterRound {
            finish_reason: None,
            ..
        }
    ));
    assert!(matches!(conversation.proceed(Vec::new()), Action::Send(_)));

    let body = body(&context);
    assert_in_order(&body, &["one", "c1", "c2"]);
    assert_eq!(
        body.matches("was not executed: the response hit the output token limit")
            .count(),
        2,
        "{body}"
    );
    assert_eq!(body.matches(r#""is_error":true"#).count(), 2, "{body}");
}

#[test]
fn content_filter_finish_runs_no_tool_and_ends_the_turn() {
    let mut context = Vec::new();
    let mut conversation = Conversation::new(&mut context);
    let _ = conversation.start(vec![Block::user_text("one")]);
    let _ = conversation.model_finished(Ok(tool_answer(FinishReason::ContentFilter)), origin());

    assert!(matches!(
        conversation.proceed(Vec::new()),
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
fn start_sends_every_block_of_the_input() {
    let mut context = Vec::new();
    let mut conversation = Conversation::new(&mut context);

    let _ = conversation.start(vec![Block::user_text("look at this"), Block::user_text("and this")]);

    assert_in_order(&body(&context), &["look at this", "and this"]);
}

#[test]
fn cancelled_request_keeps_its_text_and_calls_but_not_its_reasoning() {
    let mut context = Vec::new();
    let mut conversation = Conversation::new(&mut context);
    let _ = conversation.start(vec![Block::user_text("one")]);

    let action = conversation.model_cancelled(vec![
        Partial::Reasoning("Two files.".to_owned()),
        Partial::Text("Let me check.".to_owned()),
        Partial::ToolCall(ToolCall::new("c1", "read", "{}")),
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
            Block::ToolCall(ToolCall::new("c1", "read", "{}")),
            Block::ToolResult(ToolResult::error(
                "c1",
                "Tool call \"read\" was not executed: the user cancelled the turn."
            )),
        ]
    );
}

// The protocol sends a commit as this JSON. The SQLite store saves the parts of a commit in columns instead.
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
                        input: 1,
                        output: 2,
                        reasoning: 3,
                        cache_read: 4,
                        cache_write: 5,
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
