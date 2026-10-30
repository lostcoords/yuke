//! MCP servers of the user and of the project: their start, their tools, their state, and the trust of the project.

use super::*;

fn mcp_state(message: &Value, name: &str, state: &str) -> bool {
    let update = &message["params"]["update"];
    update["sessionUpdate"] == "mcp_server" && update["name"] == name && update["state"] == state
}

// A server of the user config starts with the session: its state reaches the client, its tool reaches the model, and
// `mcp/list` and a load give its state.
#[tokio::test]
async fn a_user_mcp_server_gives_its_tool_to_the_model_and_its_state_to_the_client() {
    let place = Place::new(
        "rpc",
        "a_user_mcp_server_gives_its_tool_to_the_model_and_its_state_to_the_client",
    );
    let script = Path::new(env!("CARGO_MANIFEST_DIR")).join("src/rpc/mcp_server.sh");
    let config = json!({ "mcpServers": {
        "sh": { "command": "sh", "args": [script] },
        "off": { "command": "sh", "enabled": false },
    } });
    std::fs::create_dir_all(&place.paths.config).unwrap();
    std::fs::write(place.paths.config.join("mcp.json"), config.to_string()).unwrap();
    // The tool is deferred, so the model calls it through the bridge.
    let call = r#"{"name":"mcp__sh__ping","arguments":{}}"#;
    let transport = ScriptedTransport::new([tool_reply(&[("c1", "tool_call", call)]), text_reply("done")]);
    let mut client = Client::initialized(&place, Box::new(transport.clone())).await;
    let id = client.request("session/new", settings(&place)).await;
    let opened = client.until(|message| message["id"] == json!(id)).await;
    let session = opened.last().unwrap()["result"]["sessionId"].clone();

    let started = if opened.iter().any(|message| mcp_state(message, "sh", "connected")) {
        Vec::new()
    } else {
        client.until(|message| mcp_state(message, "sh", "connected")).await
    };
    client.request("session/input", input_params(&session, "ping it")).await;
    client.until(is_idle).await;
    let listed = client.call("mcp/list", json!({ "sessionId": session })).await.unwrap();
    let loaded = client.load(&session, json!({})).await;

    let servers = json!([
        { "name": "off", "source": "user", "state": "disabled" },
        { "name": "sh", "source": "user", "state": "connected", "tools": 1 },
    ]);
    assert_eq!(listed, json!({ "servers": servers }));
    let replayed: Vec<Value> = loaded
        .messages
        .iter()
        .map(|message| &message["params"]["update"])
        .filter(|update| update["sessionUpdate"] == "mcp_server")
        .map(|update| json!({ "name": update["name"], "state": update["state"], "tools": update["tools"] }))
        .collect();
    assert_eq!(
        replayed,
        [
            json!({ "name": "off", "state": "disabled", "tools": null }),
            json!({ "name": "sh", "state": "connected", "tools": 1 }),
        ]
    );
    assert!(
        opened
            .iter()
            .chain(&started)
            .any(|message| mcp_state(message, "sh", "connected"))
    );
    let requests = transport.requests();
    assert!(
        // The prompt names the tool, but the first request does not declare it.
        !requests[0].contains("\"mcp__sh__ping\"")
            && requests[0].contains("- mcp__sh__ping")
            && requests[0].contains("tool_search"),
        "{}",
        requests[0]
    );
    assert!(requests[1].contains("pong"), "{}", requests[1]);
    client.end().await;
}

/// Write `.mcp.json` in the folder of `place`: the sh server as the project server `proj`, with the extra arguments
/// `extra`.
fn project_servers(place: &Place, extra: &[&str]) -> String {
    let script = Path::new(env!("CARGO_MANIFEST_DIR")).join("src/rpc/mcp_server.sh");
    let script = script.to_str().unwrap().to_owned();
    let args: Vec<&str> = std::iter::once(script.as_str()).chain(extra.iter().copied()).collect();
    let config = json!({ "mcpServers": { "proj": { "command": "sh", "args": args } } });
    std::fs::write(place.work.join(".mcp.json"), config.to_string()).unwrap();
    format!("- proj: sh {}", args.join(" "))
}

