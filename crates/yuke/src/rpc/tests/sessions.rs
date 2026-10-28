//! Sessions: turns, loads, settings, prompts, notices, lists, and removes.

use super::*;

#[tokio::test]
async fn an_input_starts_a_turn_and_the_client_sees_its_updates_in_order() {
    let place = Place::new("rpc", "an_input_starts_a_turn_and_the_client_sees_its_updates_in_order");
    let transport = ScriptedTransport::new([text_reply("hello")]);
    let mut client = Client::initialized(&place, Box::new(transport.clone())).await;
    let session = client.call("session/new", settings(&place)).await.unwrap()["sessionId"].clone();

    client.request("session/input", input_params(&session, "hi")).await;
    let messages = client.until(is_idle).await;

    let labels: Vec<String> = messages.iter().filter_map(label).collect();
    assert_eq!(
        labels,
        [
            "input_accepted",
            "response",
            "state running",
            "saved 2",
            "draft_started",
            "saved 3",
            "draft_committed",
            "saved 4",
            "state idle"
        ]
    );
    assert_eq!(messages[1]["result"], json!({ "inputId": 1 }));
    assert!(
        transport.requests()[0].contains("\"hi\""),
        "{}",
        transport.requests()[0]
    );
    client.end().await;
}

#[tokio::test]
async fn a_load_sends_the_saved_events_then_the_state_then_an_empty_answer() {
    let place = Place::new(
        "rpc",
        "a_load_sends_the_saved_events_then_the_state_then_an_empty_answer",
    );
    let mut client = Client::initialized(&place, Box::new(ScriptedTransport::new([text_reply("hello")]))).await;
    let session = client.call("session/new", settings(&place)).await.unwrap()["sessionId"].clone();
    client.request("session/input", input_params(&session, "hi")).await;
    client.until(is_idle).await;

    let loaded = client.load(&session, json!({})).await;

    let numbers: Vec<&Value> = loaded
        .messages
        .iter()
        .filter_map(|message| message["params"]["update"].get("seq"))
        .collect();
    assert_eq!(numbers, [&json!(1), &json!(2), &json!(3), &json!(4)]);
    let state = &loaded.messages[loaded.messages.len() - 2];
    assert_eq!(label(state).unwrap(), "state idle");
    assert_eq!((loaded.pending, loaded.jobs), (Vec::new(), Vec::new()));
    client.end().await;
}

#[tokio::test]
async fn a_running_session_refuses_new_settings_and_a_cancel_ends_its_turn() {
    let place = Place::new(
        "rpc",
        "a_running_session_refuses_new_settings_and_a_cancel_ends_its_turn",
    );
    let mut client = Client::initialized(&place, Box::new(Stalled)).await;
    let session = client.call("session/new", settings(&place)).await.unwrap()["sessionId"].clone();
    client.request("session/input", input_params(&session, "hi")).await;
    client
        .until(|message| message["params"]["update"]["state"] == "running")
        .await;

    let mut settings = settings(&place);
    settings["sessionId"] = session.clone();
    let refused = client.call("session/set_settings", settings).await;
    client.notify("session/cancel", json!({ "sessionId": session })).await;
    let messages = client.until(is_idle).await;

    let refused = refused.unwrap_err();
    assert_eq!(refused["code"], json!(ResponseError::INVALID_REQUEST));
    let end = messages
        .iter()
        .rev()
        .find_map(|message| message["params"]["update"]["commit"]["end"].as_object())
        .unwrap();
    assert_eq!(end["outcome"], "cancelled");
    client.end().await;
}

#[tokio::test]
async fn the_server_builds_the_prompt_of_a_new_session_from_its_folder() {
    let place = Place::new("rpc", "the_server_builds_the_prompt_of_a_new_session_from_its_folder");
    let mut client = Client::initialized(&place, Box::new(ScriptedTransport::default())).await;

    let session = client.call("session/new", settings(&place)).await.unwrap()["sessionId"].clone();

    let id: SessionId = serde_json::from_value(session).unwrap();
    let prompt = place.store().await.open(id, Access::Read).await.unwrap().prompt;
    let prompt = yuke_agent::prompt_text(&prompt);
    assert!(prompt.starts_with("You are yuke"), "{prompt}");
    assert!(prompt.contains(place.work.to_str().unwrap()), "{prompt}");
    client.end().await;
}

