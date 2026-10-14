//! The JSON of each message: it reads from a hand-written example in the style of the Agent Client Protocol, and it
//! writes the same JSON back.
#![expect(clippy::unwrap_used, reason = "a test fails by panicking")]

use std::borrow::Cow;

use serde::Serialize;
use serde::de::DeserializeOwned;
use serde_json::{Value, json};
use yuke_engine::{Commit, Outcome, TurnEnd};
use yuke_protocol::{
    ClientNotification, ClientRequest, EventNumber, InputId, LiveUpdate, ModelReference, Notification, Request,
    Response, ServerNotification, SessionEvent, SessionId, SessionSettings, SessionUpdate, SessionUpdateParams,
    StoredEvent,
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
            "system": "", "maxOutputTokens": null, "reasoning": { "thinking": null, "effort": null },
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
        jsonrpc: yuke_protocol::JsonRpc,
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
            request(
                1,
                ClientRequest::NewSession(yuke_protocol::NewSessionParams { settings: settings() }),
            ),
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
                "sessionId": SESSION, "blocks": [{ "user_text": "hello" }]
            } }),
            request(
                4,
                ClientRequest::Input(yuke_protocol::InputParams {
                    session_id: session(),
                    blocks: vec![yuke_ai::Block::user_text("hello")],
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
            jsonrpc: yuke_protocol::JsonRpc,
            id: yuke_protocol::RequestId::Text("five".to_owned()),
            call: ClientRequest::SetSettings(yuke_protocol::SetSettingsParams {
                session_id: session(),
                settings: settings(),
            }),
        },
    );
}

#[test]
fn a_request_with_an_unknown_method_or_another_version_does_not_read() {
    let unknown = json!({ "jsonrpc": "2.0", "id": 1, "method": "session/delete", "params": { "sessionId": SESSION } });
    let version = json!({ "jsonrpc": "1.0", "id": 1, "method": "session/load", "params": { "sessionId": SESSION } });

    assert!(serde_json::from_value::<Request>(unknown).is_err());
    assert!(serde_json::from_value::<Request>(version).is_err());
}

#[test]
fn a_response_holds_a_result_or_an_error() {
    assert_json(
        &json!({ "jsonrpc": "2.0", "id": 1, "result": { "sessionId": SESSION } }),
        &Response {
            jsonrpc: yuke_protocol::JsonRpc,
            id: Some(yuke_protocol::RequestId::Number(1)),
            outcome: yuke_protocol::ResponseOutcome::Result(json!({ "sessionId": SESSION })),
        },
    );
    assert_json(
        &json!({ "jsonrpc": "2.0", "id": 2, "error": { "code": -32002, "message": "the store has no such session" } }),
        &Response {
            jsonrpc: yuke_protocol::JsonRpc,
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
            jsonrpc: yuke_protocol::JsonRpc,
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
fn cancel_and_update_notifications_read_and_write_their_json() {
    assert_json(
        &json!({ "jsonrpc": "2.0", "method": "session/cancel", "params": { "sessionId": SESSION } }),
        &Notification {
            jsonrpc: yuke_protocol::JsonRpc,
            message: ClientNotification::Cancel(yuke_protocol::CancelParams { session_id: session() }),
        },
    );

    let blocks = [yuke_ai::Block::assistant_text("done")];
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
            consumed: vec![InputId(7)],
        },
    };
    assert_json(
        &json!({ "jsonrpc": "2.0", "method": "session/update", "params": {
            "sessionId": SESSION, "update": {
                "seq": 3, "sessionUpdate": "commit",
                "commit": { "replaced": null, "blocks": [{ "assistant_text": "done" }], "answer": null,
                            "end": { "outcome": "cancelled" } },
                "consumed": [7]
            }
        } }),
        &Notification {
            jsonrpc: yuke_protocol::JsonRpc,
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
