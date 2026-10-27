//! The public module `yuke:fs`: the modes of files and folders, and the write tool. crates/js/tests/fs holds the other
//! tests.

use std::os::unix::fs::PermissionsExt;
use std::path::Path;
use std::time::Duration;

use super::{NAMES, evaluate, folder, start};

/// Run `body` in a new runtime with `fs` (the module `yuke:fs`) and `base` (the folder of the test), after `setup` of
/// the folder, and give the value of its promise and the folder.
async fn run_fs(name: &str, setup: impl FnOnce(&Path), body: &str) -> (String, std::path::PathBuf) {
    let folder = folder(name);
    setup(&folder);
    let (runtime, mut reports) = start(&folder).await;
    let base = js_string(&folder);
    let body = format!("{NAMES}\nconst fs = await import('yuke:fs');\nconst base = {base};\n{body}");
    let text = tokio::time::timeout(Duration::from_secs(10), evaluate::<String>(&runtime, &body))
        .await
        .unwrap()
        .unwrap();
    if let Ok(report) = reports.try_recv() {
        panic!("unexpected report: {report:?}");
    }
    (text, folder)
}

/// `path` as a JavaScript string literal.
fn js_string(path: &Path) -> String {
    format!(
        "'{}'",
        path.to_str().unwrap().replace('\\', "\\\\").replace('\'', "\\'")
    )
}

#[tokio::test]
async fn mkdir_makes_parents_only_when_recursive_and_refuses_a_folder_that_exists() {
    let (text, folder) = run_fs(
        "mkdir_makes_parents_only_when_recursive_and_refuses_a_folder_that_exists",
        |_| {},
        "const codes = [];
         const attempt = async (work) => { try { await work(); codes.push('ok'); } catch (error) { codes.push(error.code); } };
         await attempt(() => fs.mkdir('a/b', { baseDir: base }));
         await attempt(() => fs.mkdir('a/b', { baseDir: base, recursive: true, mode: 0o700 }));
         await attempt(() => fs.mkdir('a/b', { baseDir: base, recursive: true }));
         await attempt(() => fs.mkdir('a/b', { baseDir: base }));
         return codes.join(' ');",
    )
    .await;

    assert_eq!(text, "ENOENT ok ok EEXIST");
    let mode = std::fs::metadata(folder.join("a/b")).unwrap().permissions().mode() & 0o777;
    assert_eq!(mode & 0o077, 0, "{mode:o}");
}

#[tokio::test]
async fn a_write_sets_the_mode_of_a_new_file_and_an_atomic_write_keeps_the_mode_that_it_replaces() {
    let (_text, folder) = run_fs(
        "a_write_sets_the_mode_of_a_new_file_and_an_atomic_write_keeps_the_mode_that_it_replaces",
        |_| {},
        "await fs.writeTextFile('secret.json', 'one', { baseDir: base, mode: 0o600 });
         await fs.writeTextFile('secret.json', 'two', { baseDir: base, atomic: true });
         await fs.writeTextFile('open.json', 'x', { baseDir: base, atomic: true, mode: 0o600 });
         return '';",
    )
    .await;

    let mode = |name: &str| std::fs::metadata(folder.join(name)).unwrap().permissions().mode() & 0o777;
    assert_eq!(mode("secret.json"), 0o600);
    // Each umask keeps the bits of 0o600.
    assert_eq!(mode("open.json"), 0o600);
    assert_eq!(std::fs::read_to_string(folder.join("secret.json")).unwrap(), "two");
    let mut names: Vec<String> = std::fs::read_dir(&folder)
        .unwrap()
        .map(|entry| entry.unwrap().file_name().into_string().unwrap())
        .filter(|name| name != "cache" && name != "processes")
        .collect();
    names.sort();
    assert_eq!(names, ["open.json", "secret.json"]);
}

#[tokio::test]
async fn the_mode_of_a_write_holds_for_a_file_that_exists_and_the_umask_does_not_cut_it() {
    let (_text, folder) = run_fs(
        "the_mode_of_a_write_holds_for_a_file_that_exists_and_the_umask_does_not_cut_it",
        |folder| {
            for name in ["plain", "append", "atomic"] {
                std::fs::write(folder.join(name), "one").unwrap();
                std::fs::set_permissions(folder.join(name), std::fs::Permissions::from_mode(0o644)).unwrap();
            }
        },
        "await fs.writeTextFile('plain', 'two', { baseDir: base, mode: 0o600 });
         await fs.writeTextFile('append', 'two', { baseDir: base, append: true, mode: 0o600 });
         await fs.writeTextFile('atomic', 'two', { baseDir: base, atomic: true, mode: 0o600 });
         await fs.writeTextFile('shared', 'x', { baseDir: base, mode: 0o666 });
         return '';",
    )
    .await;

    let mode = |name: &str| std::fs::metadata(folder.join(name)).unwrap().permissions().mode() & 0o777;
    assert_eq!(
        ["plain", "append", "atomic", "shared"].map(mode),
        [0o600, 0o600, 0o600, 0o666]
    );
}

#[tokio::test]
async fn an_atomic_write_keeps_a_mode_that_the_umask_would_cut() {
    let (_text, folder) = run_fs(
        "an_atomic_write_keeps_a_mode_that_the_umask_would_cut",
        |folder| {
            std::fs::write(folder.join("shared.txt"), "one").unwrap();
            std::fs::set_permissions(folder.join("shared.txt"), std::fs::Permissions::from_mode(0o666)).unwrap();
        },
        "await fs.writeTextFile('shared.txt', 'two', { baseDir: base, atomic: true });
         return '';",
    )
    .await;

    let mode = std::fs::metadata(folder.join("shared.txt"))
        .unwrap()
        .permissions()
        .mode()
        & 0o777;
    assert_eq!(mode, 0o666);
}

#[tokio::test]
async fn the_write_tool_writes_a_file_at_the_top_of_the_folder_without_a_parent_folder() {
    let folder = folder("the_write_tool_writes_a_file_at_the_top_of_the_folder_without_a_parent_folder");
    let (_runtime, _host, tools) = super::tools::tools_of(&folder, &["yuke:internal/builtins"]).await;

    let text = super::tools::text_of(&tools["write"], r#"{"path": "note.txt", "content": "x"}"#).await;

    assert_eq!(text, "The tool wrote 1 bytes.");
    assert_eq!(std::fs::read_to_string(folder.join("note.txt")).unwrap(), "x");
    assert!(!folder.join("note.tx").exists());
}
