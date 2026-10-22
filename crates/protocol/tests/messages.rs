//! The JSON of each message: it reads from a hand-written example in the style of the Agent Client Protocol, and it
//! writes the same JSON back.
#![expect(clippy::unwrap_used, reason = "a test fails by panicking")]

use std::borrow::Cow;

use serde::Serialize;
use serde::de::DeserializeOwned;
use serde_json::{Value, json};
use yuke_engine::{Commit, Outcome, TurnEnd};
use yuke_protocol::{
    ClientNotification, ClientRequest, ConsumedInput, EventNumber, Input, InputError, InputId, InputKind, InputSource,
    JobState, ListMcpServersResult, LiveUpdate, McpServer, McpServerSource, McpServerState, ModelReference,
    NoticeLevel, NoticeParams, Notification, Request, Response, ServerNotification, SessionEvent, SessionId,
    SessionSettings, SessionUpdate, SessionUpdateParams, StoredEvent,
};

const SESSION: &str = "0192f0c1-7d4e-7a3b-9c2d-1e5f6a7b8c9d";

fn session() -> SessionId {
    serde_json::from_value(json!(SESSION)).unwrap()
}

/// The settings JSON of [`settings`].
fn settings_json() -> Value {
    json!({
        "model": { "provider": "test", "model": "test-model" },
        "settings": {
            "maxOutputTokens": null, "reasoning": { "thinking": null, "effort": null },
            "temperature": null, "topP": null, "toolChoice": "auto", "outputSchema": null
        },
        "cwd": "/work"
    })
}

fn settings() -> SessionSettings {
    SessionSettings {
        model: ModelReference {
            provider: "test".to_owned(),
            model: "test-model".to_owned(),
        },
        settings: yuke_ai::Settings::new(),
        cwd: "/work".into(),
    }
}

/// Assert that `json` reads as `message` and that `message` writes `json`.
fn assert_json<T: Serialize + DeserializeOwned + PartialEq + std::fmt::Debug>(json: &Value, message: &T) {
    assert_eq!(&serde_json::from_value::<T>(json.clone()).unwrap(), message);
    assert_eq!(&serde_json::to_value(message).unwrap(), json);
}

fn request(id: i64, call: ClientRequest) -> Request {
    Request {
        jsonrpc: yuke_protocol::JsonRpc::V2,
        id: yuke_protocol::RequestId::Number(id),
        call,
    }
}

#[test]
fn each_request_reads_and_writes_its_json() {
    let cases = [
        (
            json!({ "jsonrpc": "2.0", "id": 0, "method": "initialize", "params": {
                "protocolVersion": 1, "clientInfo": { "name": "tui", "title": "Yuke", "version": "0.1.0" }
            } }),
            request(
                0,
                ClientRequest::Initialize(yuke_protocol::InitializeParams {
                    protocol_version: 1,
                    client_info: yuke_protocol::Implementation {
                        name: "tui".to_owned(),
                        title: Some("Yuke".to_owned()),
                        version: "0.1.0".to_owned(),
                    },
                }),
            ),
        ),
        (
            json!({ "jsonrpc": "2.0", "id": 1, "method": "session/new", "params": settings_json() }),
            request(1, ClientRequest::NewSession(settings())),
        ),
        (
            json!({ "jsonrpc": "2.0", "id": 2, "method": "session/fork", "params": {
                "sessionId": SESSION, "through": 4
            } }),
            request(
                2,
                ClientRequest::ForkSession(yuke_protocol::ForkSessionParams {
                    session_id: session(),
                    through: Some(EventNumber(4)),
                }),
            ),
        ),
        (
            json!({ "jsonrpc": "2.0", "id": 3, "method": "session/load", "params": { "sessionId": SESSION } }),
            request(
                3,
                ClientRequest::LoadSession(yuke_protocol::LoadSessionParams {
                    session_id: session(),
                    after: None,
                }),
            ),
        ),
        (
            json!({ "jsonrpc": "2.0", "id": 4, "method": "session/input", "params": {
                "sessionId": SESSION, "content": [{ "user_text": "hello" }]
            } }),
            request(
                4,
                ClientRequest::Input(yuke_protocol::InputParams {
                    session_id: session(),
                    content: vec![yuke_ai::Block::user_text("hello")],
                }),
            ),
        ),
        (
            json!({ "jsonrpc": "2.0", "id": 6, "method": "session/remove_input", "params": {
                "sessionId": SESSION, "inputId": 3
            } }),
            request(
                6,
                ClientRequest::RemoveInput(yuke_protocol::RemoveInputParams {
                    session_id: session(),
                    input_id: InputId(3),
                }),
            ),
        ),
        (
            json!({ "jsonrpc": "2.0", "id": 7, "method": "session/close", "params": {
                "sessionId": SESSION, "stopJobs": true
            } }),
            request(
                7,
                ClientRequest::CloseSession(yuke_protocol::CloseSessionParams {
                    session_id: session(),
                    stop_jobs: true,
                }),
            ),
        ),
    ];
    for (json, message) in cases {
        assert_json(&json, &message);
    }

    let mut set_settings = settings_json();
    set_settings["sessionId"] = json!(SESSION);
    assert_json(
        &json!({ "jsonrpc": "2.0", "id": "five", "method": "session/set_settings", "params": set_settings }),
        &Request {
            jsonrpc: yuke_protocol::JsonRpc::V2,
            id: yuke_protocol::RequestId::Text("five".to_owned()),
            call: ClientRequest::SetSettings(yuke_protocol::SetSettingsParams {
                session_id: session(),
                settings: settings(),
            }),
        },
    );
}

