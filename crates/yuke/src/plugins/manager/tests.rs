use serde_json::{Value, json};

use super::*;
use crate::testing::commit_plugin;

/// The sync result of `source` at `commit`.
fn at(source: PluginSource, commit: &str) -> SyncedPlugin {
    SyncedPlugin {
        source,
        commit: commit.to_owned(),
    }
}

/// A new empty place for the test `name`, with the folders of a profile.
fn place(name: &str) -> (PathBuf, Paths) {
    let root = std::env::temp_dir().join(format!("yuke-manager-tests-{}/{name}", std::process::id()));
    if root.exists() {
        fs::remove_dir_all(&root).unwrap();
    }
    fs::create_dir_all(root.join("config")).unwrap();
    let root = root.canonicalize().unwrap();
    let paths = Paths {
        config: root.join("config"),
        data: root.join("data"),
        cache: root.join("cache"),
    };
    (root, paths)
}

/// Commit the plugin `clock` of the repository at `root/remote`, with the subject `subject`. Gives the commit id.
fn commit(root: &Path, subject: &str) -> String {
    commit_plugin(&root.join("remote"), "clock", subject)
}

/// Write `config.json` of `paths` with the plugin items `plugins`.
fn write_config(paths: &Paths, plugins: &Value) {
    fs::write(
        paths.config.join("config.json"),
        json!({ "plugins": plugins }).to_string(),
    )
    .unwrap();
}

/// The source of the clock plugin of `root/remote` at `reference`.
fn clock(root: &Path, reference: Option<&str>) -> PluginSource {
    let url = root.join("remote").to_string_lossy().into_owned();
    git_source(url, Some("plugins/clock"), reference.map(str::to_owned)).unwrap()
}

#[tokio::test]
async fn sync_keeps_a_locked_commit_after_its_branch_moves_and_an_applied_update_moves_it() {
    let (root, paths) = place("lifecycle");
    let first = commit(&root, "first");
    let url = clock(&root, None).git;
    write_config(
        &paths,
        &json!([{ "git": url, "folder": "plugins/clock", "ref": "main" }]),
    );

    let SyncPluginsResult {
        plugins: synced,
        written,
    } = sync(&paths, false).await.unwrap();
    let second = commit(&root, "feat: seconds");
    let SyncPluginsResult {
        plugins: again,
        written: written_again,
    } = sync(&paths, false).await.unwrap();
    let config: Config = read_json(&paths.config.join("config.json")).unwrap().unwrap();
    let loaded = super::super::plugins(&paths.config, &config, &paths.data).unwrap();
    let changes = check(&paths, &PluginTarget::All).await.unwrap();
    let before_apply = Lock::read(&paths.config).unwrap();
    let applied = apply(&paths, &changes).await.unwrap();
    let after_apply = check(&paths, &PluginTarget::All).await.unwrap();

    assert_eq!(synced, [at(clock(&root, Some("main")), &first)]);
    assert!(written);
    assert_eq!(again, synced);
    assert!(!written_again);
    let clock_plugin = loaded.iter().find(|plugin| plugin.name == "clock").unwrap();
    assert_eq!(
        clock_plugin.origin,
        yuke_js::Origin::Folder {
            root: git_folder(&paths.data, &url, &first).join("plugins/clock"),
            entry: None,
        }
    );
    assert_eq!(changes.len(), 1);
    assert_eq!(
        (changes[0].old.as_str(), changes[0].new.as_str()),
        (first.as_str(), second.as_str())
    );
    let PluginLog::Commits(log) = &changes[0].log else {
        panic!("no log: {:?}", changes[0].log);
    };
    assert_eq!(log.len(), 1, "{log:?}");
    let (short, subject) = log[0].split_once(' ').unwrap();
    assert!(second.starts_with(short) && subject == "feat: seconds", "{log:?}");
    assert_eq!(before_apply.commits[&clock(&root, Some("main"))], first);
    assert!(applied);
    assert!(after_apply.is_empty(), "{after_apply:?}");
    assert_eq!(
        Lock::read(&paths.config).unwrap().commits[&clock(&root, Some("main"))],
        second
    );
}

