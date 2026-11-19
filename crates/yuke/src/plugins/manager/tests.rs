use serde_json::{Value, json};

use super::*;
use yuke_testing::commit_plugin;

/// The lock entry of `source` at `commit`.
fn at(source: PluginSource, commit: &str) -> LockedPlugin {
    LockedPlugin {
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
    git_source(url, Some("plugins/clock"), reference.map(str::to_owned))
}

#[tokio::test(flavor = "local")]
async fn sync_keeps_a_locked_commit_after_its_branch_moves_and_an_applied_update_moves_it() {
    let (root, paths) = place("lifecycle");
    let first = commit(&root, "first");
    let url = clock(&root, None).git;
    write_config(
        &paths,
        &json!([{ "git": url, "folder": "plugins/clock", "ref": "main" }]),
    );

    let written = sync(&paths, false, &|_| {}).await.unwrap().written;
    let synced = Lock::read(&paths.config).unwrap().commits;
    let second = commit(&root, "feat: seconds");
    let written_again = sync(&paths, false, &|_| {}).await.unwrap().written;
    let changes = check(&paths, &PluginTarget::All, &|_| {}).await.unwrap().changes;
    apply(&paths, &[at(changes[0].source.clone(), &changes[0].new)])
        .await
        .unwrap();
    let after_apply = check(&paths, &PluginTarget::All, &|_| {}).await.unwrap().changes;

    assert_eq!(synced, [(clock(&root, Some("main")), first.clone())].into());
    assert!(written);
    assert!(!written_again);
    assert_eq!(changes.len(), 1);
    assert_eq!(
        (changes[0].old.as_str(), changes[0].new.as_str()),
        (first.as_str(), second.as_str())
    );
    assert_eq!(
        changes[0].log,
        PluginLog::Commits {
            commits: vec![format!("{} feat: seconds", &second[..7])]
        }
    );
    assert!(after_apply.is_empty(), "{after_apply:?}");
    assert_eq!(
        Lock::read(&paths.config).unwrap().commits[&clock(&root, Some("main"))],
        second
    );
}

#[tokio::test(flavor = "local")]
async fn a_new_plugin_locks_at_its_ref_and_a_locked_plugin_keeps_its_commit() {
    let (root, paths) = place("new_plugin");
    let first = commit(&root, "first");
    let url = clock(&root, None).git;
    write_config(
        &paths,
        &json!([{ "git": url, "folder": "plugins/clock", "ref": "main" }]),
    );
    sync(&paths, false, &|_| {}).await.unwrap();
    let second = commit(&root, "second");
    write_config(
        &paths,
        &json!([
            { "git": url, "folder": "plugins/clock", "ref": "main" },
            { "git": url, "folder": "plugins/clock" },
        ]),
    );

    let written = sync(&paths, false, &|_| {}).await.unwrap().written;

    assert_eq!(
        Lock::read(&paths.config).unwrap().commits,
        [(clock(&root, Some("main")), first), (clock(&root, None), second)].into()
    );
    assert!(written);
}

#[tokio::test(flavor = "local")]
async fn a_check_gives_only_the_plugins_whose_folder_changed_with_the_commits_of_that_folder() {
    let (root, paths) = place("folder_log");
    let remote = root.join("remote");
    commit(&root, "first clock");
    let first = commit_plugin(&remote, "weather", "first weather");
    let url = clock(&root, None).git;
    add(&paths, &url, &["clock".to_owned(), "weather".to_owned()], None, &|_| {})
        .await
        .unwrap();
    let wind = commit_plugin(&remote, "weather", "feat: wind");
    let gusts = commit_plugin(&remote, "weather", "fix: gusts");

    let changes = check(&paths, &PluginTarget::All, &|_| {}).await.unwrap().changes;

    assert_eq!(changes.len(), 1, "{changes:?}");
    assert_eq!(
        (
            changes[0].name.as_str(),
            changes[0].old.as_str(),
            changes[0].new.as_str()
        ),
        ("weather", first.as_str(), gusts.as_str())
    );
    assert_eq!(
        changes[0].log,
        PluginLog::Commits {
            commits: vec![
                format!("{} fix: gusts", &gusts[..7]),
                format!("{} feat: wind", &wind[..7])
            ]
        }
    );
}

#[tokio::test(flavor = "local")]
async fn a_check_names_a_plugin_that_it_cannot_check_and_checks_the_others() {
    let (root, paths) = place("check_failures");
    let first = commit(&root, "first");
    let other = root.join("other");
    commit_plugin(&other, "weather", "first weather");
    // The plugin that fails comes first, so the check of the next one shows that the check goes on.
    add(&paths, &other.to_string_lossy(), &[], None, &|_| {}).await.unwrap();
    add(&paths, &clock(&root, None).git, &[], None, &|_| {}).await.unwrap();
    let second = commit(&root, "feat: seconds");
    fs::remove_dir_all(&other).unwrap();

    let checked = check(&paths, &PluginTarget::All, &|_| {}).await.unwrap();

    assert_eq!(checked.changes.len(), 1);
    let change = &checked.changes[0];
    assert_eq!(
        (change.name.as_str(), change.old.as_str(), change.new.as_str()),
        ("clock", first.as_str(), second.as_str())
    );
    let failed: Vec<&str> = checked.failed.iter().map(|plugin| plugin.name.as_str()).collect();
    assert_eq!(failed, ["weather"]);
    assert_ne!(checked.failed[0].error, "");
}

#[tokio::test(flavor = "local")]
async fn an_update_by_a_name_that_no_git_plugin_has_fails() {
    let (root, paths) = place("unknown_name");
    commit(&root, "first");
    write_config(
        &paths,
        &json!([{ "git": clock(&root, None).git, "folder": "plugins/clock" }]),
    );
    sync(&paths, false, &|_| {}).await.unwrap();

    let error = check(
        &paths,
        &PluginTarget::Names {
            names: vec!["nope".to_owned()],
        },
        &|_| {},
    )
    .await
    .unwrap_err();

    assert_eq!(
        error,
        "no installed Git plugin of config.json has the name 'nope': see `yuke plugin list`"
    );
}

#[tokio::test(flavor = "local")]
async fn a_sync_installs_and_locks_the_plugins_that_install_and_names_the_others() {
    let (root, paths) = place("sync_failures");
    let first = commit(&root, "first");
    let url = clock(&root, None).git;
    write_config(
        &paths,
        &json!([
            { "git": url, "folder": "plugins/sun", "ref": "v9" },
            { "git": url, "folder": "plugins/clock" },
            // The commit is on disk after the clock, and it has no folder of the moon.
            { "git": url, "folder": "plugins/moon" },
        ]),
    );

    let error = sync(&paths, false, &|_| {}).await.unwrap_err();

    assert_eq!(
        error,
        "plugin sun: no branch or tag 'v9'; plugin moon: the commit has no plugins/moon/plugin.json"
    );
    assert_eq!(
        Lock::read(&paths.config).unwrap().commits,
        [(clock(&root, None), first.clone())].into()
    );
    assert!(git_folder(&paths.data, &url, &first).is_dir());
}

#[tokio::test(flavor = "local")]
async fn a_locked_sync_fails_and_changes_nothing_when_the_lock_misses_a_plugin() {
    let (root, paths) = place("locked");
    commit(&root, "first");
    let url = clock(&root, None).git;
    write_config(&paths, &json!([{ "git": url, "folder": "plugins/clock" }]));

    let error = sync(&paths, true, &|_| {}).await.unwrap_err();

    assert_eq!(
        error,
        "plugins.lock does not match the Git plugins of config.json: run `yuke plugin sync`"
    );
    assert!(!paths.config.join("plugins.lock").exists());
    assert!(!paths.data.join("git").join(repository_key(&url)).exists());
}

#[tokio::test(flavor = "local")]
async fn a_locked_sync_installs_the_locked_commit_and_keeps_the_lock_text() {
    let (root, paths) = place("locked_match");
    let first = commit(&root, "first");
    let url = clock(&root, None).git;
    write_config(&paths, &json!([{ "git": url, "folder": "plugins/clock" }]));
    // A lock that the user formats by hand differs from the text that a write gives.
    let text = json!({ "plugins": [{ "git": url, "folder": "plugins/clock", "commit": first }] }).to_string();
    fs::write(paths.config.join("plugins.lock"), &text).unwrap();

    let written = sync(&paths, true, &|_| {}).await.unwrap().written;

    assert!(!written);
    assert_eq!(fs::read_to_string(paths.config.join("plugins.lock")).unwrap(), text);
    assert!(git_folder(&paths.data, &url, &first).is_dir());
}

#[tokio::test(flavor = "local")]
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

    let written = sync(&paths, false, &|_| {}).await.unwrap().written;

    assert!(written);
    assert!(paths.config.join("plugins.lock").is_symlink());
    let text = fs::read_to_string(root.join("dotfiles/plugins.lock")).unwrap();
    assert!(text.contains(&first), "{text}");
}

