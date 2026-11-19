use std::path::PathBuf;

use crate::config::git_source;

use serde_json::json;

use super::*;

/// A new empty folder for the test `name`, with `config` and `data` folders.
fn place(name: &str) -> PathBuf {
    let root = std::env::temp_dir().join(format!("yuke-plugins-tests-{}/{name}", std::process::id()));
    if root.exists() {
        std::fs::remove_dir_all(&root).unwrap();
    }
    std::fs::create_dir_all(root.join("config")).unwrap();
    root.canonicalize().unwrap()
}

/// Write the plugin folder `folder` below `root` with the manifest text `manifest`.
fn write_plugin(root: &Path, folder: &str, manifest: &str) -> PathBuf {
    let folder = root.join(folder);
    std::fs::create_dir_all(&folder).unwrap();
    std::fs::write(folder.join("plugin.json"), manifest).unwrap();
    folder
}

/// The manifest of `name` with the yuke fields `fields`.
fn manifest(name: &str, fields: &Value) -> String {
    json!({ "name": name, "extensions": { "sh.yuke": fields } }).to_string()
}

/// The plugins of the folders `list`, in the config folder of `root`, with no bundled plugin.
fn load(root: &Path, list: &[&str]) -> Result<PluginList, String> {
    load_with(&[], root, list, &[])
}

/// The names of the plugins to load of `list`, in load order.
fn names(list: &PluginList) -> Vec<&str> {
    list.load.iter().map(|plugin| plugin.name.as_str()).collect()
}

/// The failure texts of the outcomes of `list`, in the order of `config.json`.
fn failures(list: &PluginList) -> Vec<String> {
    list.outcomes.iter().filter_map(Outcome::failure_text).collect()
}

/// The bundled plugins `bundled` that `disable` does not name, then the plugins of the folders `list`.
fn load_with(bundled: &[Bundled], root: &Path, list: &[&str], disable: &[&str]) -> Result<PluginList, String> {
    let config = Config {
        plugins: list
            .iter()
            .map(|&path| ConfigPlugin {
                source: PluginOrigin::Folder(path.to_owned()),
                options: Map::new(),
            })
            .collect(),
        disable: disable.iter().map(|&name| name.to_owned()).collect(),
        ..Config::default()
    };
    with_bundled(bundled, &root.join("config"), &config, &root.join("data"))
}

#[test]
fn the_list_gives_each_plugin_in_its_order_with_the_fields_of_its_manifest() {
    let root = place("fields");
    write_plugin(
        &root,
        "config/notes",
        r#"{
          // The standard fields and other extensions stay unread.
          "$schema": "https://agent-plugins.org/schemas/1.1.0/plugin.schema.json",
          "name": "notes",
          "version": "1.0.0",
          "extensions": {
            "sh.yuke": { "entry": "./index.ts", "provides": ["notes"] },
            "dev.other": { "anything": true }
          }
        }"#,
    );
    let reader = write_plugin(
        &root,
        "elsewhere/reader",
        &manifest("reader", &json!({ "uses": ["notes"] })),
    );

    let plugins = load(&root, &["notes", reader.to_str().unwrap()]).unwrap().load;
    create_data_folders(&plugins).unwrap();

    assert_eq!(
        plugins,
        [
            Plugin {
                name: "notes".to_owned(),
                origin: PluginCode::Folder {
                    root: root.join("config/notes"),
                    entry: Some(root.join("config/notes/./index.ts")),
                },
                data_dir: root.join("data/plugins/notes"),
                options: Map::new(),
                uses: Vec::new(),
                provides: vec!["notes".to_owned()],
            },
            Plugin {
                name: "reader".to_owned(),
                origin: PluginCode::Folder {
                    root: reader,
                    entry: None,
                },
                data_dir: root.join("data/plugins/reader"),
                options: Map::new(),
                uses: vec!["notes".to_owned()],
                provides: Vec::new(),
            },
        ]
    );
    assert!(root.join("data/plugins/notes").is_dir());
    assert!(root.join("data/plugins/reader").is_dir());
}