#[tokio::test]
async fn a_new_plugin_locks_at_its_ref_and_a_locked_plugin_keeps_its_commit() {
    let (root, paths) = place("new_plugin");
    let first = commit(&root, "first");
    let url = clock(&root, None).git;
    write_config(
        &paths,
        &json!([{ "git": url, "folder": "plugins/clock", "ref": "main" }]),
    );
    sync(&paths, false).await.unwrap();
    let second = commit(&root, "second");
    write_config(
        &paths,
        &json!([
            { "git": url, "folder": "plugins/clock", "ref": "main" },
            { "git": url, "folder": "plugins/clock" },
        ]),
    );

    let SyncPluginsResult {
        plugins: synced,
        written,
    } = sync(&paths, false).await.unwrap();

    assert_eq!(
        synced,
        [at(clock(&root, Some("main")), &first), at(clock(&root, None), &second),]
    );
    assert!(written);
}

#[tokio::test]
async fn an_update_by_a_name_that_no_git_plugin_has_fails() {
    let (root, paths) = place("unknown_name");
    commit(&root, "first");
    write_config(
        &paths,
        &json!([{ "git": clock(&root, None).git, "folder": "plugins/clock" }]),
    );
    sync(&paths, false).await.unwrap();

    let error = check(&paths, &PluginTarget::Names(vec!["nope".to_owned()]))
        .await
        .unwrap_err();

    assert_eq!(
        error,
        "no installed Git plugin of config.json has the name 'nope': see `yuke plugin list`"
    );
}

#[tokio::test]
async fn a_locked_sync_fails_and_changes_nothing_when_the_lock_misses_a_plugin() {
    let (root, paths) = place("locked");
    commit(&root, "first");
    let url = clock(&root, None).git;
    write_config(&paths, &json!([{ "git": url, "folder": "plugins/clock" }]));

    let error = sync(&paths, true).await.unwrap_err();

    assert_eq!(
        error,
        "plugins.lock does not match the Git plugins of config.json: run `yuke plugin sync`"
    );
    assert!(!paths.config.join("plugins.lock").exists());
    assert!(!paths.data.join("git").join(repository_key(&url)).exists());
}

#[tokio::test]
async fn a_locked_sync_installs_the_locked_commit_and_keeps_the_lock_text() {
    let (root, paths) = place("locked_match");
    let first = commit(&root, "first");
    let url = clock(&root, None).git;
    write_config(&paths, &json!([{ "git": url, "folder": "plugins/clock" }]));
    // A lock that the user formats by hand differs from the text that a write gives.
    let text =
        json!({ "version": 1, "plugins": [{ "git": url, "folder": "plugins/clock", "commit": first }] }).to_string();
    fs::write(paths.config.join("plugins.lock"), &text).unwrap();

    let SyncPluginsResult {
        plugins: synced,
        written,
    } = sync(&paths, true).await.unwrap();

    assert_eq!(synced, [at(clock(&root, None), &first)]);
    assert!(!written);
    assert_eq!(fs::read_to_string(paths.config.join("plugins.lock")).unwrap(), text);
    assert!(git_folder(&paths.data, &url, &first).is_dir());
}

#[tokio::test]
async fn a_linked_lock_stays_a_link_and_its_target_gets_the_commits() {
    let (root, paths) = place("linked");
    let first = commit(&root, "first");
    // The target does not exist yet, as on the first sync of a new dotfiles repository.
    fs::create_dir_all(root.join("dotfiles")).unwrap();
    std::os::unix::fs::symlink(root.join("dotfiles/plugins.lock"), paths.config.join("plugins.lock")).unwrap();
    write_config(
        &paths,
        &json!([{ "git": clock(&root, None).git, "folder": "plugins/clock" }]),
    );

    let written = sync(&paths, false).await.unwrap().written;

    assert!(written);
    assert!(paths.config.join("plugins.lock").is_symlink());
    let text = fs::read_to_string(root.join("dotfiles/plugins.lock")).unwrap();
    assert!(text.contains(&first), "{text}");
}

#[tokio::test]
async fn an_apply_with_a_commit_that_is_not_a_full_id_fails_and_keeps_the_lock() {
    let (root, paths) = place("apply_short");
    let first = commit(&root, "first");
    write_config(
        &paths,
        &json!([{ "git": clock(&root, None).git, "folder": "plugins/clock" }]),
    );
    sync(&paths, false).await.unwrap();
    let change = PluginChange {
        name: "clock".to_owned(),
        source: clock(&root, None),
        old: first.clone(),
        new: "3f9c1a2".to_owned(),
        log: PluginLog::Commits(Vec::new()),
    };

    let error = apply(&paths, &[change]).await.unwrap_err();

    assert_eq!(
        error,
        format!(
            "plugin {} (folder plugins/clock): '3f9c1a2' is not a full commit id",
            clock(&root, None).git
        )
    );
    assert_eq!(Lock::read(&paths.config).unwrap().commits[&clock(&root, None)], first);
}
