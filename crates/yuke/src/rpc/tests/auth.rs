//! Credentials: pushed tokens, logins, API keys, and the catalog of the providers.

use super::*;

/// A place where `xai-grok/test` speaks Anthropic Messages, as the scripted replies do.
fn place_with_login_model(name: &str) -> Place {
    let place = Place::new("rpc", name);
    std::fs::create_dir_all(&place.paths.config).unwrap();
    let providers = json!({ "providers": [{
        "id": "xai-grok",
        "endpoints": [
            { "protocol": "openai_responses", "credential_header": "authorization_bearer" },
            { "protocol": "anthropic_messages", "credential_header": "authorization_bearer" }
        ],
        "models": [{ "id": "test", "protocol": "anthropic_messages", "limits": { "max_output_tokens": 1000 } }]
    }] });
    std::fs::write(place.paths.config.join("providers.json"), providers.to_string()).unwrap();
    place
}

/// Push `token` for `xai-grok`, valid for an hour.
async fn push(client: &mut Client, token: &str) -> Result<Value, Value> {
    let expires_at = crate::auth::millis(std::time::SystemTime::now()) + 3_600_000;
    client
        .call(
            "credential/update",
            json!({ "provider": "xai-grok", "accessToken": token, "expiresAt": expires_at }),
        )
        .await
}

/// A new session of `xai-grok/test`, and the params of an input to it.
async fn login_session(client: &mut Client, place: &Place) -> Value {
    let mut settings = settings(place);
    settings["model"] = json!({ "provider": "xai-grok", "model": "test" });
    let session = client.call("session/new", settings).await.unwrap()["sessionId"].clone();
    input_params(&session, "hi")
}

#[tokio::test]
async fn a_pushed_token_serves_each_open_session_and_a_new_push_serves_the_next_request() {
    let place = place_with_login_model("pushed_token");
    let transport = ScriptedTransport::new([text_reply("one"), text_reply("two")]);
    let mut client = Client::initialized(&place, Box::new(transport.clone())).await;
    let first_session = login_session(&mut client, &place).await;
    let second_session = login_session(&mut client, &place).await;

    assert_eq!(push(&mut client, "first").await, Ok(json!({})));
    client.request("session/input", first_session).await;
    client.until(is_idle).await;
    push(&mut client, "second").await.unwrap();
    client.request("session/input", second_session).await;
    client.until(is_idle).await;

    assert_eq!(
        transport.header("Authorization"),
        [Some("Bearer first".to_owned()), Some("Bearer second".to_owned())]
    );
    client.end().await;
}

#[tokio::test]
async fn a_credential_update_that_cannot_serve_is_refused_and_keeps_the_token_before_it() {
    let place = place_with_login_model("refused_push");
    let transport = ScriptedTransport::new([text_reply("one")]);
    let mut client = Client::initialized(&place, Box::new(transport.clone())).await;
    push(&mut client, "kept").await.unwrap();
    let later = crate::auth::millis(std::time::SystemTime::now()) + 3_600_000;
    let update = |provider: &str, token: &str, expires_at: u64, account: Option<&str>| {
        let mut params = json!({ "provider": provider, "accessToken": token, "expiresAt": expires_at });
        if let Some(account) = account {
            params["accountId"] = json!(account);
        }
        params
    };
    let bad_token = "accessToken: send a value that is not empty and has no control character";
    let bad_account = "accountId: send a value that is not empty and has no control character";
    let cases = [
        (
            update("openai", "t", later, None),
            "provider: openai has no login flow, so it takes no credential/update",
        ),
        (
            update("nobody", "t", later, None),
            "provider: nobody has no login flow, so it takes no credential/update",
        ),
        (update("xai-grok", "", later, None), bad_token),
        (update("xai-grok", "a\nb", later, None), bad_token),
        (update("xai-grok", "a\tb", later, None), bad_token),
        (update("xai-grok", "t", 1, None), "expiresAt: the token already expired"),
        (
            update("xai-grok", "t", later, Some("account")),
            "accountId: xai-grok names no account, so send none",
        ),
        (update("openai-codex", "t", later, Some("")), bad_account),
    ];

    for (params, message) in cases {
        let error = client.call("credential/update", params.clone()).await.unwrap_err();
        assert_eq!(error["code"], json!(-32602), "{params}");
        assert_eq!(error["message"], json!(message), "{params}");
    }
    let missing = client
        .call(
            "credential/update",
            json!({ "provider": "xai-grok", "accessToken": "t" }),
        )
        .await
        .unwrap_err();
    assert_eq!(missing["code"], json!(-32602), "{missing}");
    let input = login_session(&mut client, &place).await;
    client.request("session/input", input).await;
    client.until(is_idle).await;
    assert_eq!(transport.header("Authorization"), [Some("Bearer kept".to_owned())]);
    client.end().await;
}

