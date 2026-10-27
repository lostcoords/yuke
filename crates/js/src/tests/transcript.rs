//! The public module `yuke:transcript`: the fold of the events of a session into the entries of its conversation.

use serde_json::{Value, json};

use super::run;

/// The JavaScript that the tests share: the module, builders of the updates, and the updates of one turn in the order
/// of the protocol. The turn reads a test, runs it, and answers.
const TURN: &str = r#"
const { Transcript } = await import('yuke:transcript');
const settings = { model: { provider: 'p', model: 'm' }, settings: {}, cwd: '/w' };
const commit = (seq, fields, consumed = []) =>
  ({ seq, sessionUpdate: 'commit', commit: { replaced: null, blocks: [], answer: null, end: null, ...fields }, consumed });
const answer = (finishReason) => ({ finishReason });
const live = (sessionUpdate, fields = {}) => ({ sessionUpdate, ...fields });
const model = (draftId, event) => live('model', { draftId, event });
const call = { callId: 'call_0', name: 'bash', arguments: '{"command":"cargo test"}' };
const result = { callId: 'call_0', content: '1 failed', isError: false };
const turn = [
  { seq: 1, sessionUpdate: 'settings', ...settings },
  live('input_accepted', { inputId: 1, input: { source: { kind: 'user' }, kind: 'message', content: [{ user_text: 'fix the test' }] } }),
  live('state', { state: 'running' }),
  commit(2, { blocks: [{ user_text: 'fix the test' }] }, [{ id: 1, source: { kind: 'user' }, kind: 'message', blockCount: 1 }]),
  live('draft_started', { draftId: 'd1' }),
  model('d1', { kind: 'block_started', block: 0, blockKind: 'reasoning' }),
  model('d1', { kind: 'reasoning_delta', block: 0, text: 'the test ' }),
  model('d1', { kind: 'reasoning_section_started', block: 0 }),
  model('d1', { kind: 'reasoning_delta', block: 0, text: 'expects 3' }),
  model('d1', { kind: 'block_started', block: 1, blockKind: 'text' }),
  model('d1', { kind: 'text_delta', block: 1, text: 'I run ' }),
  model('d1', { kind: 'text_delta', block: 1, text: 'the tests.' }),
  model('d1', { kind: 'block_started', block: 2, blockKind: 'tool_call' }),
  model('d1', { kind: 'tool_input_delta', block: 2, text: '{"command":' }),
  model('d1', { kind: 'tool_input_delta', block: 2, text: '"cargo test"}' }),
  model('d1', { kind: 'block_stopped', block: 2, call }),
  model('d1', { kind: 'response_completed', finishReason: 'tool_calls', rawFinishReason: 'tool_use', usage: {} }),
  commit(3, {
    blocks: [{ reasoning: { text: 'the test expects 3' } }, { assistant_text: 'I run the tests.' }, { tool_call: call }],
    answer: answer('tool_calls'),
  }),
  live('draft_committed', { draftId: 'd1', eventNumber: 3, blocks: [0, 1, 2] }),
  live('tool_started', { execution: { eventNumber: 3, blockIndex: 2 }, call }),
  live('tool_output', { execution: { eventNumber: 3, blockIndex: 2 }, text: 'running 1 test\n' }),
  live('tool_finished', { execution: { eventNumber: 3, blockIndex: 2 }, result }),
  commit(4, { blocks: [{ tool_result: result }] }),
  live('draft_started', { draftId: 'd2' }),
  model('d2', { kind: 'block_started', block: 0, blockKind: 'text' }),
  model('d2', { kind: 'text_delta', block: 0, text: 'Fixed.' }),
  model('d2', { kind: 'block_stopped', block: 0, call: null }),
  commit(5, { blocks: [{ assistant_text: 'Fixed.' }], answer: answer('stop') }),
  live('draft_committed', { draftId: 'd2', eventNumber: 5, blocks: [0] }),
  commit(6, { end: { outcome: { completed: { finishReason: 'stop' } } } }),
  live('state', { state: 'idle' }),
];
const saved = turn.filter((update) => 'seq' in update);
const opened = (updates = []) => {
  const transcript = new Transcript();
  transcript.apply({ snapshot: { settings, updates } });
  return transcript;
};
const fed = (transcript, updates) => {
  for (const update of updates) transcript.apply({ update });
  return transcript;
};
const shown = (transcript) => JSON.stringify(transcript.entries);
"#;

