//! The plugin manager over the protocol: a profile with a Git plugin that is not installed, its sync, and the reload
//! that loads it.

use super::*;
use crate::testing::commit_plugin;

#[tokio::test]
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
    let text = notice["params"]["message"].as_str().unwrap();
    assert!(
        text.starts_with("only the bundled plugins run, because the plugin list did not load: ")
            && text.ends_with("plugins.lock has no commit for this plugin: run `yuke plugin sync`"),
        "{text}"
    );
    let item = format!("{url} (folder plugins/clock)");
    assert_eq!(
        listed,
        Ok(json!({ "plugins": [{ "item": item, "loaded": false, "state": "not_locked" }] }))
    );
    assert_eq!(synced["plugins"][0]["commit"], json!(commit));
    assert_eq!(synced["written"], json!(true));
    assert_eq!(reloaded, Ok(json!({})));
    assert_eq!(
        loaded,
        Ok(
            json!({ "plugins": [{ "item": item, "name": "clock", "loaded": true, "state": "installed", "commit": commit }] })
        )
    );
    client.end().await;
}

#[tokio::test]
async fn a_plugin_that_does_not_load_at_the_start_lists_as_not_loaded() {
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

    let loaded: Vec<(&str, bool)> = listed["plugins"]
        .as_array()
        .unwrap()
        .iter()
        .map(|plugin| (plugin["name"].as_str().unwrap(), plugin["loaded"].as_bool().unwrap()))
        .collect();
    assert_eq!(loaded, [("broken", false), ("fine", true)]);
    client.end().await;
}
