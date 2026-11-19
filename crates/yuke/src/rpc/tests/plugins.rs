//! The plugin manager over the protocol: a profile with a Git plugin that is not installed, its sync, and the reload
//! that loads it.

use super::*;
use yuke_testing::commit_plugin;

#[tokio::test(flavor = "local")]
async fn a_server_starts_without_a_missing_git_plugin_and_a_sync_and_a_reload_load_it() {
    let place = Place::new("rpc", "plugins_sync");
    let remote = place.work.join("remote");
    let commit = commit_plugin(&remote, "clock", "first");
    let url = remote.to_string_lossy().into_owned();
    std::fs::create_dir_all(&place.paths.config).unwrap();
    let config = json!({ "plugins": [{ "git": url, "folder": "plugins/clock" }] });
    std::fs::write(place.paths.config.join("config.json"), config.to_string()).unwrap();

    let mut client = Client::start(&place, Box::new(ScriptedTransport::new([])));
    let id = client
        .request(
            "initialize",
            json!({ "protocolVersion": 1, "clientInfo": { "name": "test", "version": "1" } }),
        )
        .await;
    let started = client.until(|message| is_response(message, id)).await;
    let listed = client.call("plugin/list", json!({})).await;
    let synced = client.call("plugin/sync", json!({})).await.unwrap();
    let reloaded = client.call("profile/reload", json!({})).await;
    let loaded = client.call("plugin/list", json!({})).await;

    let notice = started.iter().find(|message| message["method"] == "notice").unwrap();
    assert_eq!(
        notice["params"]["text"],
        "Plugin clock did not load: it is not installed · /plugins or `yuke plugin sync` installs it"
    );
    let source = json!({ "git": url, "folder": "plugins/clock" });
    assert_eq!(
        listed,
        Ok(
            json!({ "plugins": [{ "source": source, "state": { "kind": "notInstalled" }, "load": { "kind": "pending" } }] })
        )
    );
    assert_eq!(synced, json!({ "written": true }));
    assert_eq!(reloaded, Ok(json!({})));
    assert_eq!(
        loaded,
        Ok(
            json!({ "plugins": [{ "source": source, "name": "clock", "state": { "kind": "installed", "commit": commit }, "load": { "kind": "loaded" } }] })
        )
    );
    client.end().await;
}

#[tokio::test(flavor = "local")]
async fn a_plugin_that_does_not_load_at_the_start_lists_as_failed_with_its_reason() {
    let place = Place::new("rpc", "plugins_not_loaded");
    place.plugin("broken", "export function apply() { throw new Error('no'); }");
    place.plugin("fine", "export function apply() {}");
    std::fs::write(
        place.paths.config.join("config.json"),
        r#"{ "plugins": ["broken", "fine"] }"#,
    )
    .unwrap();
    let mut client = Client::initialized(&place, Box::new(ScriptedTransport::new([]))).await;

    let listed = client.call("plugin/list", json!({})).await.unwrap();

    assert_eq!(listed["plugins"][1]["load"], json!({ "kind": "loaded" }));
    assert_eq!(listed["plugins"][0]["load"]["kind"], "failed");
    let error = listed["plugins"][0]["load"]["error"].as_str().unwrap();
    assert!(error.starts_with("Plugin broken did not load: Error: no"), "{error}");
    client.end().await;
}

#[tokio::test(flavor = "local")]
async fn a_bad_plugin_request_is_invalid_params_and_a_failed_git_call_is_an_internal_error() {
    let place = Place::new("rpc", "plugins_error_codes");
    let missing = place.work.join("no-such-repository").to_string_lossy().into_owned();
    let mut client = Client::initialized(&place, Box::new(ScriptedTransport::new([]))).await;

    let unknown = client
        .call("plugin/remove", json!({ "name": "nope" }))
        .await
        .unwrap_err();
    let failed = client.call("plugin/find", json!({ "git": missing })).await.unwrap_err();

    assert_eq!(unknown["code"], json!(ResponseError::INVALID_PARAMS));
    assert_eq!(failed["code"], json!(ResponseError::INTERNAL_ERROR));
    client.end().await;
}

// The manager tests check the files that an add and a remove change. This test checks the messages.
#[tokio::test(flavor = "local")]
async fn plugin_find_add_and_remove_answer_in_their_wire_shapes() {
    let place = Place::new("rpc", "plugins_add_remove");
    let remote = place.work.join("remote");
    let commit = commit_plugin(&remote, "clock", "first");
    let url = remote.to_string_lossy().into_owned();
    std::fs::create_dir_all(&place.paths.config).unwrap();
    let mut client = Client::initialized(&place, Box::new(ScriptedTransport::new([]))).await;

    let found = client.call("plugin/find", json!({ "git": url })).await;
    let added = client
        .call("plugin/add", json!({ "git": url, "names": ["clock"] }))
        .await;
    let removed = client.call("plugin/remove", json!({ "name": "clock" })).await;

    assert_eq!(
        found,
        Ok(json!({ "plugins": [{ "name": "clock", "folder": "plugins/clock" }] }))
    );
    assert_eq!(added, Ok(json!({ "plugins": [{ "name": "clock", "commit": commit }] })));
    assert_eq!(removed, Ok(json!({})));
    client.end().await;
}