#[tokio::test]
async fn a_regular_file_is_no_folder_for_a_new_session_or_new_settings() {
    let place = Place::new("rpc", "a_regular_file_is_no_folder_for_a_new_session_or_new_settings");
    let mut client = Client::initialized(&place, Box::new(ScriptedTransport::default())).await;
    let file = place.work.join("notes.txt");
    std::fs::write(&file, "notes").unwrap();
    let session = client.call("session/new", settings(&place)).await.unwrap()["sessionId"].clone();
    let mut new = settings(&place);
    new["cwd"] = json!(file);
    let mut changed = settings(&place);
    changed["sessionId"] = session;
    changed["cwd"] = json!(file);

    let created = client.call("session/new", new).await;
    let refused = client.call("session/set_settings", changed).await;

    for error in [created.unwrap_err(), refused.unwrap_err()] {
        assert_eq!(error["code"], json!(ResponseError::INVALID_PARAMS), "{error}");
        assert!(error["message"].as_str().unwrap().ends_with("not a folder"), "{error}");
    }
    client.end().await;
}

#[tokio::test]
async fn process_and_session_notices_reach_the_client_and_a_failed_load_sends_a_notice() {
    let place = Place::new(
        "rpc",
        "process_and_session_notices_reach_the_client_and_a_failed_load_sends_a_notice",
    );
    place.plugin("broken", "export function apply() { throw new Error('no luck'); }");
    place.plugin(
        "loud",
        "export function apply(ctx) { ctx.notify('info', 'hello'); }
         export function session(s) { s.notify('info', `opened in ${s.folder}`); }",
    );
    std::fs::write(
        place.paths.config.join("config.json"),
        r#"{ "plugins": ["loud", "broken"] }"#,
    )
    .unwrap();
    let mut client = Client::start(&place, Box::new(ScriptedTransport::default()));

    let hello = client
        .until(|message| message["method"] == "notice")
        .await
        .pop()
        .unwrap();
    let notice = client
        .until(|message| message["method"] == "notice")
        .await
        .pop()
        .unwrap();
    client.initialize().await;
    // The notice of the new session can come before or after the response.
    let id = client.request("session/new", settings(&place)).await;
    let mut messages: Vec<Value> = Vec::new();
    while !(messages.iter().any(|message| message["id"] == json!(id))
        && messages.iter().any(|message| message["method"] == "notice"))
    {
        messages.push(client.next().await);
    }
    let session = &messages.iter().find(|message| message["id"] == json!(id)).unwrap()["result"]["sessionId"];
    let opened = messages.iter().find(|message| message["method"] == "notice").unwrap();

    assert_eq!(
        hello["params"],
        json!({
            "level": "info",
            "source": "loud",
            "message": "hello",
        })
    );
    assert_eq!(
        opened["params"],
        json!({
            "sessionId": session,
            "level": "info",
            "source": "loud",
            "message": format!("opened in {}", std::fs::canonicalize(&place.work).unwrap().display()),
        })
    );
    assert_eq!(notice["params"]["level"], "error");
    assert_eq!(notice["params"]["source"], "host:yuke");
    let message = notice["params"]["message"].as_str().unwrap();
    assert!(
        message.starts_with("plugin broken did not load: Error: no luck"),
        "{message}"
    );
    client.end().await;
}

#[tokio::test]
async fn a_request_before_initialize_an_unknown_method_and_no_json_get_errors() {
    let place = Place::new(
        "rpc",
        "a_request_before_initialize_an_unknown_method_and_no_json_get_errors",
    );
    let mut client = Client::start(&place, Box::new(ScriptedTransport::default()));

    let early = client.call("session/new", settings(&place)).await;
    client.initialize().await;
    let unknown = client.call("session/delete", json!({})).await;
    let session = client.call("session/new", settings(&place)).await.unwrap()["sessionId"].clone();
    let bad_block = client
        .call(
            "session/input",
            json!({ "sessionId": session, "content": [{ "session/input": "hi" }] }),
        )
        .await;
    client.write("{ no json").await;
    let broken = client.next().await;

    assert_eq!(early.unwrap_err()["code"], json!(ResponseError::INVALID_REQUEST));
    assert_eq!(unknown.unwrap_err()["code"], json!(ResponseError::METHOD_NOT_FOUND));
    assert_eq!(bad_block.unwrap_err()["code"], json!(ResponseError::INVALID_PARAMS));
    assert_eq!(broken["id"], Value::Null);
    assert_eq!(broken["error"]["code"], json!(ResponseError::PARSE_ERROR));
    client.end().await;
}