#[tokio::test]
async fn a_pushed_token_still_serves_after_a_reload() {
    let place = place_with_login_model("reload_pushed_token");
    let transport = ScriptedTransport::new([text_reply("one")]);
    let mut client = Client::initialized(&place, Box::new(transport.clone())).await;
    let session = login_session(&mut client, &place).await;
    push(&mut client, "kept").await.unwrap();

    client.call("profile/reload", json!({})).await.unwrap();
    client.request("session/input", session).await;
    client.until(is_idle).await;

    assert_eq!(transport.header("Authorization"), [Some("Bearer kept".to_owned())]);
    client.end().await;
}

/// The state of each provider of `listed`, a `catalog/list` result, by provider id.
fn provider_states(listed: &Value) -> BTreeMap<String, Value> {
    listed["providers"]
        .as_array()
        .unwrap()
        .iter()
        .map(|provider| (provider["id"].as_str().unwrap().to_owned(), provider["state"].clone()))
        .collect()
}

#[tokio::test]
async fn the_catalog_gives_the_ready_providers_or_each_provider_with_its_state() {
    let place = Place::new(
        "rpc",
        "the_catalog_gives_the_ready_providers_or_each_provider_with_its_state",
    );
    std::fs::create_dir_all(&place.paths.data).unwrap();
    // An entry of the wrong kind gives its provider no credential.
    let stored = json!({
        "openai-codex": { "access_token": "a", "refresh_token": "r", "expires_at": 0 },
        "anthropic": { "access_token": "b", "refresh_token": "s", "expires_at": 0 },
        "xai-grok": { "api_key": "k" },
    });
    std::fs::write(place.paths.data.join("auth.json"), stored.to_string()).unwrap();
    std::fs::create_dir_all(&place.paths.config).unwrap();
    let providers = r#"{ "providers": [{
        "id": "local", "base_url": "http://127.0.0.1:8080/v1",
        "endpoints": [{ "protocol": "anthropic_messages" }],
        "models": [{ "id": "small", "upstream_id": "vendor/small", "limits": { "max_output_tokens": 4096 },
                     "reasoning_levels": ["high", "high"] }]
    }] }"#;
    std::fs::write(place.paths.config.join("providers.json"), providers).unwrap();
    let mut client = Client::initialized(&place, Box::new(ScriptedTransport::default())).await;

    let ready = client.call("catalog/list", json!({})).await.unwrap();
    let all = client.call("catalog/list", json!({ "all": true })).await.unwrap();
    let refused = client.call("catalog/list", json!({ "all": "yes" })).await;
    client.end().await;

    let ready_state = json!({ "kind": "ready" });
    let ready_states = provider_states(&ready);
    assert!(
        ready_states.values().all(|state| *state == ready_state),
        "{ready_states:?}"
    );
    assert_eq!(
        ready_states.keys().map(String::as_str).collect::<Vec<_>>(),
        ["local", "minimax", "openai-codex"]
    );
    let all_states = provider_states(&all);
    assert_eq!(
        all_states["anthropic"],
        json!({ "kind": "needs_api_key", "variable": "ANTHROPIC_API_KEY" })
    );
    assert_eq!(all_states["xai-grok"], json!({ "kind": "needs_login" }));
    assert_eq!(all_states["openai-codex"], ready_state);
    assert_eq!(refused.unwrap_err()["code"], json!(ResponseError::INVALID_PARAMS));

    let local = &all["providers"]
        .as_array()
        .unwrap()
        .iter()
        .find(|provider| provider["id"] == "local")
        .unwrap();
    let small = &local["models"][0];
    assert_eq!(small["id"], "small");
    assert_eq!(small["maxOutputTokens"], 4096);
    assert_eq!(
        small["reasoning"][0],
        json!({ "level": "default", "settings": { "thinking": null, "effort": null } })
    );
    let levels: Vec<&str> = small["reasoning"]
        .as_array()
        .unwrap()
        .iter()
        .map(|choice| choice["level"].as_str().unwrap())
        .collect();
    assert_eq!(levels, ["default", "off", "high"]);
}

