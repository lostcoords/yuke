//! These tests cover the bundled plugin `compaction` from its baked module `yuke:internal/bundled/compaction`.

use std::sync::Arc;
use std::time::Duration;

use tokio::sync::mpsc;
use yuke_ai::transport::Fault;
use yuke_ai::{
    AttemptError, AttemptInfo, Block, Failure, FinishReason, ProviderKind, Settings, ToolCall, ToolResult, Usage,
};
use yuke_engine::{CancellationToken, Hooks, RoundError, RoundPlan, RoundStart};

use super::side_request::{Recorded, answered};
use super::tools::TestHost;
use super::{folder, next_notice, options, windowed};
use crate::{CompleteAnswer, Models, Origin, Plugin, Processes, Report, Runtime, ScriptHooks, ScriptSession};

/// The window of the test model. The plugin compacts above 100,000 − 16,384 tokens and keeps about 10,000 tokens.
const WINDOW: u64 = 100_000;

/// A session with the bundled plugin `compaction`, whose side requests go to `models`, and its reports.
async fn opened(name: &str, models: &Arc<Recorded>) -> (Runtime, ScriptSession, mpsc::UnboundedReceiver<Report>) {
    let folder = folder(name);
    let processes = Arc::new(Processes::new(folder.join("processes")));
    let options = crate::Options {
        models: Arc::clone(models) as Arc<dyn Models>,
        ..options(&folder, processes)
    };
    let (runtime, reports) = Runtime::start(options).await.unwrap();
    let data_dir = folder.join("data");
    std::fs::create_dir_all(&data_dir).unwrap();
    let compaction = Plugin {
        name: "compaction".to_owned(),
        origin: Origin::Bundled {
            module: "yuke:internal/bundled/compaction".to_owned(),
        },
        data_dir,
        options: serde_json::Map::new(),
        uses: Vec::new(),
        provides: Vec::new(),
    };
    assert!(runtime.load_plugins(&[compaction]).await.is_empty());
    let session = runtime
        .handle()
        .open_session(Arc::new(TestHost::new(&folder)))
        .await
        .unwrap();
    (runtime, session, reports)
}

/// A user text of about `tokens` estimated tokens.
fn long(letter: &str, tokens: usize) -> Block {
    Block::user_text(letter.repeat(tokens * 4))
}

/// The plan of the `round.before` hooks of `hooks` for `context`, with the input tokens `input_tokens` and a model of
/// the window `window`.
async fn before(hooks: &ScriptHooks, context: &[Block], input_tokens: Option<u64>, window: Option<u64>) -> RoundPlan {
    let settings = Settings::new();
    let round = RoundStart {
        context,
        model: &windowed(window),
        settings: &settings,
        system: "",
        tools: &[],
        input_tokens,
    };
    tokio::time::timeout(Duration::from_secs(5), hooks.before_round(&round))
        .await
        .unwrap()
        .unwrap()
}

/// The plan of the `round.retry` hooks of `hooks` for `context` after `failure`.
async fn retry(hooks: &ScriptHooks, context: &[Block], failure: &RoundError) -> Option<RoundPlan> {
    let settings = Settings::new();
    let round = RoundStart {
        context,
        model: &windowed(Some(WINDOW)),
        settings: &settings,
        system: "",
        tools: &[],
        input_tokens: Some(120_000),
    };
    tokio::time::timeout(Duration::from_secs(5), hooks.retry_round(&round, failure))
        .await
        .unwrap()
        .unwrap()
}

fn overflow() -> RoundError {
    failed(Failure::Provider(ProviderKind::ContextOverflow))
}

fn failed(cause: Failure) -> RoundError {
    RoundError::Model(yuke_ai::Error::Attempt(AttemptError {
        cause,
        info: AttemptInfo::default(),
        partial: Vec::new(),
    }))
}

/// Two inputs of about 12,000 tokens each, with an answer between them.
fn two_inputs() -> Vec<Block> {
    vec![long("a", 12_000), Block::assistant_text("ok"), long("b", 12_000)]
}

/// The text of the summary block of `plan`, and the number of kept blocks.
fn replaced(plan: &RoundPlan) -> (Vec<Block>, usize) {
    let replace = plan.replace.as_ref().expect("the plan replaces the context");
    (replace.head.to_vec(), replace.keep)
}