/// Save a session of `model` with one waiting input in the store of `place`, before a server runs.
async fn saved_session(place: &Place, provider: &str, model: &str) -> SessionId {
    let store: Arc<dyn Store> = Arc::new(place.store().await);
    let settings = SessionSettings {
        model: ModelReference {
            provider: provider.to_owned(),
            model: model.to_owned(),
        },
        settings: yuke_ai::Settings::new(),
        cwd: place.work.clone(),
    };
    let session = Session::create(
        Arc::clone(&store),
        &settings,
        &[PromptSection::new("base", "the prompt")],
    )
    .await
    .unwrap();
    let input = Input::new(
        InputSource::User,
        InputKind::Message,
        vec![yuke_ai::Block::user_text("waiting")],
    )
    .unwrap();
    let id = session.id();
    store.accept_input(id, input).await.unwrap();
    id
}

#[tokio::test]
async fn a_load_only_reads_and_waiting_input_blocks_new_settings() {
    let place = Place::new("rpc", "a_load_only_reads_and_waiting_input_blocks_new_settings");
    let session = saved_session(&place, "minimax", "MiniMax-M3").await;
    let mut client = Client::initialized(&place, Box::new(Stalled)).await;

    let loaded = client.load(&json!(session), json!({})).await;
    let mut settings = settings(&place);
    settings["sessionId"] = json!(session);
    let id = client.request("session/set_settings", settings).await;
    let refused = client.until(|message| message["id"] == json!(id)).await;
    let reloaded = client.load(&json!(session), json!({ "after": 1 })).await;

    let labels: Vec<String> = loaded.messages.iter().filter_map(label).collect();
    assert_eq!(labels, ["settings", "state idle", "input_accepted", "response"]);
    // No turn started: the session is still idle, and the input still waits.
    assert!(
        !refused
            .iter()
            .chain(&reloaded.messages)
            .any(|message| message["params"]["update"]["state"] == "running")
    );
    assert_eq!(reloaded.state, "idle");
    // The session has one saved event, and the reload asked for the events after it.
    assert!(
        !reloaded
            .messages
            .iter()
            .any(|message| message["params"]["update"].get("seq").is_some()),
        "{:?}",
        reloaded.messages
    );
    assert_eq!(loaded.state, "idle");
    assert_eq!(loaded.pending.len(), 1);
    assert_eq!(loaded.pending[0]["content"][0]["user_text"], "waiting");
    assert_eq!(reloaded.pending, loaded.pending);
    assert_eq!(
        refused.last().unwrap()["error"]["code"],
        json!(ResponseError::INVALID_REQUEST)
    );
    client.end().await;
}

#[tokio::test]
async fn a_fork_that_has_no_credential_fails_and_leaves_no_session() {
    let place = Place::new("rpc", "a_fork_that_has_no_credential_fails_and_leaves_no_session");
    let source = saved_session(&place, "anthropic", "claude-sonnet-4-5").await;
    let mut client = Client::initialized(&place, Box::new(ScriptedTransport::default())).await;

    let forked = client.call("session/fork", json!({ "sessionId": source })).await;
    client.end().await;

    assert_eq!(forked.unwrap_err()["code"], json!(ResponseError::INVALID_PARAMS));
    let store = place.store().await;
    let page = store.list_sessions(None, None, 10).await.unwrap();
    let ids: Vec<_> = page.sessions.iter().map(|session| session.session_id).collect();
    assert_eq!(ids, [source]);
}

