use yuke_ai::{
    AttemptError, AttemptInfo, Block, Completion, Content, Failure, FinishReason, Partial, ProviderKind, Reasoning,
    Response, ToolCall, ToolResult, Usage,
};
use yuke_engine::{Action, Conversation, Outcome};

use crate::support::{assert_in_order, called_names, sent_body};

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

#[test]
fn second_turn_sends_the_first_turn_history() {
    let mut conversation = Conversation::new();
    let _ = conversation.start(vec![Block::user_text("one")]);
    let _ = conversation.model_finished(Ok(answer("first answer")));
    let _ = conversation.stop();

    let body = sent_body(conversation.start(vec![Block::user_text("two")]));

    assert_in_order(&body, &["one", "first answer", "two"]);
}

#[test]
fn stop_after_the_final_answer_ends_the_turn_as_completed() {
    let mut conversation = Conversation::new();
    let _ = conversation.start(vec![Block::user_text("one")]);
    let _ = conversation.model_finished(Ok(answer("done")));

    let action = conversation.stop();

    assert!(matches!(
        action,
        Action::Done(Ok(Outcome::Completed {
            finish_reason: FinishReason::Stop
        }))
    ));
}

#[test]
fn continue_turn_sends_another_request_without_input() {
    let mut conversation = Conversation::new();
    let _ = conversation.start(vec![Block::user_text("one")]);
    let _ = conversation.model_finished(Ok(answer("done")));
    assert!(matches!(conversation.proceed(Vec::new()), Action::AfterTurn { .. }));

    let body = sent_body(conversation.continue_turn(Vec::new()));

    assert_in_order(&body, &["one", "done"]);
}

#[test]
fn failed_attempt_adds_no_assistant_block() {
    let mut conversation = Conversation::new();
    let _ = conversation.start(vec![Block::user_text("one")]);
    let failure = AttemptError {
        cause: Failure::Provider(ProviderKind::ServerError),
        info: AttemptInfo::default(),
        partial: vec![Partial::Text("cut".to_owned())],
    };

    let action = conversation.model_finished(Err(failure.into()));

    assert!(matches!(action, Action::Done(Err(_))));
    assert_eq!(conversation.history(), [Block::user_text("one")]);
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
fn tool_call_answer_asks_for_its_calls_and_the_results_and_new_input_join_the_next_request() {
    let mut conversation = Conversation::new();
    let _ = conversation.start(vec![Block::user_text("one")]);

    let action = conversation.model_finished(Ok(tool_answer(FinishReason::ToolCalls)));
    assert_eq!(called_names(action), ["read", "write"]);

    let results = vec![
        ToolResult::success("c1", "file text"),
        ToolResult::success("c2", "written"),
    ];
    let action = conversation.tools_finished(results);
    assert!(matches!(action, Action::AfterRound(_)));
    let body = sent_body(conversation.proceed(vec![Block::user_text("also run the tests")]));
    assert_in_order(
        &body,
        &["one", "c1", "c2", "file text", "written", "also run the tests"],
    );
}

#[test]
fn stop_finish_with_tool_calls_runs_them() {
    let mut conversation = Conversation::new();
    let _ = conversation.start(vec![Block::user_text("one")]);

    let action = conversation.model_finished(Ok(tool_answer(FinishReason::Stop)));

    assert_eq!(called_names(action), ["read", "write"]);
}

#[test]
fn length_finish_runs_no_tool_and_asks_the_model_again() {
    let mut conversation = Conversation::new();
    let _ = conversation.start(vec![Block::user_text("one")]);

    let action = conversation.model_finished(Ok(tool_answer(FinishReason::Length)));
    assert!(matches!(action, Action::AfterRound(_)));

    let body = sent_body(conversation.proceed(Vec::new()));
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
    let mut conversation = Conversation::new();
    let _ = conversation.start(vec![Block::user_text("one")]);
    let _ = conversation.model_finished(Ok(tool_answer(FinishReason::ContentFilter)));

    let action = conversation.proceed(Vec::new());

    assert!(matches!(
        action,
        Action::AfterTurn {
            finish_reason: FinishReason::ContentFilter,
            ..
        }
    ));
    assert!(matches!(
        conversation.stop(),
        Action::Done(Ok(Outcome::Completed {
            finish_reason: FinishReason::ContentFilter
        }))
    ));
    let results: Vec<(&str, bool)> = conversation
        .history()
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
    let mut conversation = Conversation::new();

    let body = sent_body(conversation.start(vec![Block::user_text("look at this"), Block::user_text("and this")]));

    assert_in_order(&body, &["look at this", "and this"]);
}

#[test]
fn cancelled_request_keeps_its_text_and_calls_but_not_its_reasoning() {
    let mut conversation = Conversation::new();
    let _ = conversation.start(vec![Block::user_text("one")]);

    let action = conversation.model_cancelled(vec![
        Partial::Reasoning("Two files.".to_owned()),
        Partial::Text("Let me check.".to_owned()),
        Partial::ToolCall(ToolCall::new("c1", "read", "{}")),
    ]);

    assert!(matches!(action, Action::Done(Ok(Outcome::Cancelled))));
    assert_eq!(
        conversation.history(),
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
