use std::process::Command;

use serde_json::{Value, json};

use super::*;

/// A new empty place for the test `name`, with the folders of a profile and a repository `remote` on branch `main`.
fn place(name: &str) -> (PathBuf, Paths) {
    let root = std::env::temp_dir().join(format!("yuke-manager-tests-{}/{name}", std::process::id()));
    if root.exists() {
        fs::remove_dir_all(&root).unwrap();
    }
    fs::create_dir_all(root.join("config")).unwrap();
    let root = root.canonicalize().unwrap();
    run_git(&root, &["init", "--quiet", "-b", "main", "remote"]);
    let paths = Paths {
        config: root.join("config"),
        data: root.join("data"),
        cache: root.join("cache"),
    };
    (root, paths)
}

/// Run `git` with `args` in `folder`, and give its output.
fn run_git(folder: &Path, args: &[&str]) -> String {
    let output = Command::new("git")
        .current_dir(folder)
        .args([
            "-c",
            "user.name=test",
            "-c",
            "user.email=test@example.com",
            "-c",
            "commit.gpgsign=false",
        ])
        .args(["-c", "core.hooksPath=/dev/null"])
        .args(args)
        .output()
        .unwrap();
    assert!(output.status.success(), "{}", String::from_utf8_lossy(&output.stderr));
    String::from_utf8(output.stdout).unwrap().trim().to_owned()
}

/// Commit the plugin `clock` in `plugins/clock` of the repository at `root/remote`, with the subject `subject`. Gives
/// the commit id.
fn commit(root: &Path, subject: &str) -> String {
    let remote = root.join("remote");
    let folder = remote.join("plugins/clock");
    fs::create_dir_all(&folder).unwrap();
    fs::write(folder.join("plugin.json"), json!({ "name": "clock" }).to_string()).unwrap();
    fs::write(folder.join("notes.txt"), subject).unwrap();
    run_git(&remote, &["add", "."]);
    run_git(&remote, &["commit", "--quiet", "-m", subject]);
    run_git(&remote, &["rev-parse", "HEAD"])
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
fn clock(root: &Path, reference: Option<&str>) -> GitSource {
    let url = root.join("remote").to_string_lossy().into_owned();
    GitSource::new(url, Some("plugins/clock"), reference.map(str::to_owned)).unwrap()
}

#[tokio::test]
async fn sync_keeps_a_locked_commit_after_its_branch_moves_and_an_applied_update_moves_it() {
    let (root, paths) = place("lifecycle");
    let first = commit(&root, "first");
    let url = clock(&root, None).url;
    write_config(
        &paths,
        &json!([{ "git": url, "folder": "plugins/clock", "ref": "main" }]),
    );

    let (synced, written) = sync(&paths, false).await.unwrap();
    let second = commit(&root, "feat: seconds");
    let (again, written_again) = sync(&paths, false).await.unwrap();
    let config: Config = read_json(&paths.config.join("config.json")).unwrap().unwrap();
    let loaded = super::super::plugins(&paths.config, &config, &paths.data).unwrap();
    let changes = check(&paths, &Selection::All).await.unwrap();
    let before_apply = Lock::read(&paths.config).unwrap();
    let applied = apply(&paths, &changes).unwrap();
    let after_apply = check(&paths, &Selection::All).await.unwrap();

    assert_eq!(synced, [(clock(&root, Some("main")), first.clone())]);
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
    let log = changes[0].log.as_ref().unwrap();
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
    let url = clock(&root, None).url;
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

    let (synced, written) = sync(&paths, false).await.unwrap();

    assert_eq!(
        synced,
        [(clock(&root, Some("main")), first), (clock(&root, None), second)]
    );
    assert!(written);
}

#[tokio::test]
async fn an_update_by_a_name_that_no_git_plugin_has_fails() {
    let (root, paths) = place("unknown_name");
    commit(&root, "first");
    write_config(
        &paths,
        &json!([{ "git": clock(&root, None).url, "folder": "plugins/clock" }]),
    );
    sync(&paths, false).await.unwrap();

    let error = check(&paths, &Selection::Names(vec!["nope".to_owned()]))
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
    let url = clock(&root, None).url;
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
    let url = clock(&root, None).url;
    write_config(&paths, &json!([{ "git": url, "folder": "plugins/clock" }]));
    // A lock that the user formats by hand differs from the text that a write gives.
    let text =
        json!({ "version": 1, "plugins": [{ "git": url, "folder": "plugins/clock", "commit": first }] }).to_string();
    fs::write(paths.config.join("plugins.lock"), &text).unwrap();

    let (synced, written) = sync(&paths, true).await.unwrap();

    assert_eq!(synced, [(clock(&root, None), first.clone())]);
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
        &json!([{ "git": clock(&root, None).url, "folder": "plugins/clock" }]),
    );

    let (_, written) = sync(&paths, false).await.unwrap();

    assert!(written);
    assert!(paths.config.join("plugins.lock").is_symlink());
    let text = fs::read_to_string(root.join("dotfiles/plugins.lock")).unwrap();
    assert!(text.contains(&first), "{text}");
}
