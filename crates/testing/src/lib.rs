//! Test fixtures that the tests of several yuke crates share: a test model and a new folder for each test. A fixture that
//! one crate alone uses stays in that crate. The scripted transport is `yuke_ai::scripted`, and the timer that never
//! waits is `yuke_engine::NoWait`.
#![expect(
    clippy::unwrap_used,
    clippy::missing_panics_doc,
    reason = "a fixture fails its test by panicking"
)]

use std::sync::Arc;

use serde_json::Value;
use yuke_ai::route::{Credential, Route};
use yuke_ai::{AnthropicWire, Origin, OriginRef, Target, ToolDefinition, Wire};
use yuke_engine::Model;

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
pub fn model() -> Model {
    model_of(target())
}

/// `target` with no credential.
pub fn model_of(target: Target) -> Model {
    Model {
        target,
        source: Arc::new(Credential::None),
        context_window: None,
    }
}

/// Assert that each of `texts` appears as a JSON string in `body`, in order.
#[track_caller]
pub fn assert_in_order(body: &str, texts: &[&str]) {
    let positions: Vec<Option<usize>> = texts
        .iter()
        .map(|text| body.find(&Value::from(*text).to_string()))
        .collect();
    assert!(positions.iter().all(Option::is_some), "{body}");
    assert!(positions.is_sorted(), "{body}");
}

/// A new empty folder for the test `name` of the test group `group`, as a canonical path. The process id keeps two test
/// runs at once apart.
pub fn folder(group: &str, name: &str) -> std::path::PathBuf {
    let folder = std::env::temp_dir()
        .join(format!("yuke-{group}-tests-{}", std::process::id()))
        .join(name);
    match std::fs::remove_dir_all(&folder) {
        Err(error) if error.kind() == std::io::ErrorKind::NotFound => {}
        result => result.unwrap(),
    }
    std::fs::create_dir_all(&folder).unwrap();
    // On macOS, the temporary folder is a symbolic link. A command reports the canonical path of its working folder.
    folder.canonicalize().unwrap()
}