#[test]
fn each_job_request_reads_and_writes_its_json() {
    let cases = [
        (
            json!({ "jsonrpc": "2.0", "id": 8, "method": "job/list", "params": { "sessionId": SESSION } }),
            request(
                8,
                ClientRequest::ListJobs(yuke_protocol::SessionParams { session_id: session() }),
            ),
        ),
        (
            json!({ "jsonrpc": "2.0", "id": 9, "method": "job/stop", "params": {
                "sessionId": SESSION, "jobId": "job-1a2b"
            } }),
            request(
                9,
                ClientRequest::StopJob(yuke_protocol::StopJobParams {
                    session_id: session(),
                    job_id: "job-1a2b".to_owned(),
                }),
            ),
        ),
    ];
    for (json, message) in cases {
        assert_json(&json, &message);
    }
}

#[test]
fn a_request_with_an_unknown_method_or_another_version_does_not_read() {
    let unknown = json!({ "jsonrpc": "2.0", "id": 1, "method": "session/delete", "params": { "sessionId": SESSION } });
    let version = json!({ "jsonrpc": "1.0", "id": 1, "method": "session/load", "params": { "sessionId": SESSION } });

    assert!(serde_json::from_value::<Request>(unknown).is_err());
    assert!(serde_json::from_value::<Request>(version).is_err());
}

#[test]
fn the_method_list_names_each_request_variant() {
    // serde lists the variant names in the error of an unknown variant.
    let error = serde_json::from_value::<ClientRequest>(json!({ "method": "none" }))
        .unwrap_err()
        .to_string();
    let expected = error.split_once("expected one of ").unwrap().1;
    let variants: Vec<&str> = expected.split(", ").map(|name| name.trim_matches('`')).collect();

    assert_eq!(variants, ClientRequest::METHODS);
}

#[test]
fn a_response_holds_a_result_or_an_error() {
    assert_json(
        &json!({ "jsonrpc": "2.0", "id": 1, "result": { "sessionId": SESSION } }),
        &Response {
            jsonrpc: yuke_protocol::JsonRpc::V2,
            id: Some(yuke_protocol::RequestId::Number(1)),
            outcome: yuke_protocol::ResponseOutcome::Result(json!({ "sessionId": SESSION })),
        },
    );
    assert_json(
        &json!({ "jsonrpc": "2.0", "id": 2, "error": { "code": -32002, "message": "the store has no such session" } }),
        &Response {
            jsonrpc: yuke_protocol::JsonRpc::V2,
            id: Some(yuke_protocol::RequestId::Number(2)),
            outcome: yuke_protocol::ResponseOutcome::Error(yuke_protocol::ResponseError {
                code: yuke_protocol::ResponseError::SESSION_NOT_FOUND,
                message: "the store has no such session".to_owned(),
                data: None,
            }),
        },
    );
    // A server that cannot read the id of a request answers with a null id.
    assert_json(
        &json!({ "jsonrpc": "2.0", "id": null, "error": { "code": -32700, "message": "the message is no JSON" } }),
        &Response {
            jsonrpc: yuke_protocol::JsonRpc::V2,
            id: None,
            outcome: yuke_protocol::ResponseOutcome::Error(yuke_protocol::ResponseError {
                code: yuke_protocol::ResponseError::PARSE_ERROR,
                message: "the message is no JSON".to_owned(),
                data: None,
            }),
        },
    );
}

