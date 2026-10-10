//! The committed `src/queries.rs` is the output of `yuke-sqlgen` for the current migrations and queries.

use std::path::Path;

#[test]
fn the_committed_queries_are_current() {
    let crate_folder = Path::new(env!("CARGO_MANIFEST_DIR"));
    let generated = yuke_sqlgen::generate(crate_folder).unwrap();
    let current = std::fs::read_to_string(crate_folder.join("src/queries.rs")).unwrap();

    assert!(
        current == generated.code,
        "src/queries.rs is out of date; run `cargo run -p yuke-sqlgen`"
    );
}