/// Run `body` after [`TURN`]. Return the JSON value of the text that `body` returns.
async fn folded(name: &str, body: &str) -> Value {
    let text = run::<String>(name, &format!("{TURN}\n{body}")).await;
    serde_json::from_str(&text).unwrap()
}

/// The entries of [`TURN`] after its end.
fn turn_entries() -> Value {
    json!([
        { "kind": "input", "key": "2:0", "inputId": 1, "source": { "kind": "user" }, "inputKind": "message",
          "content": [{ "user_text": "fix the test" }] },
        { "kind": "reasoning", "key": "3:0", "text": "the test expects 3", "draft": false },
        { "kind": "text", "key": "3:1", "text": "I run the tests.", "refusal": false, "draft": false },
        { "kind": "tool", "key": "3:2", "name": "bash", "arguments": "{\"command\":\"cargo test\"}", "status": "done",
          "output": "", "result": { "callId": "call_0", "content": "1 failed", "isError": false } },
        { "kind": "text", "key": "5:0", "text": "Fixed.", "refusal": false, "draft": false },
        { "kind": "end", "key": "6:end", "end": { "outcome": { "completed": { "finishReason": "stop" } } } },
    ])
}

#[tokio::test]
async fn a_live_transcript_ends_equal_to_a_replay_of_its_saved_events() {
    let folded = folded(
        "a_live_transcript_ends_equal_to_a_replay_of_its_saved_events",
        "return JSON.stringify([JSON.parse(shown(fed(opened(), turn))), JSON.parse(shown(opened(saved)))]);",
    )
    .await;

    assert_eq!(folded, json!([turn_entries(), turn_entries()]));
}

#[tokio::test]
async fn a_draft_streams_its_blocks_until_its_saved_commit_replaces_them() {
    let folded = folded(
        "a_draft_streams_its_blocks_until_its_saved_commit_replaces_them",
        "const transcript = opened();
         const streamed = shown(fed(transcript, turn.slice(0, 16)));
         fed(transcript, turn.slice(16, 18));
         return JSON.stringify([JSON.parse(streamed), transcript.entries.map((entry) => entry.key)]);",
    )
    .await;

    assert_eq!(
        folded,
        json!([
            [
                turn_entries()[0],
                { "kind": "reasoning", "key": "draft:d1:0", "text": "the test expects 3", "draft": true },
                { "kind": "text", "key": "draft:d1:1", "text": "I run the tests.", "refusal": false, "draft": true },
                { "kind": "tool", "key": "draft:d1:2", "name": "bash", "arguments": "{\"command\":\"cargo test\"}",
                  "status": "waiting", "output": "" },
            ],
            ["2:0", "3:0", "3:1", "3:2"],
        ])
    );
}

#[tokio::test]
async fn a_tool_shows_its_live_output_until_its_saved_result() {
    let folded = folded(
        "a_tool_shows_its_live_output_until_its_saved_result",
        "const transcript = fed(opened(), turn.slice(0, 20));
         const running = transcript.entries[3];
         fed(transcript, turn.slice(20, 22));
         const finished = transcript.entries[3];
         fed(transcript, turn.slice(22, 23));
         return JSON.stringify([running.status, running.output, finished.status, finished.output,
                                transcript.entries[3].output]);",
    )
    .await;

    assert_eq!(folded, json!(["running", "", "done", "running 1 test\n", ""]));
}

// Some providers start the call ids of each answer again, so only the saved position tells two calls apart.
#[tokio::test]
async fn tool_updates_reach_their_call_by_position_when_call_ids_repeat() {
    let folded = folded(
        "tool_updates_reach_their_call_by_position_when_call_ids_repeat",
        "const read = { callId: 'call_0', name: 'read', arguments: '{}' };
         const transcript = fed(opened(saved.slice(0, 3)), [
           commit(4, { blocks: [{ tool_result: result }] }),
           commit(5, { blocks: [{ tool_call: read }], answer: answer('tool_calls') }),
           live('tool_started', { execution: { eventNumber: 5, blockIndex: 0 }, call: read }),
           live('tool_output', { execution: { eventNumber: 5, blockIndex: 0 }, text: 'lib.rs' }),
         ]);
         return JSON.stringify(transcript.entries.filter((entry) => entry.kind === 'tool')
           .map((entry) => [entry.key, entry.name, entry.status, entry.output, entry.result?.content ?? null]));",
    )
    .await;

    assert_eq!(
        folded,
        json!([
            ["3:2", "bash", "done", "", "1 failed"],
            ["5:0", "read", "running", "lib.rs", null],
        ])
    );
}