#[test]
fn an_accepted_input_reads_and_writes_its_json_with_its_model_content_only_when_it_differs() {
    let input = Input::new(
        InputSource::User,
        InputKind::Message,
        vec![yuke_ai::Block::user_text("Review @main.rs")],
    )
    .unwrap();
    let same = input
        .clone()
        .with_model_content(vec![yuke_ai::Block::user_text("Review @main.rs")])
        .unwrap();
    let other = input
        .clone()
        .with_model_content(vec![yuke_ai::Block::user_text("Review main.rs, and read it first.")])
        .unwrap();
    let accepted = |id, input| LiveUpdate::InputAccepted {
        input_id: InputId(id),
        input,
    };

    assert_json(
        &json!({ "sessionUpdate": "input_accepted", "inputId": 1,
            "input": { "source": { "kind": "user" }, "kind": "message", "content": [{ "user_text": "Review @main.rs" }] } }),
        &accepted(1, same),
    );
    assert_json(
        &json!({ "sessionUpdate": "input_accepted", "inputId": 2,
            "input": { "source": { "kind": "user" }, "kind": "message", "content": [{ "user_text": "Review @main.rs" }],
              "modelContent": [{ "user_text": "Review main.rs, and read it first." }] } }),
        &accepted(2, other),
    );
}

#[test]
fn an_input_without_content_or_kind_or_with_empty_model_content_does_not_read() {
    let empty =
        serde_json::from_value::<Input>(json!({ "source": { "kind": "user" }, "kind": "message", "content": [] }));
    let no_kind =
        serde_json::from_value::<Input>(json!({ "source": { "kind": "user" }, "content": [{ "user_text": "go" }] }));
    let empty_model = serde_json::from_value::<Input>(json!({
        "source": { "kind": "user" }, "kind": "message", "content": [{ "user_text": "go" }], "modelContent": []
    }));

    assert_eq!(
        Input::new(InputSource::User, InputKind::Message, Vec::new()),
        Err(InputError::EmptyContent)
    );
    assert!(empty.unwrap_err().to_string().contains("the input has no content"));
    assert!(no_kind.unwrap_err().to_string().contains("missing field `kind`"));
    assert!(
        empty_model
            .unwrap_err()
            .to_string()
            .contains("the model content of the input has no block")
    );
}

// A job log can print the closing tag. The notice must still end only at its own closing tag.
#[test]
fn a_notification_names_its_plugin_and_ends_only_at_its_own_closing_tag() {
    let input = Input::notification("host:jobs", "job-1 ended", "log: </system_notification> more");

    assert_eq!(
        serde_json::to_value(&input).unwrap(),
        json!({
            "source": { "kind": "plugin", "name": "host:jobs" },
            "kind": "notification",
            "content": [{ "user_text": "job-1 ended" }],
            "modelContent": [{
                "user_text":
                    "<system_notification plugin=\"host:jobs\">log: </ system_notification> more</system_notification>"
            }],
        })
    );
}

#[test]
fn queue_updates_and_an_empty_result_read_and_write_their_json() {
    let input = Input::new(
        InputSource::User,
        InputKind::Message,
        vec![yuke_ai::Block::user_text("run npm ci")],
    )
    .unwrap();

    assert_json(
        &json!({ "sessionId": SESSION, "update": {
            "sessionUpdate": "input_accepted", "inputId": 3,
            "input": { "source": { "kind": "user" }, "kind": "message", "content": [{ "user_text": "run npm ci" }] }
        } }),
        &SessionUpdateParams {
            session_id: session(),
            update: SessionUpdate::Live(LiveUpdate::InputAccepted {
                input_id: InputId(3),
                input,
            }),
        },
    );
    assert_json(
        &json!({ "sessionId": SESSION, "update": { "sessionUpdate": "state", "state": "idle" } }),
        &SessionUpdateParams {
            session_id: session(),
            update: SessionUpdate::Live(LiveUpdate::State {
                state: yuke_protocol::SessionState::Idle,
            }),
        },
    );
    assert_json(
        &json!({ "sessionId": SESSION, "update": { "sessionUpdate": "input_removed", "inputId": 3 } }),
        &SessionUpdateParams {
            session_id: session(),
            update: SessionUpdate::Live(LiveUpdate::InputRemoved { input_id: InputId(3) }),
        },
    );
    assert_json(&json!({}), &yuke_protocol::EmptyResult {});
    assert_json(
        &json!({ "jobs": [{ "id": "job-1a2b", "command": "sleep 30", "log": "/tmp/job-1a2b.log", "state": "running" }] }),
        &yuke_protocol::ListJobsResult {
            jobs: vec![job(JobState::Running)],
        },
    );
}