#[tokio::test(flavor = "local")]
async fn an_apply_with_a_short_commit_or_a_plugin_out_of_the_lock_fails_and_keeps_the_lock() {
    let (root, paths) = place("apply_bad");
    let first = commit(&root, "first");
    write_config(
        &paths,
        &json!([{ "git": clock(&root, None).git, "folder": "plugins/clock" }]),
    );
    sync(&paths, false, &|_| {}).await.unwrap();

    let short = apply(&paths, &[at(clock(&root, None), "3f9c1a2")]).await.unwrap_err();
    let removed = apply(&paths, &[at(clock(&root, Some("v2")), &"b".repeat(40))])
        .await
        .unwrap_err();

    let label = format!("plugin {} (folder plugins/clock", clock(&root, None).git);
    assert_eq!(short, format!("{label}): '3f9c1a2' is not a full commit id"));
    assert_eq!(removed, format!("{label}, ref v2) is not in plugins.lock"));
    assert_eq!(Lock::read(&paths.config).unwrap().commits[&clock(&root, None)], first);
}

#[tokio::test(flavor = "local")]
async fn find_lists_the_plugins_of_a_repository_and_add_takes_them_by_name() {
    let (root, paths) = place("find_add");
    commit(&root, "first");
    let last = commit_plugin(&root.join("remote"), "weather", "second");
    let url = clock(&root, None).git;

    let found = find(&paths, &url).await.unwrap();
    let unnamed = add(&paths, &url, &[], None, &|_| {}).await.unwrap_err();
    let unknown = add(&paths, &url, &["sun".to_owned()], None, &|_| {}).await.unwrap_err();
    let added = add(&paths, &url, &["weather".to_owned(), "clock".to_owned()], None, &|_| {})
        .await
        .unwrap();
    let listed = list(&paths, &[]).unwrap();

    let at_folder = |name: &str| FoundPlugin {
        name: name.to_owned(),
        folder: Some(format!("plugins/{name}")),
    };
    assert_eq!(found, [at_folder("clock"), at_folder("weather")]);
    assert_eq!(
        unnamed,
        format!("{url} has 2 plugins: clock, weather: name the ones to add")
    );
    assert_eq!(unknown, format!("{url} has no plugin 'sun': it has clock, weather"));
    let names: Vec<&str> = added.iter().map(|plugin| plugin.name.as_str()).collect();
    assert_eq!(names, ["weather", "clock"]);
    assert!(added.iter().all(|plugin| plugin.commit == last));
    let states: Vec<(Option<&str>, &PluginState, &PluginLoad)> = listed
        .iter()
        .map(|plugin| (plugin.name.as_deref(), &plugin.state, &plugin.load))
        .collect();
    let installed = PluginState::Installed { commit: last.clone() };
    assert_eq!(
        states,
        [
            (Some("weather"), &installed, &PluginLoad::Pending),
            (Some("clock"), &installed, &PluginLoad::Pending),
        ]
    );
}