// An answer cut by its length saves an error result per call in the same commit. A repair commit saves the results
// of the calls that an unconfirmed turn left open.
#[tokio::test]
async fn saved_results_pair_with_the_calls_of_their_answer_in_the_same_or_a_later_commit() {
    let folded = folded(
        "saved_results_pair_with_the_calls_of_their_answer_in_the_same_or_a_later_commit",
        "const error = (content) => ({ tool_result: { callId: 'call_0', content, isError: true } });
         const transcript = opened([
           commit(1, { blocks: [{ tool_call: call }, { tool_call: call }, error('cut 1'), error('cut 2')],
                       answer: answer('length') }),
           commit(2, { blocks: [{ tool_call: call }], answer: answer('tool_calls') }),
           commit(3, { blocks: [error('the turn stopped')], end: { failed: 'the turn stopped before it saved its end' } }),
         ]);
         return JSON.stringify(transcript.entries.filter((entry) => entry.kind === 'tool')
           .map((entry) => [entry.key, entry.status, entry.result.content]));",
    )
    .await;

    assert_eq!(
        folded,
        json!([
            ["1:0", "done", "cut 1"],
            ["1:1", "done", "cut 2"],
            ["2:0", "done", "the turn stopped"]
        ])
    );
}

#[tokio::test]
async fn a_page_that_starts_mid_turn_pairs_its_results_after_the_older_page() {
    let folded = folded(
        "a_page_that_starts_mid_turn_pairs_its_results_after_the_older_page",
        "const transcript = opened(saved.slice(3));
         const before = [transcript.first, transcript.entries.map((entry) => entry.key)];
         const later = transcript.entries[0];
         transcript.insert(saved.slice(0, 3));
         const full = opened(saved.slice(1));
         const tool = full.entries[3];
         full.insert(saved.slice(0, 1));
         return JSON.stringify([before, transcript.first, transcript.entries[4] === later, full.entries[3] === tool,
                                JSON.parse(shown(transcript))]);",
    )
    .await;

    assert_eq!(folded, json!([[4, ["5:0", "6:end"]], 1, true, true, turn_entries()]));
}

#[tokio::test]
async fn a_gap_names_the_missing_events_and_insert_fills_it() {
    let folded = folded(
        "a_gap_names_the_missing_events_and_insert_fills_it",
        "const transcript = fed(opened(saved.slice(0, 3)), saved.slice(4));
         const gap = transcript.gap;
         transcript.insert(saved.slice(3, 4));
         return JSON.stringify([gap, transcript.gap ?? null, JSON.parse(shown(transcript))]);",
    )
    .await;

    assert_eq!(folded, json!([{ "before": 5, "limit": 1 }, null, turn_entries()]));
}

#[tokio::test]
async fn a_gap_fill_removes_the_inputs_that_its_commits_consume() {
    let folded = folded(
        "a_gap_fill_removes_the_inputs_that_its_commits_consume",
        "const transcript = fed(opened(saved.slice(0, 1)), [turn[1], ...saved.slice(2)]);
         const before = [...transcript.pending.keys()];
         transcript.insert(saved.slice(1, 2));
         return JSON.stringify([before, [...transcript.pending.keys()]]);",
    )
    .await;

    assert_eq!(folded, json!([[1], []]));
}

#[tokio::test]
async fn a_cancel_mid_draft_keeps_only_what_its_commit_saved() {
    let folded = folded(
        "a_cancel_mid_draft_keeps_only_what_its_commit_saved",
        "const transcript = fed(opened(), [
           ...turn.slice(0, 11),
           commit(3, { blocks: [{ assistant_text: 'I run ' }], end: { outcome: 'cancelled' } }),
           live('draft_discarded', { draftId: 'd1', reason: 'failed' }),
         ]);
         return shown(transcript);",
    )
    .await;

    assert_eq!(
        folded,
        json!([
            turn_entries()[0],
            { "kind": "text", "key": "3:0", "text": "I run ", "refusal": false, "draft": false },
            { "kind": "end", "key": "3:end", "end": { "outcome": "cancelled" } },
        ])
    );
}

#[tokio::test]
async fn a_context_replacement_adds_a_marker_and_keeps_the_entries_before_it() {
    let folded = folded(
        "a_context_replacement_adds_a_marker_and_keeps_the_entries_before_it",
        "const transcript = fed(opened(saved), [
           commit(7, { replaced: { head: [{ user_text: '<context_summary>…' }], keep: 0 } }),
         ]);
         return JSON.stringify(transcript.entries.map((entry) => entry.key));",
    )
    .await;

    assert_eq!(
        folded,
        json!(["2:0", "3:0", "3:1", "3:2", "5:0", "6:end", "7:replaced"])
    );
}

