use std::path::PathBuf;

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
fn load(root: &Path, list: &[&str]) -> Result<Vec<Plugin>, String> {
    load_with(&[], root, list, &[])
}

/// The bundled plugins `bundled` that `disable` does not name, then the plugins of the folders `list`.
fn load_with(
    bundled: &[(&str, &str, &[&str])],
    root: &Path,
    list: &[&str],
    disable: &[&str],
) -> Result<Vec<Plugin>, String> {
    let config = Config {
        plugins: list
            .iter()
            .map(|&path| ConfigPlugin {
                path: path.to_owned(),
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

    let plugins = load(&root, &["notes", reader.to_str().unwrap()]).unwrap();

    assert_eq!(
        plugins,
        [
            Plugin {
                name: "notes".to_owned(),
                origin: Origin::Folder {
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
                origin: Origin::Folder {
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
fn a_bad_folder_or_manifest_stops_the_start_and_names_the_problem() {
    let root = place("bad");
    let fields = |fields: Value| manifest("p", &fields);
    let cases = [
        ("{", "plugin.json: EOF while parsing an object at line 1 column 1"),
        (
            r#"{ "extensions": {} }"#,
            "plugin.json: missing field `name` at line 1 column 20",
        ),
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
        (
            &fields(json!({ "entry": "../x.ts" })),
            "entry: '../x.ts' is not a relative path inside the plugin folder",
        ),
        (
            &fields(json!({ "entry": "src/../../x.ts" })),
            "entry: 'src/../../x.ts' is not a relative",
        ),
        (
            &fields(json!({ "entry": "/tmp/x.ts" })),
            "entry: '/tmp/x.ts' is not a relative",
        ),
        (&fields(json!({ "entri": "x.ts" })), "unknown field `entri`"),
        (
            &fields(json!({ "entry": "main.py" })),
            "entry: 'main.py' is not a .ts or a .js file",
        ),
        (&fields(json!({ "uses": [""] })), "uses: a service name is empty"),
        (
            &fields(json!({ "provides": ["a", "a"], "entry": "i.ts" })),
            "provides: 'a' is in the list twice",
        ),
        (
            &fields(json!({ "uses": ["a"], "provides": ["a"], "entry": "i.ts" })),
            "'a' is in uses and in provides",
        ),
        (
            &fields(json!({ "provides": ["a"] })),
            "provides: a plugin without an entry cannot provide a service",
        ),
    ];

    for (index, (text, expected)) in cases.into_iter().enumerate() {
        let folder = format!("case{index}");
        write_plugin(&root, &format!("config/{folder}"), text);
        let error = load(&root, &[&folder]).unwrap_err();
        assert!(error.starts_with(&format!("plugin folder {folder}: ")), "{error}");
        assert!(error.contains(expected), "{text}: {error}");
    }
    let missing = load(&root, &["absent"]).unwrap_err();
    assert!(missing.starts_with("plugin folder absent: "), "{missing}");
    std::fs::create_dir_all(root.join("config/empty")).unwrap();
    let no_manifest = load(&root, &["empty"]).unwrap_err();
    assert!(no_manifest.contains("plugin.json"), "{no_manifest}");
    write_plugin(&root, "config/fine", &manifest("fine", &json!({})));
    let twice = load(&root, &["fine", "./fine"]).unwrap_err();
    assert_eq!(twice, "plugin folder ./fine: the list names this folder twice");
}

#[test]
fn the_order_of_the_list_is_the_load_order_so_a_provider_comes_first() {
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

    assert_eq!(
        load(&root, &["reader", "notes"]),
        Err("plugin reader: it uses 'notes', and plugin notes provides it later in the list".to_owned())
    );
    assert_eq!(
        load(&root, &["reader"]),
        Err("plugin reader: it uses 'notes', and no plugin of the list provides it".to_owned())
    );
    assert_eq!(
        load(&root, &["notes", "notes2"]),
        Err("plugin notes2: plugin notes provides 'notes' already".to_owned())
    );
    assert_eq!(
        load(&root, &["notes", "reader", "again"]),
        Err("plugin reader: another plugin of the list has this name".to_owned())
    );
    assert_eq!(load(&root, &["notes", "reader"]).map(|plugins| plugins.len()), Ok(2));
}

/// Two bundled plugins of a test. The second one provides `pairs`.
const BUNDLED_PAIR: &[(&str, &str, &[&str])] = &[
    ("first", "yuke:internal/bundled/first", &[]),
    ("second", "yuke:internal/bundled/second", &["pairs"]),
];

#[test]
fn the_bundled_plugins_load_first_and_disable_leaves_one_out() {
    let root = place("bundled_first");
    write_plugin(&root, "config/mine", &manifest("mine", &json!({})));

    let plugins = load_with(BUNDLED_PAIR, &root, &["mine"], &["first"]).unwrap();

    let names: Vec<&str> = plugins.iter().map(|plugin| plugin.name.as_str()).collect();
    assert_eq!(names, ["second", "mine"]);
    assert_eq!(
        plugins[0],
        Plugin {
            name: "second".to_owned(),
            origin: Origin::Bundled {
                module: "yuke:internal/bundled/second".to_owned(),
            },
            data_dir: root.join("data/plugins/second"),
            options: Map::new(),
            uses: Vec::new(),
            provides: vec!["pairs".to_owned()],
        }
    );
    assert!(root.join("data/plugins/second").is_dir());
}

#[test]
fn a_profile_plugin_uses_the_service_of_a_bundled_plugin_until_its_disable() {
    let root = place("bundled_service");
    write_plugin(&root, "config/mine", &manifest("mine", &json!({ "uses": ["pairs"] })));

    let loaded = load_with(BUNDLED_PAIR, &root, &["mine"], &[]).map(|plugins| plugins.len());
    let refused = load_with(BUNDLED_PAIR, &root, &["mine"], &["second"]);

    assert_eq!(loaded, Ok(3));
    assert_eq!(
        refused,
        Err("plugin mine: it uses 'pairs', and no plugin of the list provides it".to_owned())
    );
}

#[test]
fn a_disable_name_that_no_bundled_plugin_has_stops_the_start() {
    let root = place("bundled_unknown");

    let refused = load_with(BUNDLED_PAIR, &root, &[], &["frist"]);

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

    let plugins = with_bundled(BUNDLED_PAIR, &root.join("config"), &config, &root.join("data")).unwrap();
    let unknown = Config {
        bundled: serde_json::from_value(json!({ "frist": {} })).unwrap(),
        ..Config::default()
    };
    let refused = with_bundled(BUNDLED_PAIR, &root.join("config"), &unknown, &root.join("data"));

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

    let refused = load_with(BUNDLED_PAIR, &root, &["mine"], &[]);
    let replaced = load_with(BUNDLED_PAIR, &root, &["mine"], &["first"]).unwrap();

    assert_eq!(
        refused,
        Err(
            "plugin first: a bundled plugin has this name: add \"first\" to \"disable\" in config.json to replace it"
                .to_owned()
        )
    );
    let origins: Vec<bool> = replaced
        .iter()
        .map(|plugin| matches!(plugin.origin, Origin::Folder { .. }))
        .collect();
    assert_eq!(origins, [false, true]);
    assert_eq!(replaced[1].name, "first");
}