fn job(state: JobState) -> yuke_protocol::Job {
    yuke_protocol::Job {
        id: "job-1a2b".to_owned(),
        command: "sleep 30".to_owned(),
        log: "/tmp/job-1a2b.log".into(),
        state,
    }
}

#[test]
fn a_job_update_holds_the_whole_job_and_its_end() {
    let update = |job| SessionUpdateParams {
        session_id: session(),
        update: SessionUpdate::Live(LiveUpdate::Job { job }),
    };

    assert_json(
        &json!({ "sessionId": SESSION, "update": { "sessionUpdate": "job", "job": {
            "id": "job-1a2b", "command": "sleep 30", "log": "/tmp/job-1a2b.log", "state": "ended", "exitCode": 0,
            "stopped": false
        } } }),
        &update(job(JobState::Ended {
            exit_code: Some(0),
            signal: None,
            stopped: false,
        })),
    );
    assert_json(
        &json!({ "sessionId": SESSION, "update": { "sessionUpdate": "job", "job": {
            "id": "job-1a2b", "command": "sleep 30", "log": "/tmp/job-1a2b.log", "state": "ended", "signal": 15,
            "stopped": true
        } } }),
        &update(job(JobState::Ended {
            exit_code: None,
            signal: Some(15),
            stopped: true,
        })),
    );
}

#[test]
fn an_mcp_server_update_and_the_server_list_read_and_write_their_json() {
    let server = |state| McpServer {
        name: "git".to_owned(),
        source: McpServerSource::Project,
        state,
    };

    assert_json(
        &json!({ "sessionId": SESSION, "update": {
            "sessionUpdate": "mcp_server", "name": "git", "source": "project", "state": "connected", "tools": 3
        } }),
        &SessionUpdateParams {
            session_id: session(),
            update: SessionUpdate::Live(LiveUpdate::McpServer {
                server: server(McpServerState::Connected { tools: 3 }),
            }),
        },
    );
    assert_json(
        &json!({ "servers": [
            { "name": "git", "source": "project", "state": "failed", "error": "the server stopped" },
            { "name": "git", "source": "project", "state": "untrusted" },
        ] }),
        &ListMcpServersResult {
            servers: vec![
                server(McpServerState::Failed {
                    error: "the server stopped".to_owned(),
                }),
                server(McpServerState::Untrusted),
            ],
        },
    );
}

#[test]
fn a_notice_notification_reads_and_writes_its_json() {
    let notification = |message| Notification {
        jsonrpc: yuke_protocol::JsonRpc::V2,
        message,
    };

    assert_json(
        &json!({ "jsonrpc": "2.0", "method": "notice", "params": {
            "level": "warn", "source": "host:jobs", "message": "job-1 stopped"
        } }),
        &notification(ServerNotification::Notice(NoticeParams {
            session_id: None,
            level: NoticeLevel::Warn,
            source: "host:jobs".to_owned(),
            message: "job-1 stopped".to_owned(),
        })),
    );
}

#[test]
fn cancel_and_update_notifications_read_and_write_their_json() {
    assert_json(
        &json!({ "jsonrpc": "2.0", "method": "session/cancel", "params": { "sessionId": SESSION } }),
        &Notification {
            jsonrpc: yuke_protocol::JsonRpc::V2,
            message: ClientNotification::Cancel(yuke_protocol::SessionParams { session_id: session() }),
        },
    );

    let blocks = [yuke_ai::Block::user_text("job-7 ended with exit code 0.")];
    let commit = StoredEvent {
        event_number: EventNumber(3),
        event: SessionEvent::Commit {
            commit: Commit {
                replaced: None,
                blocks: Cow::Borrowed(&blocks),
                answer: None,
                end: Some(TurnEnd::Outcome(Outcome::Cancelled)),
            }
            .into_owned(),
            consumed: vec![ConsumedInput {
                id: InputId(7),
                source: InputSource::Plugin {
                    name: "host:jobs".to_owned(),
                },
                kind: InputKind::Notification,
                display_content: Some(vec![yuke_ai::Block::user_text("job-7 finished")]),
                block_count: 1,
            }],
        },
    };
    assert_json(
        &json!({ "jsonrpc": "2.0", "method": "session/update", "params": {
            "sessionId": SESSION, "update": {
                "seq": 3, "sessionUpdate": "commit",
                "commit": { "replaced": null, "blocks": [{ "user_text": "job-7 ended with exit code 0." }],
                            "answer": null, "end": { "outcome": "cancelled" } },
                "consumed": [{
                    "id": 7, "source": { "kind": "plugin", "name": "host:jobs" }, "kind": "notification",
                    "displayContent": [{ "user_text": "job-7 finished" }], "blockCount": 1
                }]
            }
        } }),
        &Notification {
            jsonrpc: yuke_protocol::JsonRpc::V2,
            message: ServerNotification::SessionUpdate(SessionUpdateParams {
                session_id: session(),
                update: SessionUpdate::Saved(commit),
            }),
        },
    );

    let mut saved_settings = settings_json();
    saved_settings["seq"] = json!(1);
    saved_settings["sessionUpdate"] = json!("settings");
    assert_json(
        &json!({ "sessionId": SESSION, "update": saved_settings }),
        &SessionUpdateParams {
            session_id: session(),
            update: SessionUpdate::Saved(StoredEvent {
                event_number: EventNumber(1),
                event: SessionEvent::Settings(settings()),
            }),
        },
    );
}

