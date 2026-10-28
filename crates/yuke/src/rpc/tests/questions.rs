//! Questions of plugins: the ask, the answer of the client, and a question across a close and a load.

use super::*;

// The tool waits for the user. A wrong answer leaves the question open, and the answer reaches the model.
#[tokio::test]
async fn a_plugin_asks_the_user_and_the_answer_of_the_client_reaches_its_tool() {
    let place = Place::new(
        "rpc",
        "a_plugin_asks_the_user_and_the_answer_of_the_client_reaches_its_tool",
    );
    place.plugin(
        "deploy",
        "export function session(s) {
           s.tools.define({
             name: 'deploy', description: 'Deploy.', concurrency: 'serial',
             parameters: { type: 'object', properties: {} },
             async execute(_args, { signal }) {
               return `deployed to ${await s.select('Deploy to?', ['staging', 'production'], { signal })}`;
             },
           });
         }",
    );
    std::fs::write(place.paths.config.join("config.json"), r#"{ "plugins": ["deploy"] }"#).unwrap();
    let transport = ScriptedTransport::new([tool_reply(&[("c1", "deploy", "{}")]), text_reply("done")]);
    let mut client = Client::initialized(&place, Box::new(transport.clone())).await;
    let session = client.call("session/new", settings(&place)).await.unwrap()["sessionId"].clone();

    client
        .request("session/input", input_params(&session, "deploy it"))
        .await;
    let asked = client.until(is_question).await.pop().unwrap();
    let answer = |value: &str| json!({ "sessionId": session, "interactionId": 1, "response": { "kind": "select", "value": value } });
    let wrong = client.call("interaction/respond", answer("local")).await;
    let id = client.request("interaction/respond", answer("production")).await;
    let answered = client.until(|message| message["id"] == json!(id)).await;
    client.until(is_idle).await;
    let late = client.call("interaction/respond", answer("staging")).await;

    assert_eq!(
        asked["params"]["update"],
        json!({
            "sessionUpdate": "interaction_requested",
            "interactionId": 1,
            "source": "deploy",
            "request": { "kind": "select", "title": "Deploy to?", "options": ["staging", "production"] },
        })
    );
    assert_eq!(wrong.unwrap_err()["code"], -32_602);
    let closed = json!({ "sessionUpdate": "interaction_closed", "interactionId": 1 });
    assert_eq!(answered[answered.len() - 2]["params"]["update"], closed, "{answered:?}");
    assert_eq!(answered.last().unwrap()["result"], json!({}));
    assert!(
        transport.requests()[1].contains("deployed to production"),
        "{}",
        transport.requests()[1]
    );
    assert_eq!(late.unwrap_err()["code"], -32_005);
    client.end().await;
}

// A load sends the open question again, and an answer after the load ends the wait.
#[tokio::test]
async fn a_load_sends_an_open_question_again() {
    let place = Place::new("rpc", "a_load_sends_an_open_question_again");
    place.plugin(
        "keeper",
        "export function session(s) {
           s.tools.define({
             name: 'keep', description: 'Keep.', concurrency: 'serial',
             parameters: { type: 'object', properties: {} },
             execute: async (_args, { signal }) => `kept: ${await s.confirm('Keep the branch?', 'It has no merge.', { signal })}`,
           });
         }",
    );
    std::fs::write(place.paths.config.join("config.json"), r#"{ "plugins": ["keeper"] }"#).unwrap();
    let transport = ScriptedTransport::new([tool_reply(&[("c1", "keep", "{}")]), text_reply("done")]);
    let mut client = Client::initialized(&place, Box::new(transport.clone())).await;
    let session = client.call("session/new", settings(&place)).await.unwrap()["sessionId"].clone();
    client.request("session/input", input_params(&session, "keep it")).await;
    client.until(is_question).await;

    let loaded = client.load(&session, json!({})).await;
    let answer = json!({ "sessionId": session, "interactionId": 1, "response": { "kind": "confirm", "value": true } });
    client.call("interaction/respond", answer).await.unwrap();
    client.until(is_idle).await;

    let questions: Vec<&Value> = loaded
        .messages
        .iter()
        .map(|message| &message["params"]["update"])
        .filter(|update| update["sessionUpdate"] == "interaction_requested")
        .collect();
    assert_eq!(
        questions,
        [&json!({
            "sessionUpdate": "interaction_requested",
            "interactionId": 1,
            "source": "keeper",
            "request": { "kind": "confirm", "title": "Keep the branch?", "message": "It has no merge." },
        })]
    );
    assert!(
        transport.requests()[1].contains("kept: true"),
        "{}",
        transport.requests()[1]
    );
    client.end().await;
}

// The close ends the question. After a load, the next question has a new id, so an old answer finds nothing.
#[tokio::test]
async fn a_question_after_a_close_and_a_load_has_a_new_id() {
    let place = Place::new("rpc", "a_question_after_a_close_and_a_load_has_a_new_id");
    place.plugin(
        "keeper",
        "export function session(s) {
           s.tools.define({
             name: 'keep', description: 'Keep.', concurrency: 'serial',
             parameters: { type: 'object', properties: {} },
             execute: async (_args, { signal }) => `kept: ${await s.confirm('Keep the branch?', '', { signal })}`,
           });
         }",
    );
    std::fs::write(place.paths.config.join("config.json"), r#"{ "plugins": ["keeper"] }"#).unwrap();
    let transport = ScriptedTransport::new([
        tool_reply(&[("c1", "keep", "{}")]),
        tool_reply(&[("c2", "keep", "{}")]),
        text_reply("done"),
    ]);
    let mut client = Client::initialized(&place, Box::new(transport.clone())).await;
    let session = client.call("session/new", settings(&place)).await.unwrap()["sessionId"].clone();
    client.request("session/input", input_params(&session, "keep it")).await;
    client.until(is_question).await;

    client
        .call("session/close", json!({ "sessionId": session, "stopJobs": false }))
        .await
        .unwrap();
    client.load(&session, json!({})).await;
    client
        .request("session/input", input_params(&session, "keep it again"))
        .await;
    let asked = client.until(is_question).await.pop().unwrap();
    let answer = |id: u64| json!({ "sessionId": session, "interactionId": id, "response": { "kind": "confirm", "value": true } });
    let old = client.call("interaction/respond", answer(1)).await;
    let new = client.call("interaction/respond", answer(2)).await;

    assert_eq!(asked["params"]["update"]["interactionId"], 2);
    assert_eq!(old.unwrap_err()["code"], -32_005);
    assert!(new.is_ok(), "{new:?}");
    client.end().await;
}
