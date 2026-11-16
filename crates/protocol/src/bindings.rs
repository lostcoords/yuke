//! The test of the TypeScript declarations in `bindings/` and in the plugin module `yuke:protocol`. It exports them to
//! a temporary folder, and it fails when they differ from the checked-in files. `YUKE_WRITE_BINDINGS=1` writes them
//! instead.

use std::collections::{BTreeMap, BTreeSet};
use std::fmt::Write as _;
use std::path::{Path, PathBuf};

use ts_rs::{Config, TS};

use crate::message::{ClientRequestResults, ERROR_CODES};
use crate::{
    ClientNotification, ClientRequest, Notification, PROTOCOL_VERSION, Request, Response, ServerNotification,
    ServerRequest, SessionSnapshot,
};

/// The types that plugins use. The plugin module holds them and each type that they use.
const PLUGIN_TYPES: &[&str] = &[
    "AddPluginParams",
    "AddPluginResult",
    "ApplyPluginsParams",
    "ApplyPluginsResult",
    "Block",
    "CheckPluginsParams",
    "CheckPluginsResult",
    "DisplayBlock",
    "EventNumber",
    "ExtensionEventParams",
    "ExtensionRequestParams",
    "FinishReason",
    "InputId",
    "InputKind",
    "InputSource",
    "InteractionId",
    "InteractionResponse",
    "Job",
    "ListCatalogResult",
    "ListPluginsResult",
    "ListSessionsParams",
    "ListSessionsResult",
    "LoginId",
    "LoginOutcome",
    "LoginResult",
    "McpServer",
    "ModelReference",
    "NoticeLevel",
    "NoticeParams",
    "PluginChange",
    "PluginTarget",
    "RemovePluginParams",
    "SessionId",
    "SessionRow",
    "SessionSettings",
    "SessionSnapshot",
    "SessionUpdate",
    "SetApiKeyParams",
    "RequestSettings",
    "StoredEvent",
    "SyncPluginsParams",
    "SyncPluginsResult",
    "ToolHints",
    "Usage",
];

/// The plugin module `yuke:protocol` from the files of `bindings`: the declaration of each type of [`PLUGIN_TYPES`] and
/// of each type that one uses, in name order, in one file without the imports between them.
fn plugin_module(bindings: &BTreeMap<PathBuf, String>) -> String {
    let mut names = BTreeSet::new();
    let mut next: Vec<String> = PLUGIN_TYPES.iter().map(|name| (*name).to_owned()).collect();
    while let Some(name) = next.pop() {
        let text = &bindings[&PathBuf::from(format!("{name}.ts"))];
        if names.insert(name) {
            // ts-rs writes each import as `import type { Name } from "./Name";`.
            let imports = text.lines().filter_map(|line| line.strip_prefix("import type { "));
            next.extend(imports.filter_map(|rest| rest.split(' ').next()).map(str::to_owned));
        }
    }
    let mut module = String::from(
        "// Generated from the protocol types by the bindings test of `yuke-protocol`. Do not edit.\n\
         // The types of the protocol that plugins use, as the clients of the protocol see them.\n",
    );
    for name in names {
        let text = &bindings[&PathBuf::from(format!("{name}.ts"))];
        for line in text
            .lines()
            .filter(|line| !line.starts_with("//") && !line.starts_with("import type "))
        {
            module.push_str(line);
            module.push('\n');
        }
    }
    module
}

/// Export each message and each result, with the types that they use, and the constants to `folder`.
fn export(folder: &Path) {
    // serde writes a `u64` as a JSON number, and ts-rs writes it as `bigint` unless the config says `number`.
    // Node and Bun load a TypeScript import only with its extension.
    let config = Config::new()
        .with_large_int("number")
        .with_import_extension(Some("ts"))
        .with_out_dir(folder);
    Request::<ClientRequest>::export_all(&config).unwrap();
    // The export of the generic `Request` writes no file for its argument.
    ClientRequest::export_all(&config).unwrap();
    ServerRequest::export_all(&config).unwrap();
    Response::export_all(&config).unwrap();
    Notification::<ClientNotification>::export_all(&config).unwrap();
    // The export of the generic `Notification` writes no file for its argument.
    ClientNotification::export_all(&config).unwrap();
    ServerNotification::export_all(&config).unwrap();
    // The map of the results by method also writes each result type.
    ClientRequestResults::export_all(&config).unwrap();
    // The plugins see a session as a snapshot, then updates.
    SessionSnapshot::export_all(&config).unwrap();
    for (path, text) in files(folder) {
        std::fs::write(folder.join(path), typescript_doc(&text)).unwrap();
    }
    std::fs::write(folder.join("constants.ts"), constants()).unwrap();
}