/// Open a new session in the folder of `place`, and wait for its question about the project servers. Answer the id of
/// the session and the question.
async fn opened_with_question(client: &mut Client, place: &Place) -> (Value, Value) {
    let id = client.request("session/new", settings(place)).await;
    let mut messages = client.until(is_question).await;
    if !messages.iter().any(|message| message["id"] == json!(id)) {
        messages.extend(client.until(|message| message["id"] == json!(id)).await);
    }
    let session = messages.iter().find(|message| message["id"] == json!(id)).unwrap()["result"]["sessionId"].clone();
    let question = messages.into_iter().find(is_question).unwrap()["params"]["update"].clone();
    (session, question)
}

fn answer(session: &Value, question: &Value, value: bool) -> Value {
    json!({
        "sessionId": session,
        "interactionId": question["interactionId"],
        "response": { "kind": "confirm", "value": value },
    })
}

// A yes starts the project server and keeps the trust, so the next session in the folder asks nothing. A changed list
// asks again.
#[tokio::test]
async fn a_project_mcp_server_starts_after_a_yes_and_the_trust_lasts_until_the_list_changes() {
    let place = Place::new(
        "rpc",
        "a_project_mcp_server_starts_after_a_yes_and_the_trust_lasts_until_the_list_changes",
    );
    let line = project_servers(&place, &[]);
    let mut client = Client::initialized(&place, Box::new(ScriptedTransport::new([]))).await;

    let (first, question) = opened_with_question(&mut client, &place).await;
    client
        .call("interaction/respond", answer(&first, &question, true))
        .await
        .unwrap();
    client.until(|message| mcp_state(message, "proj", "connected")).await;
    let id = client.request("session/new", settings(&place)).await;
    let mut second = client.until(|message| message["id"] == json!(id)).await;
    let second_id = second.last().unwrap()["result"]["sessionId"].clone();
    let connected =
        |message: &Value| message["params"]["sessionId"] == second_id && mcp_state(message, "proj", "connected");
    if !second.iter().any(connected) {
        second.extend(client.until(connected).await);
    }
    project_servers(&place, &["changed"]);
    let (_third, asked_again) = opened_with_question(&mut client, &place).await;

    assert_eq!(question["source"], "host:mcp");
    assert_eq!(question["request"]["kind"], "confirm");
    assert_eq!(question["request"]["title"], "Start the MCP servers of this project?");
    let message = question["request"]["message"].as_str().unwrap();
    assert!(
        message.ends_with(&format!("has these MCP servers. Each runs on this computer.\n{line}")),
        "{message}"
    );
    assert!(!second.iter().any(is_question), "{second:?}");
    assert!(
        asked_again["request"]["message"].as_str().unwrap().ends_with("changed"),
        "{asked_again}"
    );
    let kept = std::fs::read_dir(place.paths.data.join("mcp-trust")).unwrap().count();
    assert_eq!(kept, 1);
    client.end().await;
}

// A no leaves the project server untrusted, and the next session asks again.
#[tokio::test]
async fn a_no_leaves_a_project_mcp_server_untrusted_and_the_next_session_asks_again() {
    let place = Place::new(
        "rpc",
        "a_no_leaves_a_project_mcp_server_untrusted_and_the_next_session_asks_again",
    );
    project_servers(&place, &[]);
    let mut client = Client::initialized(&place, Box::new(ScriptedTransport::new([]))).await;

    let (session, question) = opened_with_question(&mut client, &place).await;
    client
        .call("interaction/respond", answer(&session, &question, false))
        .await
        .unwrap();
    let listed = client.call("mcp/list", json!({ "sessionId": session })).await.unwrap();
    let (_next, asked_again) = opened_with_question(&mut client, &place).await;

    assert_eq!(
        listed,
        json!({ "servers": [{ "name": "proj", "source": "project", "state": "untrusted" }] })
    );
    assert_eq!(
        asked_again["request"]["title"],
        "Start the MCP servers of this project?"
    );
    assert!(!place.paths.data.join("mcp-trust").exists());
    client.end().await;
}