#[test]
fn a_bad_folder_or_manifest_skips_its_plugin_names_the_problem_and_the_others_load() {
    let root = place("bad");
    write_plugin(&root, "config/fine", &manifest("fine", &json!({})));
    let fields = |fields: Value| manifest("p", &fields);
    let cases = [
        ("{", "plugin.json"),
        (r#"{ "extensions": {} }"#, "missing field `name`"),
        (
            &manifest("Upper", &json!({})) as &str,
            "name: 'Upper' must be 1 to 64 lowercase letters, digits, '-', or '.', start and end with a letter or a \
             digit, and have no '--' or '..'",
        ),
        (&manifest("a--b", &json!({})), "name: 'a--b' must be"),
        (&manifest("-a", &json!({})), "name: '-a' must be"),
        (
            &fields(json!({ "activation": { "workspaceContains": "Cargo.toml" } })),
            "unknown field `activation`",
        ),
    ];

    for (index, (text, expected)) in cases.into_iter().enumerate() {
        let folder = format!("case{index}");
        write_plugin(&root, &format!("config/{folder}"), text);
        let list = load(&root, &[&folder, "fine"]).unwrap();
        let failures = failures(&list);
        // A manifest with a good name names the plugin, and the others name the folder.
        let label = if text.contains(r#""name":"p""#) { "p" } else { &folder };
        assert_eq!(names(&list), ["fine"]);
        assert_eq!(failures.len(), 1);
        assert!(
            failures[0].starts_with(&format!("Plugin {label} did not load: ")),
            "{}",
            failures[0]
        );
        assert!(failures[0].contains(expected), "{text}: {}", failures[0]);
    }
    std::fs::create_dir_all(root.join("config/empty")).unwrap();
    let list = load(&root, &["absent", "empty", "fine"]).unwrap();
    let failures = failures(&list);
    assert_eq!(names(&list), ["fine"]);
    assert!(
        failures[0].starts_with("Plugin absent did not load: "),
        "{}",
        failures[0]
    );
    assert!(failures[1].contains("plugin.json"), "{}", failures[1]);
}

#[test]
fn a_provider_loads_before_its_users_and_the_rest_keeps_the_list_order() {
    let root = place("order");
    write_plugin(
        &root,
        "config/notes",
        &manifest("notes", &json!({ "entry": "i.ts", "provides": ["notes"] })),
    );
    write_plugin(
        &root,
        "config/notes2",
        &manifest("notes2", &json!({ "entry": "i.ts", "provides": ["notes"] })),
    );
    write_plugin(
        &root,
        "config/reader",
        &manifest("reader", &json!({ "uses": ["notes"] })),
    );
    write_plugin(&root, "config/again", &manifest("reader", &json!({})));

    write_plugin(&root, "config/plain", &manifest("plain", &json!({})));
    let load = |list: &[&str]| load(&root, list).unwrap();

    assert_eq!(
        names(&load(&["reader", "plain", "notes"])),
        ["plain", "notes", "reader"]
    );
    assert_eq!(
        names(&load(&["notes", "reader", "plain"])),
        ["notes", "reader", "plain"]
    );
    let twice = load(&["notes", "notes2", "reader", "again"]);
    assert_eq!(names(&twice), ["notes", "reader"]);
    assert_eq!(
        failures(&twice),
        [
            "Plugin notes2 did not load: plugin notes provides 'notes' already",
            "Plugin reader did not load: another plugin of the list has this name",
        ]
    );
}

/// Two bundled plugins of a test. The second one provides `pairs`.
const BUNDLED_PAIR: &[Bundled] = &[
    Bundled {
        name: "first",
        module: "yuke:internal/bundled/first",
        uses: &[],
        provides: &[],
    },
    Bundled {
        name: "second",
        module: "yuke:internal/bundled/second",
        uses: &[],
        provides: &["pairs"],
    },
];

#[test]
fn a_bundled_plugin_uses_the_service_of_a_profile_plugin_that_replaces_its_provider() {
    let root = place("bundled_user");
    write_plugin(
        &root,
        "config/mine",
        &manifest("mine", &json!({ "entry": "i.ts", "provides": ["pairs"] })),
    );
    let bundled = [
        Bundled {
            name: "user",
            module: "yuke:internal/bundled/user",
            uses: &["pairs"],
            provides: &[],
        },
        Bundled {
            name: "second",
            module: "yuke:internal/bundled/second",
            uses: &[],
            provides: &["pairs"],
        },
    ];

    let plugins = load_with(&bundled, &root, &["mine"], &["second"]).unwrap().load;

    let names: Vec<&str> = plugins.iter().map(|plugin| plugin.name.as_str()).collect();
    assert_eq!(names, ["mine", "user"]);
    assert_eq!(plugins[1].uses, ["pairs"]);
}

#[test]
fn plugins_without_a_provider_or_in_a_cycle_of_uses_go_last_for_the_runtime_to_skip() {
    let root = place("cycle");
    write_plugin(
        &root,
        "config/first",
        &manifest("first", &json!({ "entry": "i.ts", "uses": ["b"], "provides": ["a"] })),
    );
    write_plugin(
        &root,
        "config/second",
        &manifest("second", &json!({ "entry": "i.ts", "uses": ["a"], "provides": ["b"] })),
    );
    write_plugin(&root, "config/plain", &manifest("plain", &json!({})));
    write_plugin(
        &root,
        "config/alone",
        &manifest("alone", &json!({ "uses": ["absent"] })),
    );

    let list = load(&root, &["first", "alone", "plain", "second"]).unwrap();

    assert_eq!(names(&list), ["plain", "first", "alone", "second"]);
    assert_eq!(failures(&list), Vec::<String>::new());
}

#[test]
fn the_bundled_plugins_load_first_and_disable_leaves_one_out() {
    let root = place("bundled_first");
    write_plugin(&root, "config/mine", &manifest("mine", &json!({})));

    let plugins = load_with(BUNDLED_PAIR, &root, &["mine"], &["first"]).unwrap().load;

    let names: Vec<&str> = plugins.iter().map(|plugin| plugin.name.as_str()).collect();
    assert_eq!(names, ["second", "mine"]);
    assert_eq!(
        plugins[0],
        Plugin {
            name: "second".to_owned(),
            origin: PluginCode::Bundled {
                module: "yuke:internal/bundled/second".to_owned(),
            },
            data_dir: root.join("data/plugins/second"),
            options: Map::new(),
            uses: Vec::new(),
            provides: vec!["pairs".to_owned()],
        }
    );
}

#[test]
fn a_disable_name_that_no_bundled_plugin_has_stops_the_start() {
    let root = place("bundled_unknown");

    let refused = load_with(BUNDLED_PAIR, &root, &[], &["frist"]).map(|list| list.load);

    assert_eq!(
        refused,
        Err("config.json: disable names 'frist', which is not a bundled plugin".to_owned())
    );
}

#[test]
fn a_bundled_plugin_gets_its_options_and_an_unknown_name_stops_the_start() {
    let root = place("bundled_options");
    let options = json!({ "first": { "level": 2 } });
    let config = Config {
        bundled: serde_json::from_value(options).unwrap(),
        ..Config::default()
    };

    let plugins = with_bundled(BUNDLED_PAIR, &root.join("config"), &config, &root.join("data"))
        .unwrap()
        .load;
    let unknown = Config {
        bundled: serde_json::from_value(json!({ "frist": {} })).unwrap(),
        ..Config::default()
    };
    let refused = with_bundled(BUNDLED_PAIR, &root.join("config"), &unknown, &root.join("data")).map(|list| list.load);

    let options: Vec<&Map<String, Value>> = plugins.iter().map(|plugin| &plugin.options).collect();
    assert_eq!(options, [json!({ "level": 2 }).as_object().unwrap(), &Map::new()]);
    assert_eq!(
        refused,
        Err("config.json: bundled names 'frist', which is not a bundled plugin".to_owned())
    );
}

#[test]
fn a_profile_plugin_takes_the_name_of_a_bundled_plugin_only_after_its_disable() {
    let root = place("bundled_replace");
    write_plugin(&root, "config/mine", &manifest("first", &json!({})));

    let refused = load_with(BUNDLED_PAIR, &root, &["mine"], &[]).unwrap();
    let replaced = load_with(BUNDLED_PAIR, &root, &["mine"], &["first"]).unwrap().load;

    assert_eq!(names(&refused), ["first", "second"]);
    assert_eq!(
        failures(&refused),
        [
            "Plugin first did not load: a bundled plugin has this name: add \"first\" to \"disable\" in config.json to \
             replace it"
        ]
    );
    let origins: Vec<bool> = replaced
        .iter()
        .map(|plugin| matches!(plugin.origin, PluginCode::Folder { .. }))
        .collect();
    assert_eq!(origins, [false, true]);
    assert_eq!(replaced[1].name, "first");
}

/// The `plugins` item of the folder `folder` of the repository `url` at `reference`.
fn git(url: &str, folder: &str, reference: Option<&str>) -> ConfigPlugin {
    ConfigPlugin {
        source: PluginOrigin::Git(git_source(url.to_owned(), Some(folder), reference.map(str::to_owned))),
        options: Map::new(),
    }
}

/// The plugins of `items` in the config folder of `root`, with no bundled plugin.
fn load_items(root: &Path, items: Vec<ConfigPlugin>) -> Result<PluginList, String> {
    let config = Config {
        plugins: items,
        ..Config::default()
    };
    with_bundled(&[], &root.join("config"), &config, &root.join("data"))
}

/// Write `plugins.lock` of `root` with the entries `entries`.
fn write_lock(root: &Path, entries: &Value) {
    let text = json!({ "plugins": entries }).to_string();
    std::fs::write(root.join("config/plugins.lock"), text).unwrap();
}

const URL: &str = "https://github.com/lostcoords/yuke-plugin.git";

#[test]
fn a_git_install_folder_has_the_last_url_part_and_a_hash_of_the_whole_url() {
    let data = Path::new("/data");

    assert_eq!(
        git_folder(data, URL, "c1"),
        Path::new("/data/git/yuke-plugin-c4285510f1a5da6e/c1")
    );
    assert_eq!(
        git_folder(data, "git@github.com:lostcoords/yuke-plugin", "c1"),
        Path::new("/data/git/yuke-plugin-520d70dd994511f7/c1")
    );
}

#[test]
fn a_git_plugin_loads_from_the_install_of_the_commit_that_the_lock_gives_its_folder_and_ref() {
    let root = place("git_locked");
    let commit = "3f9c1a2b".repeat(5);
    let installed = root.join("data/git/yuke-plugin-c4285510f1a5da6e").join(&commit);
    write_plugin(&installed, "plugins/clock", &manifest("clock", &json!({})));
    write_lock(
        &root,
        &json!([{ "git": URL, "folder": "./plugins/clock/", "ref": "main", "commit": commit }]),
    );

    let plugins = load_items(&root, vec![git(URL, "plugins/clock", Some("main"))])
        .unwrap()
        .load;

    assert_eq!(
        plugins[0].origin,
        PluginCode::Folder {
            root: installed.join("plugins/clock"),
            entry: None,
        }
    );
}

#[test]
fn a_git_plugin_without_its_commit_in_the_lock_or_on_disk_is_not_installed_and_the_others_load() {
    let root = place("git_missing");
    let commit = "3f9c1a2b".repeat(5);
    write_plugin(&root, "config/local", &manifest("local", &json!({})));
    write_lock(&root, &json!([{ "git": URL, "folder": "clock", "commit": commit }]));
    let local = ConfigPlugin {
        source: PluginOrigin::Folder("local".to_owned()),
        options: Map::new(),
    };

    // The lock has no commit for the root of the repository, and the commit of `clock` is not on disk.
    let list = load_items(&root, vec![git(URL, ".", None), git(URL, "clock", None), local]).unwrap();

    assert_eq!(names(&list), ["local"]);
    assert_eq!(
        failures(&list),
        [
            "Plugin yuke-plugin did not load: it is not installed · /plugins or `yuke plugin sync` installs it",
            "Plugin clock did not load: it is not installed · /plugins or `yuke plugin sync` installs it",
        ]
    );
}

#[test]
fn a_lock_with_a_short_commit_fails_the_list() {
    let root = place("git_bad_lock");
    let lock = root.join("config/plugins.lock");
    write_lock(&root, &json!([{ "git": URL, "commit": "3f9c1a2" }]));

    let short = load_items(&root, vec![git(URL, "clock", None)]).unwrap_err();

    assert_eq!(short, format!("{}: '3f9c1a2' is not a full commit id", lock.display()));
}
