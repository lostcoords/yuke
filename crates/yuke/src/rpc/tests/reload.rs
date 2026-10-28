//! The reload of the config: plugins, providers, skills, and the cleanups of the old and the new plugins.

use super::*;

/// The source of a plugin that defines the tool `name`.
fn tool_plugin(name: &str) -> String {
    format!(
        "export function session(s) {{
           s.tools.define({{
             name: '{name}', description: 'A tool.', concurrency: 'serial',
             parameters: {{ type: 'object', properties: {{}} }},
             execute: async () => 'done',
           }});
         }}"
    )
}

#[tokio::test]
async fn after_a_reload_the_next_turn_of_an_open_session_has_the_tools_of_the_changed_plugin() {
    let place = Place::new("rpc", "reload_tools");
    place.plugin("tools", &tool_plugin("alpha"));
    std::fs::write(place.paths.config.join("config.json"), r#"{ "plugins": ["tools"] }"#).unwrap();
    let transport = ScriptedTransport::new([text_reply("one"), text_reply("two")]);
    let mut client = Client::initialized(&place, Box::new(transport.clone())).await;
    let session = client.call("session/new", settings(&place)).await.unwrap()["sessionId"].clone();
    turn(&mut client, &session, "first").await;
    place.plugin("tools", &tool_plugin("beta"));

    let reloaded = client.call("profile/reload", json!({})).await;
    turn(&mut client, &session, "second").await;

    assert_eq!(reloaded, Ok(json!({})));
    let requests = transport.requests();
    assert!(requests[0].contains(r#""name":"alpha""#), "{}", requests[0]);
    assert!(
        requests[1].contains(r#""name":"beta""#) && !requests[1].contains(r#""name":"alpha""#),
        "{}",
        requests[1]
    );
    // The new runtime has the tools of yuke too.
    assert!(requests[1].contains(r#""name":"read""#), "{}", requests[1]);
    client.end().await;
}

#[tokio::test]
async fn a_plugin_gets_the_options_of_its_config_item_and_a_reload_reads_them_again() {
    let place = Place::new("rpc", "reload_options");
    place.plugin(
        "tools",
        "export const optionsSchema = {
           type: 'object', properties: { name: { type: 'string' } }, required: ['name'],
         };
         export function session(s) {
           s.tools.define({
             name: s.options.name, description: 'A tool.', concurrency: 'serial',
             parameters: { type: 'object', properties: {} },
             execute: async () => 'done',
           });
         }",
    );
    let config = |name: &str| {
        let config = json!({ "plugins": [{ "path": "tools", "options": { "name": name } }] });
        std::fs::write(place.paths.config.join("config.json"), config.to_string()).unwrap();
    };
    config("alpha");
    let transport = ScriptedTransport::new([text_reply("one"), text_reply("two")]);
    let mut client = Client::initialized(&place, Box::new(transport.clone())).await;
    let session = client.call("session/new", settings(&place)).await.unwrap()["sessionId"].clone();
    turn(&mut client, &session, "first").await;
    config("beta");

    let reloaded = client.call("profile/reload", json!({})).await;
    turn(&mut client, &session, "second").await;

    assert_eq!(reloaded, Ok(json!({})));
    let requests = transport.requests();
    assert!(requests[0].contains(r#""name":"alpha""#), "{}", requests[0]);
    assert!(
        requests[1].contains(r#""name":"beta""#) && !requests[1].contains(r#""name":"alpha""#),
        "{}",
        requests[1]
    );
    client.end().await;
}

#[tokio::test]
async fn a_reload_during_a_turn_answers_an_error() {
    let place = Place::new("rpc", "reload_during_a_turn");
    let mut client = Client::initialized(&place, Box::new(Stalled)).await;
    let session = client.call("session/new", settings(&place)).await.unwrap()["sessionId"].clone();
    client.request("session/input", input_params(&session, "wait")).await;
    client
        .until(|message| message["params"]["update"]["state"] == "running")
        .await;

    let refused = client.call("profile/reload", json!({})).await.unwrap_err();

    assert_eq!(refused["code"], ResponseError::INVALID_REQUEST);
    assert_eq!(refused["message"], "a turn runs: reload after it ends");
    client.notify("session/cancel", json!({ "sessionId": session })).await;
    client.until(is_idle).await;
    client.end().await;
}

#[tokio::test]
async fn a_bad_config_fails_the_reload_and_keeps_the_old_plugins() {
    let place = Place::new("rpc", "reload_bad_config");
    place.plugin("tools", &tool_plugin("alpha"));
    std::fs::write(place.paths.config.join("config.json"), r#"{ "plugins": ["tools"] }"#).unwrap();
    let transport = ScriptedTransport::new([text_reply("one")]);
    let mut client = Client::initialized(&place, Box::new(transport.clone())).await;
    let session = client.call("session/new", settings(&place)).await.unwrap()["sessionId"].clone();
    std::fs::write(place.paths.config.join("config.json"), "{").unwrap();

    let refused = client.call("profile/reload", json!({})).await.unwrap_err();
    turn(&mut client, &session, "first").await;

    assert_eq!(refused["code"], ResponseError::INVALID_PARAMS);
    assert!(transport.requests()[0].contains(r#""name":"alpha""#));
    client.end().await;
}

#[tokio::test]
async fn a_plugin_that_does_not_load_fails_the_reload_and_keeps_the_old_plugins() {
    let place = Place::new("rpc", "reload_broken_plugin");
    place.plugin("tools", &tool_plugin("alpha"));
    place.plugin("other", &tool_plugin("beta"));
    std::fs::write(
        place.paths.config.join("config.json"),
        r#"{ "plugins": ["tools", "other"] }"#,
    )
    .unwrap();
    let transport = ScriptedTransport::new([text_reply("one")]);
    let mut client = Client::initialized(&place, Box::new(transport.clone())).await;
    let session = client.call("session/new", settings(&place)).await.unwrap()["sessionId"].clone();
    // The edits make both plugins fail to load. The same reload also adds a provider.
    place.plugin("tools", "export function session(s) {");
    place.plugin("other", "export function session(s) {");
    std::fs::write(
        place.paths.config.join("providers.json"),
        r#"{ "providers": [{
            "id": "local", "base_url": "http://127.0.0.1:8080/v1",
            "endpoints": [{ "protocol": "anthropic_messages" }],
            "models": [{ "id": "small", "limits": { "max_output_tokens": 4096 } }]
        }] }"#,
    )
    .unwrap();

    let refused = client.call("profile/reload", json!({})).await.unwrap_err();
    turn(&mut client, &session, "first").await;
    // The old profile is back, so it has no new provider.
    let mut local = settings(&place);
    local["model"] = json!({ "provider": "local", "model": "small" });
    let new_provider = client.call("session/new", local).await;

    assert_eq!(refused["code"], ResponseError::INVALID_PARAMS);
    let message = refused["message"].as_str().unwrap();
    assert!(message.starts_with("the reload keeps the old plugins"), "{message}");
    // Each failure has its own text.
    assert!(
        message.contains("plugin tools") && message.contains("plugin other"),
        "{message}"
    );
    assert!(transport.requests()[0].contains(r#""name":"alpha""#));
    assert!(new_provider.is_err(), "{new_provider:?}");
    client.end().await;
}

#[tokio::test]
async fn a_session_after_a_reload_has_a_new_provider_and_the_skills_of_a_new_plugin_folder() {
    let place = Place::new("rpc", "reload_profile");
    std::fs::create_dir_all(&place.paths.config).unwrap();
    let transport = ScriptedTransport::new([text_reply("one")]);
    let mut client = Client::initialized(&place, Box::new(transport.clone())).await;
    let mut local = settings(&place);
    local["model"] = json!({ "provider": "local", "model": "small" });
    let before = client.call("session/new", local.clone()).await;
    std::fs::write(
        place.paths.config.join("providers.json"),
        r#"{ "providers": [{
            "id": "local", "base_url": "http://127.0.0.1:8080/v1",
            "endpoints": [{ "protocol": "anthropic_messages" }],
            "models": [{ "id": "small", "limits": { "max_output_tokens": 4096 } }]
        }] }"#,
    )
    .unwrap();
    place.plugin("charts", "export function session(s) {}");
    let skill = place.paths.config.join("charts/skills/charts");
    std::fs::create_dir_all(&skill).unwrap();
    std::fs::write(
        skill.join("SKILL.md"),
        "---\nname: charts\ndescription: Draw charts.\n---\n",
    )
    .unwrap();
    std::fs::write(place.paths.config.join("config.json"), r#"{ "plugins": ["charts"] }"#).unwrap();

    client.call("profile/reload", json!({})).await.unwrap();
    let session = client.call("session/new", local).await.unwrap()["sessionId"].clone();
    turn(&mut client, &session, "hi").await;

    assert!(before.is_err(), "{before:?}");
    assert_eq!(transport.urls(), ["http://127.0.0.1:8080/v1/messages"]);
    assert!(transport.requests()[0].contains("<name>charts</name>"));
    client.end().await;
}

// A rejected reload closes the plugins of its new runtime and keeps the old ones open.
#[tokio::test]
async fn a_rejected_reload_runs_the_cleanups_of_its_new_plugins_only() {
    let place = Place::new("rpc", "reload_rejected_cleanups");
    let marks = place.work.join("marks");
    let source = format!(
        "import {{ writeTextFile, readTextFile }} from 'yuke:fs';
         export function apply(ctx) {{
           return async () => {{
             const before = await readTextFile('{marks}').catch(() => '');
             await writeTextFile('{marks}', before + 'apply ended\\n');
           }};
         }}",
        marks = marks.display()
    );
    place.plugin("marker", &source);
    place.plugin("broken", "export function session(s) {}");
    std::fs::write(
        place.paths.config.join("config.json"),
        r#"{ "plugins": ["marker", "broken"] }"#,
    )
    .unwrap();
    let mut client = Client::initialized(&place, Box::new(ScriptedTransport::new([]))).await;
    client.call("session/new", settings(&place)).await.unwrap();
    place.plugin("broken", "export function session(s) {");

    client.call("profile/reload", json!({})).await.unwrap_err();

    // Only the marker of the new runtime closed: the old one still runs.
    assert_eq!(std::fs::read_to_string(&marks).unwrap(), "apply ended\n");
    client.end().await;
}

// The old plugins close during the reload, so the cleanup of each one runs once.
#[tokio::test]
async fn a_reload_runs_the_cleanups_of_the_old_plugins() {
    let place = Place::new("rpc", "reload_cleanups");
    let marks = place.work.join("marks");
    let source = format!(
        "import {{ writeTextFile, readTextFile }} from 'yuke:fs';
         const mark = async (text) => {{
           const before = await readTextFile('{marks}').catch(() => '');
           await writeTextFile('{marks}', before + text + '\\n');
         }};
         export function apply(ctx) {{ return () => mark('apply ended'); }}
         export function session(s) {{ return () => mark('session ended'); }}",
        marks = marks.display()
    );
    place.plugin("marker", &source);
    std::fs::write(place.paths.config.join("config.json"), r#"{ "plugins": ["marker"] }"#).unwrap();
    let mut client = Client::initialized(&place, Box::new(ScriptedTransport::new([]))).await;
    client.call("session/new", settings(&place)).await.unwrap();

    client.call("profile/reload", json!({})).await.unwrap();

    assert_eq!(std::fs::read_to_string(&marks).unwrap(), "session ended\napply ended\n");
    client.end().await;
}

#[tokio::test]
async fn a_bad_providers_file_fails_the_reload_and_keeps_the_old_providers() {
    let place = Place::new("rpc", "reload_bad_providers");
    let transport = ScriptedTransport::new([text_reply("one")]);
    let mut client = Client::initialized(&place, Box::new(transport.clone())).await;
    std::fs::create_dir_all(&place.paths.config).unwrap();
    std::fs::write(place.paths.config.join("providers.json"), "{").unwrap();

    let refused = client.call("profile/reload", json!({})).await.unwrap_err();
    let session = client.call("session/new", settings(&place)).await.unwrap()["sessionId"].clone();
    turn(&mut client, &session, "hi").await;

    assert_eq!(refused["code"], ResponseError::INVALID_PARAMS);
    assert_eq!(transport.requests().len(), 1);
    client.end().await;
}

// The new plugins load after the swap of the providers, so their `apply` can call a model of the new providers.
#[tokio::test]
async fn the_apply_of_a_new_plugin_can_call_a_model_of_the_new_providers() {
    let place = Place::new("rpc", "reload_apply_providers");
    std::fs::create_dir_all(&place.paths.config).unwrap();
    let transport = ScriptedTransport::new([text_reply("from apply")]);
    let mut client = Client::initialized(&place, Box::new(transport.clone())).await;
    std::fs::write(
        place.paths.config.join("providers.json"),
        r#"{ "providers": [{
            "id": "local", "base_url": "http://127.0.0.1:8080/v1",
            "endpoints": [{ "protocol": "anthropic_messages" }],
            "models": [{ "id": "small", "limits": { "max_output_tokens": 4096 } }]
        }] }"#,
    )
    .unwrap();
    let answer = place.work.join("answer");
    place.plugin(
        "asker",
        &format!(
            "import {{ generateText }} from 'yuke:ai';
             import {{ writeTextFile }} from 'yuke:fs';
             export async function apply(ctx) {{
               const answer = await generateText({{ model: {{ provider: 'local', model: 'small' }}, prompt: 'hi' }});
               await writeTextFile('{}', answer.text);
             }}",
            answer.display()
        ),
    );
    std::fs::write(place.paths.config.join("config.json"), r#"{ "plugins": ["asker"] }"#).unwrap();

    client.call("profile/reload", json!({})).await.unwrap();

    assert_eq!(std::fs::read_to_string(&answer).unwrap(), "from apply");
    assert_eq!(transport.urls(), ["http://127.0.0.1:8080/v1/messages"]);
    client.end().await;
}