#[tokio::test]
async fn the_prompt_hook_leaves_the_saved_prompt_of_the_session() {
    let place = Place::new("rpc", "the_prompt_hook_leaves_the_saved_prompt_of_the_session");
    place.plugin(
        "counted",
        "let count = 0;
         export function session(s) {
           s.hook('prompt.build', ({ sections }) => { count += 1; return { sections: { ...sections, turn: `number ${count}` } }; });
         }",
    );
    std::fs::write(place.paths.config.join("config.json"), r#"{ "plugins": ["counted"] }"#).unwrap();
    let transport = ScriptedTransport::new([text_reply("one"), text_reply("two")]);
    let mut client = Client::initialized(&place, Box::new(transport.clone())).await;
    let session = client.call("session/new", settings(&place)).await.unwrap()["sessionId"].clone();
    let id: SessionId = serde_json::from_value(session.clone()).unwrap();
    let created = place.store().await.open(id, Access::Read).await.unwrap().prompt;

    client.request("session/input", input_params(&session, "first")).await;
    client.until(is_idle).await;
    client.request("session/input", input_params(&session, "second")).await;
    client.until(is_idle).await;

    // The TypeScript tests check the requests. The test host of `yuke:test` does not show the store.
    assert!(transport.requests()[1].contains("number 2"));
    let saved = place.store().await.open(id, Access::Read).await.unwrap().prompt;
    assert_eq!(saved, created);
    client.end().await;
}

// The request is an input of the plugin in the same turn: the model reads the notice, and the saved record keeps what
// the user saw.
#[tokio::test]
async fn a_plugin_sends_the_model_on_once_after_its_final_answer() {
    let place = Place::new("rpc", "a_plugin_sends_the_model_on_once_after_its_final_answer");
    place.plugin(
        "guard",
        "export function session(s) {
           s.hook('round.after', ({ finishReason, continues }) =>
             finishReason === 'stop' && continues === 0 ? { continue: 'Run the tests.' } : undefined);
         }",
    );
    std::fs::write(place.paths.config.join("config.json"), r#"{ "plugins": ["guard"] }"#).unwrap();
    let transport = ScriptedTransport::new([text_reply("done"), text_reply("tests pass")]);
    let mut client = Client::initialized(&place, Box::new(transport.clone())).await;
    let session = client.call("session/new", settings(&place)).await.unwrap()["sessionId"].clone();

    client.request("session/input", input_params(&session, "fix it")).await;
    client.until(is_idle).await;
    let loaded = client.load(&session, json!({})).await;

    let requests = transport.requests();
    assert_eq!(requests.len(), 2);
    let notice = r#"<system_notification plugin=\"guard\">Run the tests.</system_notification>"#;
    assert!(requests[1].contains(notice), "{}", requests[1]);
    let commits: Vec<&Value> = loaded
        .messages
        .iter()
        .map(|message| &message["params"]["update"])
        .filter(|update| update["sessionUpdate"] == "commit")
        .collect();
    let ends: Vec<&Value> = commits.iter().map(|commit| &commit["commit"]["end"]).collect();
    assert_eq!(
        ends,
        [
            &Value::Null,
            &Value::Null,
            &Value::Null,
            &Value::Null,
            &json!({ "outcome": { "completed": { "finishReason": "stop" } } })
        ]
    );
    assert_eq!(
        commits[2]["consumed"],
        json!([{
            "id": 2,
            "source": { "kind": "plugin", "name": "guard" },
            "kind": "notification",
            "displayContent": [{ "user_text": "Run the tests." }],
            "blockCount": 1,
        }])
    );
    assert_eq!(
        commits[3]["commit"]["blocks"],
        json!([{ "assistant_text": "tests pass" }])
    );
    client.end().await;
}

#[tokio::test]
async fn a_skipped_skill_reaches_the_client_as_a_warning_of_the_new_session() {
    let place = Place::new("rpc", "a_skipped_skill_reaches_the_client");
    let skill = place.work.join(".agents/skills/broken");
    std::fs::create_dir_all(&skill).unwrap();
    std::fs::write(skill.join("SKILL.md"), "No frontmatter.").unwrap();
    let mut client = Client::initialized(&place, Box::new(ScriptedTransport::new([]))).await;

    let id = client.request("session/new", settings(&place)).await;
    let messages = client.until(|message| message["id"] == json!(id)).await;

    let session = &messages[messages.len() - 1]["result"]["sessionId"];
    let notice = &messages
        .iter()
        .find(|message| message["method"] == "notice")
        .expect("a notice comes before the answer")["params"];
    assert_eq!(&notice["sessionId"], session);
    assert_eq!(notice["level"], "warn");
    assert_eq!(
        notice["message"],
        format!(
            "yuke skipped the skill at {}: the file has no frontmatter",
            skill.join("SKILL.md").display()
        )
    );
    client.end().await;
}

#[tokio::test]
async fn a_close_ends_the_turn_keeps_waiting_input_and_a_load_opens_the_session_again() {
    let place = Place::new(
        "rpc",
        "a_close_ends_the_turn_keeps_waiting_input_and_a_load_opens_the_session_again",
    );
    let mut client = Client::initialized(&place, Box::new(Stalled)).await;
    let session = client.call("session/new", settings(&place)).await.unwrap()["sessionId"].clone();
    client.request("session/input", input_params(&session, "first")).await;
    // The turn takes the waiting input when it starts, so the second input comes after its request.
    client
        .until(|message| message["params"]["update"]["sessionUpdate"] == "draft_started")
        .await;
    client
        .call("session/input", input_params(&session, "second"))
        .await
        .unwrap();

    let id = client
        .request("session/close", json!({ "sessionId": session, "stopJobs": false }))
        .await;
    let closed = client.until(|message| message["id"] == json!(id)).await;
    let refused = client.call("session/input", input_params(&session, "third")).await;
    let closed_again = client
        .call("session/close", json!({ "sessionId": session, "stopJobs": false }))
        .await;
    let loaded = client.load(&session, json!({})).await;

    let labels: Vec<String> = closed.iter().filter_map(label).collect();
    assert_eq!(labels.last().unwrap(), "response");
    // A turn that started after the close would stall, and the close would not answer.
    assert!(labels.contains(&"state idle".to_owned()), "{labels:?}");
    assert_eq!(closed.last().unwrap()["result"], json!({}));
    assert_eq!(refused.unwrap_err()["code"], json!(ResponseError::SESSION_NOT_FOUND));
    assert_eq!(
        closed_again.unwrap_err()["code"],
        json!(ResponseError::SESSION_NOT_FOUND)
    );
    assert_eq!(loaded.state, "idle");
    let pending: Vec<&Value> = loaded
        .pending
        .iter()
        .map(|input| &input["content"][0]["user_text"])
        .collect();
    assert_eq!(pending, [&json!("second")]);
    client.end().await;
}

#[tokio::test]
async fn a_panic_in_a_turn_ends_the_turn_and_the_next_input_runs_with_a_note_about_it() {
    let place = Place::new(
        "rpc",
        "a_panic_in_a_turn_ends_the_turn_and_the_next_input_runs_with_a_note_about_it",
    );
    let transport = PanicsOnce::new([text_reply("back")]);
    let mut client = Client::initialized(&place, Box::new(transport)).await;
    let session = client.call("session/new", settings(&place)).await.unwrap()["sessionId"].clone();
    client.request("session/input", input_params(&session, "first")).await;

    let failed = client.until(|message| message["method"] == "notice").await;
    // The recovery ends the turn that the panic left open, and the client sees that end.
    let repaired = client
        .until(|message| message["params"]["update"]["sessionUpdate"] == "commit")
        .await;
    client
        .call("session/input", input_params(&session, "second"))
        .await
        .unwrap();
    let again = client.until(is_idle).await;

    let labels: Vec<String> = failed.iter().filter_map(label).collect();
    assert!(labels.contains(&"state running".to_owned()), "{labels:?}");
    // The unwind drops the turn, which tells the client that its provisional state is gone.
    assert_eq!(labels[labels.len() - 2..], ["turn_unconfirmed", "state idle"]);
    let notice = &failed.last().unwrap()["params"];
    assert!(
        notice["message"].as_str().unwrap().starts_with("the turn failed:"),
        "{notice}"
    );
    assert_eq!(notice["level"], "error");
    let end = &repaired.last().unwrap()["params"]["update"]["commit"]["end"];
    assert_eq!(end["failed"], "the turn stopped before it saved its end", "{end}");
    let saved: Vec<&Value> = again
        .iter()
        .filter(|message| message["params"]["update"]["sessionUpdate"] == "commit")
        .collect();
    let first = saved.first().unwrap()["params"]["update"].to_string();
    assert!(
        first.contains(r#"<system_notification plugin=\"host:session\">The previous turn ended with an error: the turn stopped before it saved its end</system_notification>"#),
        "{first}"
    );
    assert!(
        saved.iter().any(|message| message.to_string().contains("back")),
        "{again:?}"
    );
    client.end().await;
}

/// The activity of each row of `listed`, a `session/list` result, by session id.
fn activities(listed: &Value) -> BTreeMap<String, String> {
    listed["sessions"]
        .as_array()
        .unwrap()
        .iter()
        .map(|row| {
            let id = row["session"]["sessionId"].as_str().unwrap().to_owned();
            (id, row["activity"].as_str().unwrap().to_owned())
        })
        .collect()
}

#[tokio::test]
async fn the_list_and_a_get_give_each_saved_session_with_its_activity() {
    let place = Place::new("rpc", "the_list_and_a_get_give_each_saved_session_with_its_activity");
    let saved = saved_session(&place, "minimax", "MiniMax-M3").await;
    let mut client = Client::initialized(&place, Box::new(Stalled)).await;
    let running = client.call("session/new", settings(&place)).await.unwrap()["sessionId"].clone();
    client.request("session/input", input_params(&running, "hi")).await;
    client
        .until(|message| message["params"]["update"]["state"] == "running")
        .await;
    let idle = client.call("session/new", settings(&place)).await.unwrap()["sessionId"].clone();

    let listed = client.call("session/list", json!({})).await.unwrap();
    let row = client.call("session/get", json!({ "sessionId": saved })).await.unwrap();
    let unknown = client
        .call("session/get", json!({ "sessionId": SessionId::generate() }))
        .await;
    client.notify("session/cancel", json!({ "sessionId": running })).await;
    client.until(is_idle).await;
    client.end().await;

    let expected = BTreeMap::from([
        (saved.to_string(), "closed".to_owned()),
        (running.as_str().unwrap().to_owned(), "running".to_owned()),
        (idle.as_str().unwrap().to_owned(), "idle".to_owned()),
    ]);
    assert_eq!(activities(&listed), expected);
    assert_eq!(row["activity"], "closed");
    assert_eq!(row["session"]["preview"], "waiting");
    assert_eq!(row["session"]["cwd"], json!(place.work));
    assert_eq!(unknown.unwrap_err()["code"], json!(ResponseError::SESSION_NOT_FOUND));
}

#[tokio::test]
async fn a_list_pages_by_cursor_in_one_folder_and_refuses_a_bad_cursor_or_limit() {
    let place = Place::new(
        "rpc",
        "a_list_pages_by_cursor_in_one_folder_and_refuses_a_bad_cursor_or_limit",
    );
    for _ in 0..3 {
        saved_session(&place, "minimax", "MiniMax-M3").await;
    }
    let mut client = Client::initialized(&place, Box::new(ScriptedTransport::default())).await;
    let work = json!(place.work);

    let first = client
        .call("session/list", json!({ "cwd": work, "limit": 2 }))
        .await
        .unwrap();
    let cursor = first["nextCursor"].clone();
    let second = client
        .call("session/list", json!({ "cwd": work, "limit": 2, "cursor": cursor }))
        .await
        .unwrap();
    let elsewhere = client
        .call("session/list", json!({ "cwd": "/elsewhere" }))
        .await
        .unwrap();
    let mut refused = Vec::new();
    for params in [
        json!({ "cursor": cursor }),
        json!({ "cwd": work, "cursor": "not a cursor" }),
        json!({ "cursor": "18446744073709551615." }),
        json!({ "limit": 0 }),
        json!({ "limit": 101 }),
    ] {
        refused.push(client.call("session/list", params).await.unwrap_err()["code"].clone());
    }
    client.end().await;

    let ids: BTreeSet<String> = activities(&first)
        .into_keys()
        .chain(activities(&second).into_keys())
        .collect();
    assert_eq!(first["sessions"].as_array().unwrap().len(), 2);
    assert_eq!(second["sessions"].as_array().unwrap().len(), 1);
    assert_eq!(second.get("nextCursor"), None);
    assert_eq!(ids.len(), 3);
    assert_eq!(elsewhere["sessions"], json!([]));
    assert_eq!(refused, vec![json!(ResponseError::INVALID_PARAMS); 5]);
}

#[tokio::test]
async fn a_remove_deletes_a_closed_session_keeps_its_fork_and_refuses_an_open_or_held_one() {
    let place = Place::new(
        "rpc",
        "a_remove_deletes_a_closed_session_keeps_its_fork_and_refuses_an_open_or_held_one",
    );
    let source = saved_session(&place, "minimax", "MiniMax-M3").await;
    let held = saved_session(&place, "minimax", "MiniMax-M3").await;
    let store = place.store().await;
    let fork = store.fork_session(source, None).await.unwrap().id;
    // This lease stands for another process that writes the session.
    let lease = store.open(held, Access::Write).await.unwrap();
    let mut client = Client::initialized(&place, Box::new(ScriptedTransport::default())).await;
    let open = client.call("session/new", settings(&place)).await.unwrap()["sessionId"].clone();

    let removed = client.call("session/remove", json!({ "sessionId": source })).await;
    let again = client.call("session/remove", json!({ "sessionId": source })).await;
    let refused_open = client.call("session/remove", json!({ "sessionId": open })).await;
    let refused_held = client.call("session/remove", json!({ "sessionId": held })).await;
    client
        .call("session/close", json!({ "sessionId": open, "stopJobs": false }))
        .await
        .unwrap();
    let closed = client.call("session/remove", json!({ "sessionId": open })).await;
    let listed = client.call("session/list", json!({})).await.unwrap();
    let fork_row = client.call("session/get", json!({ "sessionId": fork })).await.unwrap();
    client.end().await;
    drop(lease);

    assert_eq!(removed.unwrap(), json!({}));
    assert_eq!(again.unwrap_err()["code"], json!(ResponseError::SESSION_NOT_FOUND));
    assert_eq!(refused_open.unwrap_err()["code"], json!(ResponseError::INVALID_REQUEST));
    assert_eq!(refused_held.unwrap_err()["code"], json!(ResponseError::SESSION_OWNED));
    assert_eq!(closed.unwrap(), json!({}));
    let expected = BTreeMap::from([
        (fork.to_string(), "closed".to_owned()),
        (held.to_string(), "closed".to_owned()),
    ]);
    assert_eq!(activities(&listed), expected);
    assert_eq!(fork_row["session"]["forkOf"], json!(source));
}

#[tokio::test]
async fn process_and_session_events_of_a_plugin_reach_the_client_under_its_name() {
    let place = Place::new(
        "rpc",
        "process_and_session_events_of_a_plugin_reach_the_client_under_its_name",
    );
    place.plugin(
        "todo",
        "export function apply(ctx) { ctx.emit('ready', { version: 1 }); }
         export function session(s) { s.emit('changed', ['milk']); }",
    );
    std::fs::write(place.paths.config.join("config.json"), r#"{ "plugins": ["todo"] }"#).unwrap();
    let mut client = Client::start(&place, Box::new(ScriptedTransport::default()));

    let ready = client
        .until(|message| message["method"] == "extension/event")
        .await
        .pop()
        .unwrap();
    client.initialize().await;
    // The event of the new session can come before or after the response.
    let id = client.request("session/new", settings(&place)).await;
    let mut messages: Vec<Value> = Vec::new();
    while !(messages.iter().any(|message| message["id"] == json!(id))
        && messages.iter().any(|message| message["method"] == "extension/event"))
    {
        messages.push(client.next().await);
    }
    let session = &messages.iter().find(|message| message["id"] == json!(id)).unwrap()["result"]["sessionId"];
    let changed = messages
        .iter()
        .find(|message| message["method"] == "extension/event")
        .unwrap();

    assert_eq!(
        ready["params"],
        json!({ "extension": "todo", "event": "ready", "data": { "version": 1 } })
    );
    assert_eq!(
        changed["params"],
        json!({ "sessionId": session, "extension": "todo", "event": "changed", "data": ["milk"] })
    );
    client.end().await;
}

#[tokio::test]
async fn a_session_that_a_client_created_stays_open_after_its_turn() {
    let place = Place::new("rpc", "a_session_that_a_client_created_stays_open_after_its_turn");
    let mut client = Client::initialized(&place, Box::new(ScriptedTransport::new([text_reply("hello")]))).await;
    let session = client.call("session/new", settings(&place)).await.unwrap()["sessionId"].clone();
    turn(&mut client, &session, "hi").await;

    // No request runs while the clock is paused, so no wait of the client ends early.
    tokio::time::pause();
    tokio::time::sleep(Duration::from_secs(3600)).await;
    tokio::time::resume();
    let row = client
        .call("session/get", json!({ "sessionId": session }))
        .await
        .unwrap();

    assert_eq!(row["activity"], "idle");
    client.end().await;
}