/// `text` with its rustdoc links for a TypeScript reader, who cannot follow them. A link in parentheses to a Rust path
/// goes away. Another link becomes the code text that it shows.
fn typescript_doc(text: &str) -> String {
    let mut result = String::with_capacity(text.len());
    let mut rest = text;
    while let Some(start) = rest.find("[`") {
        let Some(length) = rest[start..].find("`]") else {
            break;
        };
        let code = &rest[start + 1..=start + length];
        let mut end = start + length + 2;
        let mut target = "";
        if rest[end..].starts_with('(')
            && let Some(close) = rest[end..].find(')')
        {
            target = &rest[end + 1..end + close];
            end += close + 1;
        }
        let before = &rest[..start];
        if (code.contains("::") || target.contains("::")) && before.ends_with(" (") && rest[end..].starts_with(')') {
            result.push_str(&before[..before.len() - 2]);
            rest = &rest[end + 1..];
        } else {
            result.push_str(before);
            result.push_str(code);
            rest = &rest[end..];
        }
    }
    result.push_str(rest);
    result
}

/// The TypeScript module of the protocol version and the error codes.
fn constants() -> String {
    let mut module = format!(
        "// Generated from the protocol constants by the bindings test of `yuke-protocol`. Do not edit.\n\n\
         /** The protocol version of this server. */\n\
         export const PROTOCOL_VERSION = {PROTOCOL_VERSION};\n\n\
         /** The `code` of a failed request: a code of JSON-RPC, or a code of yuke. */\n\
         export const ErrorCode = {{\n"
    );
    for (name, code, doc) in ERROR_CODES {
        let doc = typescript_doc(doc.trim());
        write!(module, "  /** {doc} */\n  {name}: {code},\n").unwrap();
    }
    module.push_str("} as const;\n");
    module
}

/// The text of each file in `folder`, by its path relative to `folder`.
fn files(folder: &Path) -> BTreeMap<PathBuf, String> {
    let mut files = BTreeMap::new();
    let mut folders = vec![folder.to_path_buf()];
    while let Some(current) = folders.pop() {
        for entry in std::fs::read_dir(&current).unwrap() {
            let path = entry.unwrap().path();
            if path.is_dir() {
                folders.push(path);
            } else {
                let text = std::fs::read_to_string(&path).unwrap();
                files.insert(path.strip_prefix(folder).unwrap().to_path_buf(), text);
            }
        }
    }
    files
}

/// Remove `folder` when it exists.
fn remove(folder: &Path) {
    match std::fs::remove_dir_all(folder) {
        Err(error) if error.kind() == std::io::ErrorKind::NotFound => {}
        result => result.unwrap(),
    }
}

#[test]
fn the_checked_in_bindings_match_the_types() {
    let checked_in = Path::new(env!("CARGO_MANIFEST_DIR")).join("bindings");
    let plugin = Path::new(env!("CARGO_MANIFEST_DIR")).join("../js/modules/protocol.ts");
    let fresh = std::env::temp_dir().join(format!("yuke-protocol-bindings-{}", std::process::id()));
    remove(&fresh);
    export(&fresh);
    let expected = files(&fresh);
    remove(&fresh);
    let module = plugin_module(&expected);

    // A full export comes first, so a failed export leaves the checked-in files as they were.
    if std::env::var("YUKE_WRITE_BINDINGS").as_deref() == Ok("1") {
        remove(&checked_in);
        std::fs::create_dir_all(&checked_in).unwrap();
        for (path, text) in &expected {
            std::fs::write(checked_in.join(path), text).unwrap();
        }
        std::fs::write(&plugin, module).unwrap();
        return;
    }

    let actual = if checked_in.is_dir() {
        files(&checked_in)
    } else {
        BTreeMap::new()
    };
    let differ: BTreeSet<&PathBuf> = expected
        .keys()
        .chain(actual.keys())
        .filter(|path| expected.get(*path) != actual.get(*path))
        .collect();
    assert!(
        differ.is_empty(),
        "bindings/ differs from the types in {differ:?}. Write it again: YUKE_WRITE_BINDINGS=1 mise exec -- cargo test -p yuke-protocol"
    );
    assert!(
        std::fs::read_to_string(&plugin).ok().as_deref() == Some(module.as_str()),
        "crates/js/modules/protocol.ts differs from the types. Write it again: YUKE_WRITE_BINDINGS=1 mise exec -- cargo test -p yuke-protocol"
    );
}

// D3 of the wire: an absent field is left out, never `null`. Only JSON-RPC asks for a null, as the id of a response to
// a message without a readable id.
#[test]
fn no_binding_but_the_response_holds_a_null() {
    let fresh = std::env::temp_dir().join(format!("yuke-protocol-nulls-{}", std::process::id()));
    remove(&fresh);
    export(&fresh);
    let bindings = files(&fresh);
    remove(&fresh);
    let nulls: Vec<&PathBuf> = bindings
        .iter()
        .filter(|(path, text)| text.contains("| null") && path.as_path() != Path::new("Response.ts"))
        .map(|(path, _)| path)
        .collect();
    assert!(nulls.is_empty(), "these bindings hold a null: {nulls:?}");
}
