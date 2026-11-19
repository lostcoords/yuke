//! Test fixtures that the tests of several yuke crates share: a test model and a new folder for each test. A fixture that
//! one crate alone uses stays in that crate. The scripted transport is `yuke_ai::scripted`, and the timer that never
//! waits is `yuke_engine::NoWait`.
#![expect(
    clippy::unwrap_used,
    clippy::missing_panics_doc,
    clippy::panic,
    reason = "a fixture fails its test by panicking"
)]

use std::sync::Arc;

use yuke_ai::{AnthropicWire, Credential, Origin, OriginRef, Route, Target, ToolDefinition, Wire};
use yuke_engine::ModelAccess;

/// An Anthropic target at a test host. Its route takes no credential.
pub fn target() -> Target {
    Target {
        model: "test-model".into(),
        route: Route {
            base_url: "https://example.test/v1".into(),
            ..Route::default()
        },
        wire: Wire::AnthropicMessages(AnthropicWire {
            max_tokens: 64,
            cache: false,
        }),
        tool_search: false,
    }
}

/// The origin of [`target`].
pub fn origin() -> Origin {
    Origin::from(OriginRef::of(&target()))
}

/// A definition of `name` that takes any object.
pub fn definition(name: &str) -> ToolDefinition {
    ToolDefinition {
        name: name.into(),
        description: "A test tool.".to_owned(),
        input_schema: r#"{"type":"object"}"#.to_owned(),
        defer_loading: false,
    }
}

/// [`target`] with no credential.
pub fn model() -> ModelAccess {
    model_of(target())
}

/// `target` with no credential.
pub fn model_of(target: Target) -> ModelAccess {
    ModelAccess {
        target,
        source: Arc::new(Credential::None),
        context_window: None,
    }
}

/// Assert that each of `texts` appears as a JSON string in `body`, in order.
/// Each entry consumes a separate occurrence. This checks encoded text, not JSON structure.
#[track_caller]
pub fn assert_in_order(body: &str, texts: &[&str]) {
    let mut remaining = body;
    for (index, text) in texts.iter().enumerate() {
        let encoded = serde_json::to_string(text).unwrap();
        let Some(position) = remaining.find(&encoded) else {
            panic!("expected JSON string at index {index}: {encoded}\nbody: {body}");
        };
        remaining = &remaining[position + encoded.len()..];
    }
}

/// Create an empty folder for the test `name` in `group` and return its canonical path.
/// The same group and name use the same path within a process. Each call deletes the old contents.
/// The process ID separates concurrent processes. The folder remains after the returned path is dropped.
/// Filesystem failures cause a panic that reports the operation and path.
pub fn folder(group: &str, name: &str) -> std::path::PathBuf {
    let folder = std::env::temp_dir()
        .join(format!("yuke-{group}-tests-{}", std::process::id()))
        .join(name);
    match std::fs::remove_dir_all(&folder) {
        Err(error) if error.kind() == std::io::ErrorKind::NotFound => {}
        result => result.unwrap_or_else(|error| panic!("cannot remove test folder {}: {error}", folder.display())),
    }
    std::fs::create_dir_all(&folder)
        .unwrap_or_else(|error| panic!("cannot create test folder {}: {error}", folder.display()));
    // On macOS, the temporary folder is a symbolic link. A command reports the canonical path of its working folder.
    folder
        .canonicalize()
        .unwrap_or_else(|error| panic!("cannot canonicalize test folder {}: {error}", folder.display()))
}

/// Run `git` with `args` in `folder`, as a test user with no hooks and no signing, and give its output. A failure of
/// git causes a panic that reports its standard error.
pub fn git(folder: &std::path::Path, args: &[&str]) -> String {
    let output = std::process::Command::new("git")
        .current_dir(folder)
        .args(["-c", "user.name=test", "-c", "user.email=test@example.com"])
        .args(["-c", "commit.gpgsign=false", "-c", "core.hooksPath=/dev/null"])
        .args(args)
        .output()
        .unwrap_or_else(|error| panic!("git does not start: {error}"));
    assert!(
        output.status.success(),
        "git {}: {}",
        args.join(" "),
        String::from_utf8_lossy(&output.stderr)
    );
    String::from_utf8_lossy(&output.stdout).trim().to_owned()
}

/// Commit the plugin `name` in the folder `plugins/<name>` of the repository `remote`, with the subject `subject`. A
/// missing repository starts on branch `main`. Gives the commit id.
pub fn commit_plugin(remote: &std::path::Path, name: &str, subject: &str) -> String {
    let write = |path: std::path::PathBuf, text: &str| {
        std::fs::write(&path, text).unwrap_or_else(|error| panic!("cannot write {}: {error}", path.display()));
    };
    let folder = remote.join("plugins").join(name);
    std::fs::create_dir_all(&folder).unwrap_or_else(|error| panic!("cannot create {}: {error}", folder.display()));
    if !remote.join(".git").exists() {
        git(remote, &["init", "--quiet", "-b", "main"]);
    }
    write(folder.join("plugin.json"), &format!(r#"{{ "name": "{name}" }}"#));
    write(folder.join("notes.txt"), subject);
    git(remote, &["add", "."]);
    git(remote, &["commit", "--quiet", "-m", subject]);
    git(remote, &["rev-parse", "HEAD"])
}