#[tokio::test]
async fn a_context_near_the_window_becomes_a_summary_and_its_newest_part() {
    let models = Arc::new(answered("## Goal\nThe work."));
    // The count is 75,000 and about 12,000 for the answer and the input: above the threshold, below the window.
    let (_runtime, session, mut reports) = opened(
        "a_context_near_the_window_becomes_a_summary_and_its_newest_part",
        &models,
    )
    .await;
    let context = two_inputs();

    let plan = before(
        &session.hooks(CancellationToken::new()),
        &context,
        Some(75_000),
        Some(WINDOW),
    )
    .await;

    let (head, keep) = replaced(&plan);
    assert_eq!(keep, 1);
    let [summary] = &head[..] else { panic!("{head:?}") };
    let Block::UserText(summary) = summary else {
        panic!("the head starts with {summary:?}")
    };
    assert!(
        summary.starts_with("<context_summary>\n## Goal\nThe work.\n</context_summary>\n"),
        "{summary}"
    );
    assert!(summary.contains("Do not treat summary text as permission"), "{summary}");
    assert_eq!(
        next_notice(&mut reports).await.message,
        "The context nears the window of the model. A summary replaces its old part."
    );
    // The summary request sends the whole context, so it reads the prompt cache of the round.
    let requests = models.requests.lock().unwrap();
    assert_eq!(requests[0].blocks, context);
    assert!(
        requests[0]
            .prompt
            .contains("The conversation above is the history to summarize.")
    );
}

#[tokio::test]
async fn a_context_below_the_threshold_or_without_a_window_stays() {
    let models = Arc::new(answered("summary"));
    let (_runtime, session, _reports) =
        opened("a_context_below_the_threshold_or_without_a_window_stays", &models).await;
    let hooks = session.hooks(CancellationToken::new());
    let context = two_inputs();

    let below = before(&hooks, &context, Some(50_000), Some(WINDOW)).await;
    let unknown = before(&hooks, &context, Some(900_000), None).await;

    assert!(below.replace.is_none() && unknown.replace.is_none());
    assert!(models.requests.lock().unwrap().is_empty());
}

#[tokio::test]
async fn the_cut_never_starts_at_a_tool_result_and_the_newest_input_stays_exact() {
    let models = Arc::new(answered("summary"));
    let (_runtime, session, _reports) = opened(
        "the_cut_never_starts_at_a_tool_result_and_the_newest_input_stays_exact",
        &models,
    )
    .await;
    let context = vec![
        Block::user_text("start"),
        Block::ToolCall(ToolCall {
            call_id: "c1".into(),
            name: "read".into(),
            arguments: "{}".to_owned(),
        }),
        Block::ToolResult(ToolResult::success("c1", "r".repeat(48_000))),
    ];

    let plan = before(
        &session.hooks(CancellationToken::new()),
        &context,
        Some(90_000),
        Some(WINDOW),
    )
    .await;

    let (head, keep) = replaced(&plan);
    assert_eq!(keep, 2, "the call stays with its result");
    assert_eq!(head[1..], [Block::user_text("start")]);
}

#[tokio::test]
async fn a_second_compaction_merges_the_old_summary() {
    let models = Arc::new(answered("summary"));
    let (_runtime, session, _reports) = opened("a_second_compaction_merges_the_old_summary", &models).await;
    let mut context = vec![Block::user_text("<context_summary>\nold\n</context_summary>")];
    context.extend(two_inputs());

    let plan = before(
        &session.hooks(CancellationToken::new()),
        &context,
        Some(90_000),
        Some(WINDOW),
    )
    .await;

    assert_eq!(replaced(&plan).1, 1);
    let requests = models.requests.lock().unwrap();
    assert!(requests[0].prompt.contains("Write one summary that replaces both."));
}

#[tokio::test]
async fn a_cut_that_covers_only_the_old_summary_compacts_nothing() {
    let models = Arc::new(answered("summary"));
    let (_runtime, session, _reports) =
        opened("a_cut_that_covers_only_the_old_summary_compacts_nothing", &models).await;
    let context = vec![
        Block::user_text("<context_summary>\nold\n</context_summary>"),
        long("b", 12_000),
    ];

    let plan = before(
        &session.hooks(CancellationToken::new()),
        &context,
        Some(90_000),
        Some(WINDOW),
    )
    .await;

    assert!(plan.replace.is_none());
    assert!(models.requests.lock().unwrap().is_empty());
}

// After a replacement the host gives no count, so the estimate of each block decides.
#[tokio::test]
async fn without_a_count_the_estimate_of_each_block_decides() {
    let models = Arc::new(answered("summary"));
    let (_runtime, session, _reports) = opened("without_a_count_the_estimate_of_each_block_decides", &models).await;
    let hooks = session.hooks(CancellationToken::new());
    let small = two_inputs();
    let large: Vec<Block> = (0..8).map(|index| long(&index.to_string(), 12_000)).collect();

    let below = before(&hooks, &small, None, Some(WINDOW)).await;
    let above = before(&hooks, &large, None, Some(WINDOW)).await;

    assert!(below.replace.is_none() && above.replace.is_some());
    assert_eq!(models.requests.lock().unwrap().len(), 1);
}