#[tokio::test]
async fn a_change_puts_a_new_object_only_in_the_place_of_its_entry() {
    let folded = folded(
        "a_change_puts_a_new_object_only_in_the_place_of_its_entry",
        "const transcript = fed(opened(), turn.slice(0, 11));
         const before = [...transcript.entries];
         transcript.apply({ update: turn[11] });
         return JSON.stringify(transcript.entries.map((entry, index) => entry === before[index]));",
    )
    .await;

    assert_eq!(folded, json!([true, true, false]));
}

#[tokio::test]
async fn the_updates_of_a_draft_that_started_before_the_snapshot_add_nothing() {
    let folded = folded(
        "the_updates_of_a_draft_that_started_before_the_snapshot_add_nothing",
        "const transcript = fed(opened(saved.slice(0, 2)), turn.slice(9, 12));
         const during = transcript.entries.length;
         fed(transcript, turn.slice(17, 18));
         return JSON.stringify([during, transcript.entries.map((entry) => entry.key)]);",
    )
    .await;

    assert_eq!(folded, json!([1, ["2:0", "3:0", "3:1", "3:2"]]));
}

#[tokio::test]
async fn an_unconfirmed_turn_drops_its_draft_and_the_live_state_of_its_tools() {
    let folded = folded(
        "an_unconfirmed_turn_drops_its_draft_and_the_live_state_of_its_tools",
        "const transcript = fed(opened(), [
           ...turn.slice(0, 21),
           live('draft_started', { draftId: 'd2' }),
           model('d2', { kind: 'block_started', block: 0, blockKind: 'text' }),
           live('turn_unconfirmed'),
         ]);
         return JSON.stringify(transcript.entries.map((entry) => [entry.key, entry.status ?? null, entry.output ?? null]));",
    )
    .await;

    assert_eq!(
        folded,
        json!([
            ["2:0", null, null],
            ["3:0", null, null],
            ["3:1", null, null],
            ["3:2", "waiting", ""]
        ])
    );
}

#[tokio::test]
async fn the_inputs_questions_status_and_settings_follow_their_updates() {
    let folded = folded(
        "the_inputs_questions_status_and_settings_follow_their_updates",
        "const transcript = opened();
         const facts = () => [transcript.state, [...transcript.pending.keys()], [...transcript.questions.keys()],
                              transcript.status ?? null, transcript.settings.model.model];
         const steps = [];
         fed(transcript, turn.slice(0, 3));
         fed(transcript, [
           live('interaction_requested', { interactionId: 7, source: 'ask', request: { kind: 'confirm', title: 't', message: 'm' } }),
           live('retry_scheduled', { afterMs: 3000, error: 'overloaded' }),
         ]);
         steps.push(facts());
         fed(transcript, [...turn.slice(3, 5), live('interaction_closed', { interactionId: 7 })]);
         steps.push(facts());
         fed(transcript, [{ seq: 3, sessionUpdate: 'settings', ...settings, model: { provider: 'p', model: 'n' } }]);
         steps.push(facts());
         // The snapshot and the live events give the settings. An older page holds older settings.
         const paged = opened([{ seq: 7, sessionUpdate: 'settings', ...settings, model: { provider: 'p', model: 'n' } }]);
         paged.insert(saved);
         return JSON.stringify([steps, paged.settings.model.model]);",
    )
    .await;

    assert_eq!(
        folded,
        json!([
            [
                ["running", [1], [7], { "kind": "retry_scheduled", "afterMs": 3000, "error": "overloaded" }, "m"],
                ["running", [], [], null, "m"],
                ["running", [], [], null, "n"],
            ],
            "n",
        ])
    );
}

#[tokio::test]
async fn a_deferred_tool_shows_the_tool_that_its_bridge_call_names() {
    let folded = folded(
        "a_deferred_tool_shows_the_tool_that_its_bridge_call_names",
        r#"const bridge = { callId: 'c', name: 'tool_call', arguments: '{"name":"grep","arguments":{"pattern":"x"}}' };
           const transcript = opened([commit(1, { blocks: [{ tool_call: bridge }], answer: answer('tool_calls') })]);
           return JSON.stringify([transcript.entries[0].name, transcript.entries[0].arguments]);"#,
    )
    .await;

    assert_eq!(folded, json!(["grep", "{\"pattern\":\"x\"}"]));
}
