//! The plugin manager over the protocol: a profile with a Git plugin that is not installed, its sync, and the reload
//! that loads it.

use super::*;
use crate::testing::commit_plugin;

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
        "plugin clock did not load: it is not installed: /plugins or `yuke plugin sync` installs it"
    );
    let source = json!({ "git": url, "folder": "plugins/clock" });
    assert_eq!(
        listed,
        Ok(
            json!({ "plugins": [{ "source": source, "state": { "kind": "notInstalled" }, "load": { "kind": "pending" } }] })
        )
    );
    assert_eq!(synced["plugins"][0]["commit"], json!(commit));
    assert_eq!(synced["written"], json!(true));
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
    assert!(error.starts_with("plugin broken did not load: Error: no"), "{error}");
    client.end().await;
}

#[tokio::test(flavor = "local")]
async fn plugin_add_writes_config_json_and_the_lock_and_plugin_remove_takes_both_back() {
    let place = Place::new("rpc", "plugins_add_remove");
    let remote = place.work.join("remote");
    let commit = commit_plugin(&remote, "clock", "first");
    let url = remote.to_string_lossy().into_owned();
    std::fs::create_dir_all(&place.paths.config).unwrap();
    std::fs::write(place.paths.config.join("config.json"), "{\n  // mine\n}\n").unwrap();
    let mut client = Client::initialized(&place, Box::new(ScriptedTransport::new([]))).await;

    let found = client.call("plugin/find", json!({ "git": url })).await;
    let added = client
        .call("plugin/add", json!({ "git": url, "names": ["clock"] }))
        .await;
    let listed = client.call("plugin/list", json!({})).await.unwrap();
    let removed = client.call("plugin/remove", json!({ "name": "clock" })).await;
    let config = std::fs::read_to_string(place.paths.config.join("config.json")).unwrap();
    let lock = std::fs::read_to_string(place.paths.config.join("plugins.lock")).unwrap();

    assert_eq!(
        found,
        Ok(json!({ "plugins": [{ "name": "clock", "folder": "plugins/clock" }] }))
    );
    assert_eq!(
        added,
        Ok(
            json!({ "plugins": [{ "name": "clock", "source": { "git": url, "folder": "plugins/clock" }, "commit": commit }] })
        )
    );
    assert_eq!(listed["plugins"][0]["state"]["kind"], json!("installed"));
    assert_eq!(removed, Ok(json!({})));
    assert!(config.contains("// mine"), "{config}");
    assert!(!config.contains("clock"), "{config}");
    assert!(!lock.contains(&commit), "{lock}");
    client.end().await;
}