#[tokio::test]
async fn each_reasoning_choice_of_the_catalog_gives_the_settings_of_its_level() {
    let place = Place::new(
        "rpc",
        "each_reasoning_choice_of_the_catalog_gives_the_settings_of_its_level",
    );
    let mut client = Client::initialized(&place, Box::new(ScriptedTransport::default())).await;

    let all = client.call("catalog/list", json!({ "all": true })).await.unwrap();
    client.end().await;

    let providers = Providers::load(&place.paths.config).unwrap();
    let mut checked = 0;
    let mut offs = 0;
    for provider in all["providers"].as_array().unwrap() {
        for model in provider["models"].as_array().unwrap() {
            let selector = format!("{}/{}", provider["id"].as_str().unwrap(), model["id"].as_str().unwrap());
            let entry = providers.lookup(&selector).unwrap();
            for choice in model["reasoning"].as_array().unwrap().iter().skip(1) {
                let level = match choice["level"].as_str().unwrap() {
                    "off" => {
                        offs += 1;
                        yuke_ai::catalog::ReasoningLevel::Off
                    }
                    effort => yuke_ai::catalog::ReasoningLevel::Effort(serde_json::from_value(json!(effort)).unwrap()),
                };
                let expected = serde_json::to_value(entry.model.reasoning(level).unwrap()).unwrap();
                assert_eq!(choice["settings"], expected, "{selector} {level:?}");
                checked += 1;
            }
        }
    }
    assert!(checked > offs && offs > 0, "{checked} choices, {offs} off");
}

/// The `xai-grok` answer that starts a device login.
const LOGIN_START: &str =
    r#"{"device_code":"dc","user_code":"UC","verification_uri_complete":"https://x.ai/d?c=UC","interval":1}"#;

/// Whether `message` has the method `auth/login_finished` and the login id `id`.
fn finished(message: &Value, id: &Value) -> bool {
    message["method"] == "auth/login_finished" && message["params"]["loginId"] == *id
}

