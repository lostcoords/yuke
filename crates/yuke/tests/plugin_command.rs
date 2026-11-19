//! The `yuke plugin` command: its output and its exit status, with a local Git repository and an empty profile.
#![expect(clippy::unwrap_used, reason = "a test fails by panicking")]

use std::path::Path;
use std::process::{Command, Output};

use yuke_testing::commit_plugin;

/// A repository in `root/remote` with the plugins `names` in `plugins/<name>`. Gives its URL and its last commit.
fn repository(root: &Path, names: &[&str]) -> (String, String) {
    let remote = root.join("remote");
    let mut last = String::new();
    for name in names {
        last = commit_plugin(&remote, name, name);
    }
    (remote.to_string_lossy().into_owned(), last)
}

/// Run `yuke plugin` with `args` and the profile of `root`.
fn yuke(root: &Path, args: &[&str]) -> Output {
    Command::new(env!("CARGO_BIN_EXE_yuke"))
        .arg("plugin")
        .args(args)
        .env("XDG_CONFIG_HOME", root.join("config"))
        .env("XDG_DATA_HOME", root.join("data"))
        .env("XDG_CACHE_HOME", root.join("cache"))
        .env_remove("YUKE_APPNAME")
        .output()
        .unwrap()
}

/// The standard output and the standard error of `output` as text.
fn texts(output: &Output) -> (String, String) {
    (
        String::from_utf8_lossy(&output.stdout).into_owned(),
        String::from_utf8_lossy(&output.stderr).into_owned(),
    )
}

#[test]
fn add_takes_the_plugins_of_a_repository_by_name_and_list_and_remove_show_them() {
    let root = yuke_testing::folder("command", "plugin_add_list_remove");
    let (url, commit) = repository(&root, &["clock", "weather"]);
    let short = &commit[..7];

    let unnamed = yuke(&root, &["add", &url]);
    // A name that the command repeats adds the plugin once.
    let added = yuke(&root, &["add", &url, "weather", "clock", "weather"]);
    let listed = yuke(&root, &["list"]);
    let removed = yuke(&root, &["remove", "clock"]);
    let left = yuke(&root, &["list"]);

    assert_eq!(unnamed.status.code(), Some(1));
    assert!(texts(&unnamed).1.starts_with("yuke: "), "{:?}", texts(&unnamed));
    // The two plugins share one commit, so one download serves both.
    assert_eq!(
        texts(&added),
        (
            format!("Added weather at {short}\nAdded clock at {short}\nRun /reload in open sessions.\n"),
            "Installing weather…\n".to_owned()
        )
    );
    assert_eq!(
        texts(&listed).0,
        format!(
            "NAME     STATE              SOURCE\n\
             weather  installed {short}  {url} (folder plugins/weather)\n\
             clock    installed {short}  {url} (folder plugins/clock)\n"
        )
    );
    assert_eq!(
        texts(&removed).0,
        "Removed clock. Its files stay on disk. Run /reload in open sessions.\n"
    );
    assert_eq!(
        texts(&left).0,
        format!("NAME     STATE              SOURCE\nweather  installed {short}  {url} (folder plugins/weather)\n")
    );
}

#[test]
fn list_shows_why_a_plugin_does_not_load_and_how_to_install_a_missing_one() {
    let root = yuke_testing::folder("command", "plugin_list_problems");
    std::fs::create_dir_all(root.join("config/yuke/broken")).unwrap();
    std::fs::write(
        root.join("config/yuke/broken/plugin.json"),
        r#"{ "name": "broken", "extensions": { "sh.yuke": { "entry": "main.py" } } }"#,
    )
    .unwrap();
    std::fs::write(
        root.join("config/yuke/config.json"),
        r#"{ "plugins": ["./broken", { "git": "https://h/tools", "folder": "plugins/sun" }] }"#,
    )
    .unwrap();

    let listed = yuke(&root, &["list"]);

    assert_eq!(listed.status.code(), Some(0));
    assert_eq!(
        texts(&listed).0,
        "NAME    STATE          SOURCE\n\
         broken  failed         ./broken\n\
         \x20       Plugin broken did not load: entry: 'main.py' is not a .ts or a .js file\n\
         sun     not installed  https://h/tools (folder plugins/sun)\n\
         `yuke plugin sync` installs the plugins that are not installed.\n"
    );
}
