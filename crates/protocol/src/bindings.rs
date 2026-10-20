//! The test of the TypeScript declarations in `bindings/`. It exports them to a temporary folder, and it fails when they
//! differ from the checked-in files. `YUKE_WRITE_BINDINGS=1` writes them to `bindings/` instead.

use std::collections::{BTreeMap, BTreeSet};
use std::path::{Path, PathBuf};

use ts_rs::{Config, TS};

use crate::{
    ClientNotification, ClientRequest, EmptyResult, InitializeResult, InputResult, ListJobsResult,
    ListMcpServersResult, Notification, Request, Response, ServerNotification, SessionResult,
};

/// Export each message and each result, with the types that they use, to `folder`.
fn export(folder: &Path) {
    // serde writes a `u64` as a JSON number, and ts-rs writes it as `bigint` unless the config says `number`.
    let config = Config::new().with_large_int("number").with_out_dir(folder);
    Request::export_all(&config).unwrap();
    ClientRequest::export_all(&config).unwrap();
    Response::export_all(&config).unwrap();
    Notification::<ClientNotification>::export_all(&config).unwrap();
    // The export of the generic `Notification` writes no file for its argument.
    ClientNotification::export_all(&config).unwrap();
    ServerNotification::export_all(&config).unwrap();
    InitializeResult::export_all(&config).unwrap();
    SessionResult::export_all(&config).unwrap();
    InputResult::export_all(&config).unwrap();
    ListJobsResult::export_all(&config).unwrap();
    ListMcpServersResult::export_all(&config).unwrap();
    EmptyResult::export_all(&config).unwrap();
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
    let fresh = std::env::temp_dir().join(format!("yuke-protocol-bindings-{}", std::process::id()));
    remove(&fresh);
    export(&fresh);

    // A full export comes first, so a failed export leaves the checked-in files as they were.
    if std::env::var("YUKE_WRITE_BINDINGS").as_deref() == Ok("1") {
        remove(&checked_in);
        std::fs::create_dir_all(&checked_in).unwrap();
        for (path, text) in files(&fresh) {
            std::fs::write(checked_in.join(path), text).unwrap();
        }
        remove(&fresh);
        return;
    }
    let expected = files(&fresh);
    remove(&fresh);

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
}