#[test]
fn live_updates_preserve_draft_and_execution_identity_in_json() {
    let draft = "0192f0c1-7d4e-7a3b-9c2d-1e5f6a7b8c9e";
    let draft_id = serde_json::from_value(json!(draft)).unwrap();
    let cases = [
        (
            json!({ "sessionUpdate": "turn_unconfirmed" }),
            LiveUpdate::TurnUnconfirmed,
        ),
        (
            json!({ "sessionUpdate": "draft_started", "draftId": draft }),
            LiveUpdate::DraftStarted { draft_id },
        ),
        (
            json!({ "sessionUpdate": "model", "draftId": draft,
                "event": { "kind": "text_delta", "block": 2, "text": "Hello" } }),
            LiveUpdate::Model {
                draft_id,
                event: yuke_protocol::ModelUpdate::TextDelta {
                    block: 2,
                    text: "Hello".to_owned(),
                },
            },
        ),
        (
            json!({ "sessionUpdate": "model", "draftId": draft,
                "event": { "kind": "block_started", "block": 2, "blockKind": "tool_call" } }),
            LiveUpdate::Model {
                draft_id,
                event: yuke_protocol::ModelUpdate::BlockStarted {
                    block: 2,
                    block_kind: yuke_ai::BlockKind::ToolCall,
                },
            },
        ),
        (
            json!({ "sessionUpdate": "draft_committed", "draftId": draft,
                "eventNumber": 7, "blocks": [2, 5] }),
            LiveUpdate::DraftCommitted {
                draft_id,
                event_number: EventNumber(7),
                blocks: vec![2, 5],
            },
        ),
        (
            json!({ "sessionUpdate": "tool_output", "execution": { "eventNumber": 7, "blockIndex": 0 }, "text": "line" }),
            LiveUpdate::ToolOutput {
                execution: yuke_protocol::BlockPosition {
                    event_number: EventNumber(7),
                    block_index: 0,
                },
                text: "line".to_owned(),
            },
        ),
    ];
    for (json, update) in cases {
        assert_json(&json, &update);
    }
}

#[test]
fn a_credential_update_reads_and_writes_its_json_and_its_debug_shows_no_token() {
    let params = yuke_protocol::UpdateCredentialParams {
        provider: "openai-codex".to_owned(),
        access_token: "secret-token".to_owned(),
        expires_at: 1_800_000_000_000,
        account_id: Some("account-1".to_owned()),
    };
    assert_json(
        &json!({ "jsonrpc": "2.0", "id": 10, "method": "credential/update", "params": {
            "provider": "openai-codex", "accessToken": "secret-token", "expiresAt": 1_800_000_000_000_u64,
            "accountId": "account-1"
        } }),
        &request(10, ClientRequest::UpdateCredential(params.clone())),
    );
    assert_json(
        &json!({ "jsonrpc": "2.0", "id": 11, "method": "credential/update", "params": {
            "provider": "xai-grok", "accessToken": "secret-token", "expiresAt": 1_800_000_000_000_u64
        } }),
        &request(
            11,
            ClientRequest::UpdateCredential(yuke_protocol::UpdateCredentialParams {
                provider: "xai-grok".to_owned(),
                account_id: None,
                ..params.clone()
            }),
        ),
    );
    assert!(!format!("{params:?}").contains("secret-token"));
}