#[tokio::test(flavor = "local")]
async fn an_added_plugin_joins_config_json_and_the_lock_and_a_removed_one_leaves_both_with_the_comments() {
    let (root, paths) = place("add_remove");
    let first = commit(&root, "first");
    let url = clock(&root, None).git;
    let original = "{\n  // mine\n  \"plugins\": [\n    \"./notes\"\n  ]\n}\n";
    fs::write(paths.config.join("config.json"), original).unwrap();
    let added = add(&paths, &url, &[], Some("main"), &|_| {}).await.unwrap();
    let text = fs::read_to_string(paths.config.join("config.json")).unwrap();
    let locked = Lock::read(&paths.config).unwrap();
    let again = add(&paths, &url, &[], None, &|_| {}).await.unwrap_err();
    remove(&paths, "clock").await.unwrap();
    let after = fs::read_to_string(paths.config.join("config.json")).unwrap();
    let unlocked = Lock::read(&paths.config).unwrap();
    let unknown = remove(&paths, "nope").await.unwrap_err();
    fs::create_dir_all(paths.config.join("clock")).unwrap();
    fs::write(paths.config.join("clock/plugin.json"), r#"{ "name": "clock" }"#).unwrap();
    fs::write(paths.config.join("config.json"), r#"{ "plugins": ["./clock"] }"#).unwrap();
    let clash = add(&paths, &url, &[], None, &|_| {}).await.unwrap_err();

    let main = clock(&root, Some("main"));
    assert_eq!(
        added,
        [AddedPlugin {
            name: "clock".to_owned(),
            commit: first.clone(),
        }]
    );
    let url_text = Value::from(url.as_str()).to_string();
    assert_eq!(
        text,
        format!(
            "{{\n  // mine\n  \"plugins\": [\n    \"./notes\",\n    {{\"git\":{url_text},\"folder\":\"plugins/clock\",\"ref\":\"main\"}}\n  ]\n}}\n"
        )
    );
    assert_eq!(locked.commits[&main], first);
    assert_eq!(again, "plugin clock: config.json has a plugin of this name already");
    assert_eq!(after, original);
    assert!(unlocked.commits.is_empty());
    assert_eq!(
        unknown,
        "no plugin of config.json has the name 'nope': see `yuke plugin list`"
    );
    assert_eq!(clash, "plugin clock: config.json has a plugin of this name already");
    assert_eq!(
        fs::read_to_string(paths.config.join("config.json")).unwrap(),
        r#"{ "plugins": ["./clock"] }"#
    );
}

#[tokio::test(flavor = "local")]
async fn a_plugin_with_an_invalid_entry_keeps_its_name_for_list_and_remove() {
    let (_, paths) = place("invalid_entry");
    fs::create_dir_all(paths.config.join("clock")).unwrap();
    fs::write(
        paths.config.join("clock/plugin.json"),
        json!({ "name": "clock", "extensions": { "sh.yuke": { "entry": "main.txt" } } }).to_string(),
    )
    .unwrap();
    write_config(&paths, &json!(["./clock"]));

    let listed = list(&paths, &[]).unwrap();
    remove(&paths, "clock").await.unwrap();

    assert_eq!(
        listed,
        [ManagedPlugin {
            source: PluginOrigin::Folder("./clock".to_owned()),
            name: Some("clock".to_owned()),
            state: PluginState::Local,
            load: PluginLoad::Failed {
                error: "plugin clock did not load: entry: 'main.txt' is not a .ts or a .js file".to_owned(),
            },
        }]
    );
    assert_eq!(
        fs::read_to_string(paths.config.join("config.json")).unwrap(),
        r#"{"plugins":[]}"#
    );
}