#[tokio::test]
async fn a_login_gives_its_code_at_once_and_its_end_saves_the_login() {
    let place = Place::new("rpc", "a_login_gives_its_code_at_once_and_its_end_saves_the_login");
    let answers = Answers::default();
    answers.push(200, LOGIN_START);
    answers.push(200, r#"{"access_token":"at","refresh_token":"rt","expires_in":3600}"#);
    let mut client = Client::start_with(&place, Box::new(ScriptedTransport::default()), answers);
    client.initialize().await;

    let started = client
        .call("auth/login", json!({ "provider": "xai-grok" }))
        .await
        .unwrap();
    let id = started["loginId"].clone();
    let end = client.until(|message| finished(message, &id)).await.pop().unwrap();
    let catalog = client.call("catalog/list", json!({})).await.unwrap();
    client.end().await;

    assert_eq!(started["userCode"], "UC");
    assert_eq!(started["verificationUrl"], "https://x.ai/d?c=UC");
    assert_eq!(end["params"]["provider"], "xai-grok");
    assert_eq!(end["params"]["outcome"], json!({ "kind": "succeeded" }));
    assert_eq!(provider_states(&catalog)["xai-grok"], json!({ "kind": "ready" }));
    let saved: Value = serde_json::from_slice(&std::fs::read(place.paths.data.join("auth.json")).unwrap()).unwrap();
    assert_eq!(saved["xai-grok"]["access_token"], "at");
}

#[tokio::test]
async fn a_second_login_cancels_the_first_and_a_cancel_ends_a_login_once() {
    let place = Place::new("rpc", "a_second_login_cancels_the_first_and_a_cancel_ends_a_login_once");
    let answers = Answers::default();
    answers.push(200, LOGIN_START);
    answers.push(200, LOGIN_START);
    let mut client = Client::start_with(&place, Box::new(ScriptedTransport::default()), answers);
    client.initialize().await;

    let first = client.request("auth/login", json!({ "provider": "xai-grok" })).await;
    let second = client.request("auth/login", json!({ "provider": "xai-grok" })).await;
    let mut messages = client.until(|message| message["id"] == json!(second)).await;
    let first_id = messages.iter().find(|message| message["id"] == json!(first)).unwrap()["result"]["loginId"].clone();
    let second_id = messages.last().unwrap()["result"]["loginId"].clone();
    if !messages.iter().any(|message| finished(message, &first_id)) {
        messages.extend(client.until(|message| finished(message, &first_id)).await);
    }
    let cancel = client
        .request("auth/cancel_login", json!({ "loginId": second_id }))
        .await;
    let mut after = client.until(|message| finished(message, &second_id)).await;
    if !after.iter().any(|message| message["id"] == json!(cancel)) {
        after.extend(client.until(|message| message["id"] == json!(cancel)).await);
    }
    let again = client.call("auth/cancel_login", json!({ "loginId": second_id })).await;
    client.end().await;

    let outcome = |messages: &[Value], id: &Value| {
        messages.iter().find(|message| finished(message, id)).unwrap()["params"]["outcome"].clone()
    };
    assert_ne!(first_id, second_id);
    assert_eq!(outcome(&messages, &first_id), json!({ "kind": "cancelled" }));
    assert_eq!(outcome(&after, &second_id), json!({ "kind": "cancelled" }));
    assert_eq!(again.unwrap_err()["code"], json!(ResponseError::LOGIN_NOT_FOUND));
    assert!(!place.paths.data.join("auth.json").exists());
}

#[tokio::test]
async fn a_login_of_a_provider_without_a_flow_or_a_refused_start_fails() {
    let place = Place::new("rpc", "a_login_of_a_provider_without_a_flow_or_a_refused_start_fails");
    let answers = Answers::default();
    answers.push(400, r#"{"error":"invalid_client"}"#);
    let mut client = Client::start_with(&place, Box::new(ScriptedTransport::default()), answers);
    client.initialize().await;

    let key = client.call("auth/login", json!({ "provider": "anthropic" })).await;
    let unknown = client.call("auth/login", json!({ "provider": "nobody" })).await;
    let refused = client.call("auth/login", json!({ "provider": "xai-grok" })).await;
    client.end().await;

    assert_eq!(key.unwrap_err()["code"], json!(ResponseError::INVALID_PARAMS));
    assert_eq!(unknown.unwrap_err()["code"], json!(ResponseError::INVALID_PARAMS));
    assert_eq!(refused.unwrap_err()["code"], json!(ResponseError::INTERNAL_ERROR));
}

#[tokio::test]
async fn a_logout_removes_the_saved_login_and_the_pushed_token_and_cancels_a_login_in_progress() {
    let place = Place::new(
        "rpc",
        "a_logout_removes_the_saved_login_and_the_pushed_token_and_cancels_a_login_in_progress",
    );
    std::fs::create_dir_all(&place.paths.data).unwrap();
    let logins = json!({
        "xai-grok": { "access_token": "a", "refresh_token": "r", "expires_at": 0 },
        "openai-codex": { "access_token": "b", "refresh_token": "s", "expires_at": 0 },
    });
    std::fs::write(place.paths.data.join("auth.json"), logins.to_string()).unwrap();
    let answers = Answers::default();
    answers.push(200, LOGIN_START);
    let mut client = Client::start_with(&place, Box::new(ScriptedTransport::default()), answers);
    client.initialize().await;
    // A session of the provider makes its credential source, which keeps the pushed token.
    let mut settings = settings(&place);
    settings["model"] = json!({ "provider": "openai-codex", "model": "gpt-5.5" });
    client.call("session/new", settings).await.unwrap();
    let token = json!({ "provider": "openai-codex", "accessToken": "pushed", "expiresAt": u64::MAX / 2 });
    client.call("credential/update", token).await.unwrap();

    let login = client
        .call("auth/login", json!({ "provider": "xai-grok" }))
        .await
        .unwrap()["loginId"]
        .clone();
    let logout = client.request("auth/logout", json!({ "provider": "xai-grok" })).await;
    let mut messages = client.until(|message| finished(message, &login)).await;
    if !messages.iter().any(|message| message["id"] == json!(logout)) {
        messages.extend(client.until(|message| message["id"] == json!(logout)).await);
    }
    let removed = messages.iter().find(|message| message["id"] == json!(logout)).unwrap()["result"].clone();
    let cancelled = messages.iter().find(|message| finished(message, &login)).unwrap()["params"]["outcome"].clone();
    let pushed = client.call("auth/logout", json!({ "provider": "openai-codex" })).await;
    let nothing = client.call("auth/logout", json!({ "provider": "xai-grok" })).await;
    let unknown = client.call("auth/logout", json!({ "provider": "nobody" })).await;
    let catalog = client.call("catalog/list", json!({ "all": true })).await.unwrap();
    client.end().await;

    assert_eq!(
        (removed, pushed.unwrap(), nothing.unwrap()),
        (json!({}), json!({}), json!({}))
    );
    assert_eq!(cancelled, json!({ "kind": "cancelled" }));
    assert_eq!(unknown.unwrap_err()["code"], json!(ResponseError::INVALID_PARAMS));
    let states = provider_states(&catalog);
    assert_eq!(states["xai-grok"], json!({ "kind": "needs_login" }));
    assert_eq!(states["openai-codex"], json!({ "kind": "needs_login" }));
    let saved: Value = serde_json::from_slice(&std::fs::read(place.paths.data.join("auth.json")).unwrap()).unwrap();
    assert_eq!(saved, json!({}));
}

/// The content of `auth.json` in `place`.
fn saved_auth(place: &Place) -> Value {
    serde_json::from_slice(&std::fs::read(place.paths.data.join("auth.json")).unwrap()).unwrap()
}

/// A new session of `provider/model`.
async fn new_session(client: &mut Client, place: &Place, provider: &str, model: &str) -> Value {
    let mut settings = settings(place);
    settings["model"] = json!({ "provider": provider, "model": model });
    client.call("session/new", settings).await.unwrap()["sessionId"].clone()
}

/// Run one turn of `session`, and wait for its end.
async fn run_turn(client: &mut Client, session: &Value) {
    client.request("session/input", input_params(session, "hi")).await;
    client.until(is_idle).await;
}

#[tokio::test]
async fn a_stored_api_key_serves_the_next_turn_until_a_logout_and_the_variable_wins_over_it() {
    let place = Place::new(
        "rpc",
        "a_stored_api_key_serves_the_next_turn_until_a_logout_and_the_variable_wins_over_it",
    );
    std::fs::create_dir_all(&place.paths.data).unwrap();
    let login = json!({ "xai-grok": { "access_token": "a", "refresh_token": "r", "expires_at": 0 } });
    std::fs::write(place.paths.data.join("auth.json"), login.to_string()).unwrap();
    let transport = ScriptedTransport::new([text_reply("one"), text_reply("two"), text_reply("three")]);
    let mut client = Client::initialized(&place, Box::new(transport.clone())).await;
    let key = |provider: &str, key: &str| json!({ "provider": provider, "apiKey": key });

    let stored = client.call("auth/set_api_key", key("anthropic", "first-key")).await;
    client
        .call("auth/set_api_key", key("minimax", "unused-key"))
        .await
        .unwrap();
    let saved = saved_auth(&place);
    let ready = client.call("catalog/list", json!({})).await.unwrap();
    let anthropic = new_session(&mut client, &place, "anthropic", "claude-sonnet-4-5").await;
    run_turn(&mut client, &anthropic).await;
    client
        .call("auth/set_api_key", key("anthropic", "second-key"))
        .await
        .unwrap();
    run_turn(&mut client, &anthropic).await;
    let minimax = new_session(&mut client, &place, "minimax", "MiniMax-M3").await;
    run_turn(&mut client, &minimax).await;
    client
        .call("auth/logout", json!({ "provider": "anthropic" }))
        .await
        .unwrap();
    let after = client.call("catalog/list", json!({ "all": true })).await.unwrap();
    let mut settings = settings(&place);
    settings["model"] = json!({ "provider": "anthropic", "model": "claude-sonnet-4-5" });
    let refused = client.call("session/new", settings).await;
    client.end().await;

    assert_eq!(stored, Ok(json!({})));
    assert_eq!(saved["anthropic"], json!({ "api_key": "first-key" }));
    assert_eq!(saved["xai-grok"], login["xai-grok"]);
    let states = provider_states(&ready);
    assert_eq!(states["anthropic"], json!({ "kind": "ready" }));
    assert_eq!(states["xai-grok"], json!({ "kind": "ready" }));
    assert_eq!(
        transport.header("x-api-key"),
        [Some("first-key".to_owned()), Some("second-key".to_owned()), None]
    );
    assert_eq!(
        transport.header("Authorization"),
        [None, None, Some("Bearer test-key".to_owned())]
    );
    assert_eq!(
        provider_states(&after)["anthropic"],
        json!({ "kind": "needs_api_key", "variable": "ANTHROPIC_API_KEY" })
    );
    assert_eq!(refused.unwrap_err()["code"], json!(ResponseError::INVALID_PARAMS));
    let saved = saved_auth(&place);
    let providers: Vec<&String> = saved.as_object().unwrap().keys().collect();
    assert_eq!(providers, ["minimax", "xai-grok"]);
}

#[tokio::test]
async fn an_api_key_for_a_provider_without_a_key_variable_or_a_bad_key_is_refused() {
    let place = Place::new(
        "rpc",
        "an_api_key_for_a_provider_without_a_key_variable_or_a_bad_key_is_refused",
    );
    std::fs::create_dir_all(&place.paths.config).unwrap();
    let providers = r#"{ "providers": [{
        "id": "local", "base_url": "http://127.0.0.1:8080/v1",
        "endpoints": [{ "protocol": "anthropic_messages" }],
        "models": [{ "id": "small", "limits": { "max_output_tokens": 4096 } }]
    }] }"#;
    std::fs::write(place.paths.config.join("providers.json"), providers).unwrap();
    let mut client = Client::initialized(&place, Box::new(ScriptedTransport::default())).await;
    let key = |provider: &str, key: &str| json!({ "provider": provider, "apiKey": key });

    let mut refusals = Vec::new();
    for params in [
        key("nobody", "k"),
        key("xai-grok", "k"),
        key("local", "k"),
        key("anthropic", ""),
        key("anthropic", "k\n"),
    ] {
        refusals.push(client.call("auth/set_api_key", params).await.unwrap_err());
    }
    client.end().await;

    let texts: Vec<(&Value, &str)> = refusals
        .iter()
        .map(|error| (&error["code"], error["message"].as_str().unwrap()))
        .collect();
    let invalid = json!(ResponseError::INVALID_PARAMS);
    let bad_key = "apiKey: send a value that is not empty and has no control character";
    assert_eq!(
        texts,
        [
            (&invalid, "yuke has no provider nobody"),
            (&invalid, "xai-grok takes a login, not an API key: send auth/login"),
            (&invalid, "local takes no API key"),
            (&invalid, bad_key),
            (&invalid, bad_key),
        ]
    );
    assert!(!place.paths.data.join("auth.json").exists());
}