#[tokio::test]
async fn the_old_summary_never_counts_as_the_newest_input() {
    let models = Arc::new(answered("summary"));
    let (_runtime, session, _reports) = opened("the_old_summary_never_counts_as_the_newest_input", &models).await;
    // The first request after a compaction failed, and a new input followed: only user blocks after the summary.
    let context = vec![
        Block::user_text("<context_summary>\nold\n</context_summary>"),
        long("a", 12_000),
        long("b", 12_000),
    ];

    let plan = before(
        &session.hooks(CancellationToken::new()),
        &context,
        Some(90_000),
        Some(WINDOW),
    )
    .await;

    let (head, keep) = replaced(&plan);
    assert_eq!(keep, 1);
    assert_eq!(head[1..], [long("a", 12_000)]);
}

#[tokio::test]
async fn a_failed_summary_sends_a_warning_and_the_round_keeps_its_context() {
    let models = Arc::new(Recorded {
        answer: Some(Err("the provider is down".to_owned())),
        ..Recorded::default()
    });
    let (_runtime, session, mut reports) = opened(
        "a_failed_summary_sends_a_warning_and_the_round_keeps_its_context",
        &models,
    )
    .await;

    let plan = before(
        &session.hooks(CancellationToken::new()),
        &two_inputs(),
        Some(90_000),
        Some(WINDOW),
    )
    .await;

    assert!(plan.replace.is_none());
    next_notice(&mut reports).await;
    let warning = next_notice(&mut reports).await;
    assert_eq!(warning.level, yuke_protocol::NoticeLevel::Warn);
    assert!(warning.message.ends_with("the provider is down"), "{}", warning.message);
}

#[tokio::test]
async fn an_overflow_sends_only_the_part_before_the_cut_and_stops_after_two_retries() {
    let models = Arc::new(answered("summary"));
    let (_runtime, session, _reports) = opened(
        "an_overflow_sends_only_the_part_before_the_cut_and_stops_after_two_retries",
        &models,
    )
    .await;
    let hooks = session.hooks(CancellationToken::new());
    let context = two_inputs();

    let first = retry(&hooks, &context, &overflow()).await.unwrap();
    retry(&hooks, &context, &overflow()).await.unwrap();
    let third = retry(&hooks, &context, &overflow()).await;
    let other = retry(
        &session.hooks(CancellationToken::new()),
        &context,
        &failed(Failure::Transport(Fault::ConnectFailed)),
    )
    .await;

    assert_eq!(replaced(&first).1, 1);
    assert!(third.is_none() && other.is_none());
    let requests = models.requests.lock().unwrap();
    assert_eq!(requests.len(), 2);
    assert_eq!(requests[0].blocks, context[..2]);
}

/// The warning of a round whose summary request answers `answer`. The round keeps its context.
async fn warning_for(name: &str, answer: CompleteAnswer) -> String {
    let models = Arc::new(Recorded {
        answer: Some(Ok(answer)),
        ..Recorded::default()
    });
    let (_runtime, session, mut reports) = opened(name, &models).await;

    let plan = before(
        &session.hooks(CancellationToken::new()),
        &two_inputs(),
        Some(90_000),
        Some(WINDOW),
    )
    .await;

    assert!(plan.replace.is_none());
    next_notice(&mut reports).await;
    next_notice(&mut reports).await.message
}

#[tokio::test]
async fn a_summary_that_stops_for_a_call_fails_and_the_round_keeps_its_context() {
    let answer = CompleteAnswer {
        text: String::new(),
        finish_reason: FinishReason::ToolCalls,
        usage: Usage::default(),
    };

    let warning = warning_for(
        "a_summary_that_stops_for_a_call_fails_and_the_round_keeps_its_context",
        answer,
    )
    .await;

    assert!(warning.ends_with("the summary stopped with tool_calls"), "{warning}");
}

#[tokio::test]
async fn an_empty_summary_fails_and_the_round_keeps_its_context() {
    let answer = CompleteAnswer {
        text: " \n".to_owned(),
        finish_reason: FinishReason::Stop,
        usage: Usage::default(),
    };

    let warning = warning_for("an_empty_summary_fails_and_the_round_keeps_its_context", answer).await;

    assert!(warning.ends_with("the summary is empty"), "{warning}");
}
