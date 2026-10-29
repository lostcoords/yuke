//! The requests of plugins to the client: an answer, an error, a cancel, a session close, and a new client.

use super::*;

/// A plugin `boarhat` whose tool `read_session` sends `session.read` and answers with the title of the result, or with the
/// failure.
const READER: &str = "import { ExtensionRequestError } from 'yuke:plugins';
   export function session(s) {
     s.tools.define({
       name: 'read_session', description: 'Read a session.', concurrency: 'serial',
       parameters: { type: 'object', properties: {} },
       async execute(_args, { signal }) {
         try {
           const found = await s.request('session.read', { id: 'S-42' }, { signal });
           return `title: ${found.title}`;
         } catch (error) {
           if (error instanceof ExtensionRequestError) return `refused ${error.code} ${error.message} ${error.data.reason}`;
           return `failed ${error.name}: ${error.message}`;
         }
       },
     });
   }";

/// A client with the plugin of `source` as `boarhat`, a model that calls `read_session` once, and a session.
async fn reader(name: &str, source: &str) -> (ScriptedTransport, Client, Value) {
    let place = Place::new("rpc", name);
    place.plugin("boarhat", source);
    std::fs::write(place.paths.config.join("config.json"), r#"{ "plugins": ["boarhat"] }"#).unwrap();
    let transport = ScriptedTransport::new([tool_reply(&[("c1", "read_session", "{}")]), text_reply("done")]);
    let mut client = Client::initialized(&place, Box::new(transport.clone())).await;
    let session = client.call("session/new", settings(&place)).await.unwrap()["sessionId"].clone();
    (transport, client, session)
}

fn is_request(message: &Value) -> bool {
    message["method"] == "extension/request"
}

#[tokio::test]
async fn a_client_answer_becomes_the_tool_result_of_a_plugin_request() {
    let (transport, mut client, session) =
        reader("a_client_answer_becomes_the_tool_result_of_a_plugin_request", READER).await;

    client
        .request("session/input", input_params(&session, "read S-42"))
        .await;
    let request = client.until(is_request).await.pop().unwrap();
    let answer = json!({ "jsonrpc": "2.0", "id": request["id"], "result": { "title": "fix the login" } });
    client.write(&answer.to_string()).await;
    let after = client.until(is_idle).await;

    assert_eq!(
        request["params"],
        json!({ "sessionId": session, "extension": "boarhat", "request": "session.read", "data": { "id": "S-42" } })
    );
    // An answer gets no response.
    assert!(after.iter().all(|message| message.get("error").is_none()), "{after:?}");
    assert!(
        transport.requests()[1].contains("title: fix the login"),
        "{}",
        transport.requests()[1]
    );
    client.end().await;
}

#[tokio::test]
async fn a_client_error_rejects_the_plugin_request_with_its_code_and_data() {
    let (transport, mut client, session) = reader(
        "a_client_error_rejects_the_plugin_request_with_its_code_and_data",
        READER,
    )
    .await;

    client
        .request("session/input", input_params(&session, "read S-42"))
        .await;
    let request = client.until(is_request).await.pop().unwrap();
    let error = json!({ "code": -32001, "message": "no such session", "data": { "reason": "deleted" } });
    client
        .write(&json!({ "jsonrpc": "2.0", "id": request["id"], "error": error }).to_string())
        .await;
    client.until(is_idle).await;

    assert!(
        transport.requests()[1].contains("refused -32001 no such session deleted"),
        "{}",
        transport.requests()[1]
    );
    client.end().await;
}

#[tokio::test]
async fn a_cancelled_plugin_request_sends_a_cancel_and_drops_the_late_answer() {
    let (transport, mut client, session) = reader(
        "a_cancelled_plugin_request_sends_a_cancel_and_drops_the_late_answer",
        READER,
    )
    .await;

    client
        .request("session/input", input_params(&session, "read S-42"))
        .await;
    let request = client.until(is_request).await.pop().unwrap();
    client.notify("session/cancel", json!({ "sessionId": session })).await;
    let mut ended = client.until(is_idle).await;
    if !ended.iter().any(|message| message["method"] == "extension/cancel") {
        ended.extend(client.until(|message| message["method"] == "extension/cancel").await);
    }
    let late = json!({ "jsonrpc": "2.0", "id": request["id"], "result": { "title": "too late" } });
    client.write(&late.to_string()).await;
    let id = client.request("job/list", json!({ "sessionId": session })).await;
    let after = client.until(|message| is_response(message, id)).await;

    let cancels: Vec<&Value> = ended
        .iter()
        .filter(|message| message["method"] == "extension/cancel")
        .collect();
    assert_eq!(cancels.len(), 1, "{ended:?}");
    assert_eq!(cancels[0]["params"], json!({ "requestId": request["id"] }));
    assert_eq!(after.len(), 1, "{after:?}");
    assert_eq!(after[0]["result"], json!({ "jobs": [] }));
    // The cancelled turn sends no second model request.
    assert_eq!(transport.requests().len(), 1);
    client.end().await;
}

#[tokio::test]
async fn a_closed_session_cancels_its_pending_requests() {
    let place = Place::new("rpc", "a_closed_session_cancels_its_pending_requests");
    place.plugin(
        "watcher",
        "export function session(s) {
           s.request('watch', null).catch((error) => s.emit('ended', error.name));
         }",
    );
    std::fs::write(place.paths.config.join("config.json"), r#"{ "plugins": ["watcher"] }"#).unwrap();
    let mut client = Client::initialized(&place, Box::new(ScriptedTransport::default())).await;
    // The request of the session setup can come before or after the response.
    let id = client.request("session/new", settings(&place)).await;
    let mut opened: Vec<Value> = Vec::new();
    while !(opened.iter().any(|message| is_response(message, id)) && opened.iter().any(is_request)) {
        opened.push(client.next().await);
    }
    let session = opened.iter().find(|message| is_response(message, id)).unwrap()["result"]["sessionId"].clone();
    let request = opened.iter().find(|message| is_request(message)).unwrap();
    client
        .request("session/close", json!({ "sessionId": session, "stopJobs": false }))
        .await;
    let mut seen = Vec::new();
    while !(seen
        .iter()
        .any(|message: &Value| message["method"] == "extension/cancel")
        && seen
            .iter()
            .any(|message: &Value| message["method"] == "extension/event"))
    {
        seen.push(client.next().await);
    }

    let cancel = seen
        .iter()
        .find(|message| message["method"] == "extension/cancel")
        .unwrap();
    let ended = seen
        .iter()
        .find(|message| message["method"] == "extension/event")
        .unwrap();
    assert_eq!(cancel["params"], json!({ "requestId": request["id"] }));
    assert_eq!(ended["params"]["data"], "AbortError");
    client.end().await;
}

#[tokio::test]
async fn a_new_client_fails_the_requests_of_the_old_one() {
    let place = Place::new("rpc", "a_new_client_fails_the_requests_of_the_old_one");
    place.plugin("boarhat", READER);
    std::fs::write(place.paths.config.join("config.json"), r#"{ "plugins": ["boarhat"] }"#).unwrap();
    let transport = ScriptedTransport::new([tool_reply(&[("c1", "read_session", "{}")]), text_reply("done")]);
    let listening = Listening::start(&place, Box::new(transport.clone()));
    let mut first = listening.client().await;
    first.initialize().await;
    let session = first.call("session/new", settings(&place)).await.unwrap()["sessionId"].clone();
    first
        .request("session/input", input_params(&session, "read S-42"))
        .await;
    first.until(is_request).await;

    let mut second = listening.client().await;
    second.initialize().await;
    let loaded = second.load(&session, json!({})).await;
    if loaded.state == "running" {
        second.until(is_idle).await;
    }

    assert!(
        transport.requests()[1].contains("failed Error: the client disconnected before its answer"),
        "{}",
        transport.requests()[1]
    );
    listening.stop().await;
}
