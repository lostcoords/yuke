//! The public module `yuke:fs`: reads, writes, directories, facts, failures, and stops.

use std::os::unix::fs::{FileTypeExt, PermissionsExt};
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
async fn text_and_bytes_round_trip_through_a_relative_path_and_a_base_folder() {
    let (text, folder) = run_fs(
        "text_and_bytes_round_trip_through_a_relative_path_and_a_base_folder",
        |_| {},
        "await fs.writeTextFile('note.txt', 'héllo \\uD800', { baseDir: base });
         const text = await fs.readTextFile(base + '/note.txt');
         await fs.writeFile('data.bin', new Uint8Array([0, 1, 2, 3, 4]).subarray(1, 4), { baseDir: base });
         const bytes = await fs.readFile('data.bin', { baseDir: base });
         const part = await fs.readFile('data.bin', { baseDir: base, position: 1, length: 1 });
         const past = await fs.readFile('data.bin', { baseDir: base, position: 9 });
         return [JSON.stringify(text), Array.from(bytes).join(','), Array.from(part).join(','), past.length].join(' ');",
    )
    .await;

    assert_eq!(text, "\"héllo \u{fffd}\" 1,2,3 2 0");
    assert_eq!(std::fs::read(folder.join("data.bin")).unwrap(), [1, 2, 3]);
}

#[tokio::test]
async fn a_bad_path_or_option_throws_a_type_error() {
    let (text, _folder) = run_fs(
        "a_bad_path_or_option_throws_a_type_error",
        |_| {},
        "const reject = async (work) => { try { await work(); return 'none'; } catch (error) { return error.name; } };
         return (await Promise.all([
           reject(() => fs.readTextFile('relative.txt')),
           reject(() => fs.readTextFile('relative.txt', { baseDir: 'not/absolute' })),
           reject(() => fs.readTextFile('')),
           reject(() => fs.readTextFile('a\\0b', { baseDir: base })),
           reject(() => fs.readFile('x', { baseDir: base, position: -1 })),
           reject(() => fs.readFile('x', { baseDir: base, length: 1.5 })),
           reject(() => fs.writeFile('x', [1], { baseDir: base })),
           reject(() => fs.mkdir('x', { baseDir: base, mode: 0o10000 })),
           reject(() => fs.readTextFile('x', { baseDir: base, signal: {} })),
         ])).join(' ');",
    )
    .await;

    assert_eq!(text, ["TypeError"; 9].join(" "));
}

// A typo or a coerced value would change the operation without a word, so each one throws before the operation.
#[tokio::test]
async fn an_unknown_option_or_an_option_of_another_type_throws_and_changes_nothing() {
    let (text, folder) = run_fs(
        "an_unknown_option_or_an_option_of_another_type_throws_and_changes_nothing",
        |folder| {
            std::fs::create_dir(folder.join("keep")).unwrap();
            std::fs::write(folder.join("keep/note.txt"), "kept").unwrap();
        },
        "const message = async (work) => { try { await work(); return 'none'; } catch (error) { return error.message; } };
         return (await Promise.all([
           message(() => fs.remove('keep', { baseDir: base, recursive: 'false' })),
           message(() => fs.remove('keep/note.txt', { baseDir: base, force: 1 })),
           message(() => fs.writeTextFile('new.txt', 'x', { baseDir: base, atmoic: true })),
           message(() => fs.writeTextFile('new.txt', 'x', { baseDir: base, atomic: 'yes' })),
           message(() => fs.mkdir('new', { baseDir: base, recursive: 0 })),
           message(() => fs.readTextFile('keep/note.txt', null)),
           message(() => fs.readTextFile('keep/note.txt', { baseDir: 1 })),
           message(() => fs.readTextFile('keep/note.txt', { baseDir: base, signal: undefined, length: 1 })),
           message(() => fs.readDir('keep', { baseDir: base, recursive: true })),
           fs.readTextFile(base + '/keep/note.txt', { baseDir: undefined, signal: undefined }),
         ])).join('\\n');",
    )
    .await;

    assert_eq!(
        text,
        [
            "the option recursive is not a boolean",
            "the option force is not a boolean",
            "the options has the unknown field 'atmoic'",
            "the option atomic is not a boolean",
            "the option recursive is not a boolean",
            "the options is not an object",
            "the option baseDir is not a string",
            "the options has the unknown field 'length'",
            "the options has the unknown field 'recursive'",
            "kept",
        ]
        .join("\n")
    );
    assert!(folder.join("keep/note.txt").exists());
    assert!(!folder.join("new.txt").exists() && !folder.join("new").exists());
}

#[tokio::test]
async fn a_failure_is_a_file_system_error_with_a_code_and_the_absolute_path() {
    let (text, folder) = run_fs(
        "a_failure_is_a_file_system_error_with_a_code_and_the_absolute_path",
        |_| {},
        "await fs.writeFile('binary.dat', new Uint8Array([0x61, 0xff]), { baseDir: base });
         const codes = [];
         for (const work of [
           () => fs.readTextFile('gone.txt', { baseDir: base }),
           () => fs.readTextFile('binary.dat', { baseDir: base }),
           () => fs.readFile(base),
           () => fs.writeTextFile('missing/folder/x.txt', 'x', { baseDir: base }),
           () => fs.rename('gone.txt', 'other.txt', { baseDir: base }),
         ]) {
           try { await work(); codes.push('none'); } catch (error) {
             codes.push(`${error instanceof fs.FileSystemError} ${error.name} ${error.code} ${error.path} ${error.destination}`);
           }
         }
         return codes.join('\\n');",
    )
    .await;

    let folder = folder.display();
    assert_eq!(
        text,
        format!(
            "true FileSystemError ENOENT {folder}/gone.txt undefined\n\
             true FileSystemError EILSEQ {folder}/binary.dat undefined\n\
             true FileSystemError EISDIR {folder} undefined\n\
             true FileSystemError ENOENT {folder}/missing/folder/x.txt undefined\n\
             true FileSystemError ENOENT {folder}/gone.txt {folder}/other.txt"
        )
    );
}

#[tokio::test]
async fn a_failure_message_names_the_problem_and_the_path() {
    let (text, folder) = run_fs(
        "a_failure_message_names_the_problem_and_the_path",
        |_| {},
        "try { await fs.readTextFile('gone.txt', { baseDir: base }); } catch (error) { return error.message; }
         return 'none';",
    )
    .await;

    assert_eq!(text, format!("the path does not exist: {}/gone.txt", folder.display()));
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
async fn an_atomic_write_into_a_missing_folder_fails_and_leaves_no_temporary_file() {
    let (text, folder) = run_fs(
        "an_atomic_write_into_a_missing_folder_fails_and_leaves_no_temporary_file",
        |_| {},
        "try { await fs.writeTextFile('gone/x.txt', 'x', { baseDir: base, atomic: true }); }
         catch (error) { return error.code; }
         return 'none';",
    )
    .await;

    assert_eq!(text, "ENOENT");
    assert!(!folder.join("gone").exists());
}

#[tokio::test]
async fn read_dir_gives_the_entries_by_name_and_stat_and_lstat_tell_a_link_from_its_target() {
    let (text, folder) = run_fs(
        "read_dir_gives_the_entries_by_name_and_stat_and_lstat_tell_a_link_from_its_target",
        |folder| {
            std::fs::create_dir_all(folder.join("dir/sub")).unwrap();
            std::fs::write(folder.join("dir/b.txt"), "four").unwrap();
            std::fs::write(folder.join("dir/a.txt"), "").unwrap();
            std::os::unix::fs::symlink("b.txt", folder.join("dir/link")).unwrap();
        },
        "const entries = (await fs.readDir('dir', { baseDir: base }))
           .map((entry) => `${entry.name}:${entry.isFile ? 'f' : ''}${entry.isDirectory ? 'd' : ''}${entry.isSymlink ? 'l' : ''}`);
         const target = await fs.stat('dir/link', { baseDir: base });
         const link = await fs.lstat('dir/link', { baseDir: base });
         return [entries.join(','), target.isFile, target.isSymlink, target.size, link.isSymlink, link.isFile,
           target.mtime instanceof Date && Math.abs(target.mtime.getTime() - Date.now()) < 60000].join(' ');",
    )
    .await;

    assert_eq!(text, "a.txt:f,b.txt:f,link:l,sub:d true false 4 true false true");
    assert!(folder.join("dir/link").exists());
}

#[tokio::test]
async fn remove_needs_recursive_for_a_full_folder_and_force_accepts_a_missing_path() {
    let (text, folder) = run_fs(
        "remove_needs_recursive_for_a_full_folder_and_force_accepts_a_missing_path",
        |_| {},
        "await fs.mkdir('full/inner', { baseDir: base, recursive: true });
         await fs.mkdir('empty', { baseDir: base });
         await fs.writeTextFile('file.txt', 'x', { baseDir: base });
         const codes = [];
         const attempt = async (work) => { try { await work(); codes.push('ok'); } catch (error) { codes.push(error.code); } };
         await attempt(() => fs.remove('full', { baseDir: base }));
         await attempt(() => fs.remove('full', { baseDir: base, recursive: true }));
         await attempt(() => fs.remove('empty', { baseDir: base }));
         await attempt(() => fs.remove('file.txt', { baseDir: base }));
         await attempt(() => fs.remove('gone', { baseDir: base }));
         await attempt(() => fs.remove('gone', { baseDir: base, force: true }));
         return codes.join(' ');",
    )
    .await;

    assert_eq!(text, "ENOTEMPTY ok ok ok ENOENT ok");
    assert!(!folder.join("full").exists() && !folder.join("file.txt").exists());
}

#[tokio::test]
async fn rename_moves_a_file_and_replaces_one_at_the_destination() {
    let (text, folder) = run_fs(
        "rename_moves_a_file_and_replaces_one_at_the_destination",
        |_| {},
        "await fs.writeTextFile('a.txt', 'new', { baseDir: base });
         await fs.writeTextFile('b.txt', 'old', { baseDir: base });
         await fs.rename('a.txt', 'b.txt', { baseDir: base });
         return await fs.readTextFile('b.txt', { baseDir: base });",
    )
    .await;

    assert_eq!(text, "new");
    assert!(!folder.join("a.txt").exists());
}

#[tokio::test]
async fn an_aborted_signal_rejects_with_its_reason_and_changes_nothing() {
    let (text, folder) = run_fs(
        "an_aborted_signal_rejects_with_its_reason_and_changes_nothing",
        |_| {},
        "const reason = new Error('stop');
         try { await fs.writeTextFile('x.txt', 'x', { baseDir: base, signal: AbortSignal.abort(reason) }); }
         catch (error) { return String(error === reason); }
         return 'none';",
    )
    .await;

    assert_eq!(text, "true");
    assert!(!folder.join("x.txt").exists());
}

#[tokio::test]
async fn an_abort_during_a_large_read_stops_it_with_the_reason_and_a_fake_abort_event_does_not() {
    let (text, _folder) = run_fs(
        "an_abort_during_a_large_read_stops_it_with_the_reason_and_a_fake_abort_event_does_not",
        |_| {},
        "await fs.writeFile('big.bin', new Uint8Array(64 << 20), { baseDir: base });
         const controller = new AbortController();
         const reading = fs.readFile('big.bin', { baseDir: base, signal: controller.signal });
         controller.abort('stop');
         let stopped;
         try { await reading; stopped = 'none'; } catch (error) { stopped = error; }
         const faked = new AbortController();
         const whole = fs.readFile('big.bin', { baseDir: base, signal: faked.signal });
         faked.signal.dispatchEvent(new Event('abort'));
         return `${stopped} ${(await whole).length}`;",
    )
    .await;

    assert_eq!(text, format!("stop {}", 64 << 20));
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
async fn a_failed_atomic_write_removes_its_temporary_file() {
    let (text, folder) = run_fs(
        "a_failed_atomic_write_removes_its_temporary_file",
        |folder| std::fs::create_dir_all(folder.join("taken/inner")).unwrap(),
        "try { await fs.writeTextFile('taken', 'x', { baseDir: base, atomic: true }); }
         catch (error) { return error instanceof fs.FileSystemError ? 'failed' : String(error); }
         return 'none';",
    )
    .await;

    assert_eq!(text, "failed");
    let names: Vec<String> = std::fs::read_dir(&folder)
        .unwrap()
        .map(|entry| entry.unwrap().file_name().into_string().unwrap())
        .filter(|name| Path::new(name).extension().is_some_and(|extension| extension == "tmp"))
        .collect();
    assert!(names.is_empty(), "{names:?}");
}

#[tokio::test]
async fn an_abort_during_a_large_atomic_write_leaves_the_old_file_and_no_temporary_file() {
    let (text, folder) = run_fs(
        "an_abort_during_a_large_atomic_write_leaves_the_old_file_and_no_temporary_file",
        |folder| std::fs::write(folder.join("big.bin"), "old").unwrap(),
        "const controller = new AbortController();
         const writing = fs.writeFile('big.bin', new Uint8Array(64 << 20), { baseDir: base, atomic: true, signal: controller.signal });
         controller.abort('stop');
         try { await writing; return 'none'; } catch (error) { return String(error); }",
    )
    .await;

    assert_eq!(text, "stop");
    assert_eq!(std::fs::read_to_string(folder.join("big.bin")).unwrap(), "old");
    let temporary = std::fs::read_dir(&folder).unwrap().any(|entry| {
        entry
            .unwrap()
            .path()
            .extension()
            .is_some_and(|extension| extension == "tmp")
    });
    assert!(!temporary);
}

#[tokio::test]
async fn a_read_or_a_write_of_a_fifo_rejects_at_once_and_does_not_wait_for_its_other_end() {
    let (text, folder) = run_fs(
        "a_read_or_a_write_of_a_fifo_rejects_at_once_and_does_not_wait_for_its_other_end",
        |folder| {
            let status = std::process::Command::new("mkfifo")
                .arg(folder.join("pipe"))
                .status()
                .unwrap();
            assert!(status.success());
        },
        "const codes = [];
         for (const work of [
           () => fs.readFile('pipe', { baseDir: base }),
           () => fs.writeTextFile('pipe', 'x', { baseDir: base }),
           () => fs.writeTextFile('pipe', 'x', { baseDir: base, atomic: true }),
         ]) {
           try { await work(); codes.push('none'); } catch (error) { codes.push(error.code); }
         }
         return codes.join(' ');",
    )
    .await;

    assert_eq!(text, "EINVAL EINVAL EINVAL");
    assert!(folder.join("pipe").metadata().unwrap().file_type().is_fifo());
}

#[tokio::test]
async fn a_symbolic_link_loop_rejects_with_eloop() {
    let (text, _folder) = run_fs(
        "a_symbolic_link_loop_rejects_with_eloop",
        |folder| {
            std::os::unix::fs::symlink("second", folder.join("first")).unwrap();
            std::os::unix::fs::symlink("first", folder.join("second")).unwrap();
        },
        "try { await fs.stat('first', { baseDir: base }); return 'none'; } catch (error) { return error.code; }",
    )
    .await;

    assert_eq!(text, "ELOOP");
}

#[tokio::test]
async fn a_time_before_the_epoch_is_a_date_and_not_null() {
    let (text, _folder) = run_fs(
        "a_time_before_the_epoch_is_a_date_and_not_null",
        |folder| {
            let file = std::fs::File::create(folder.join("old.txt")).unwrap();
            let time = std::time::UNIX_EPOCH - Duration::from_hours(10 * 365 * 24);
            file.set_modified(time).unwrap();
        },
        "const info = await fs.stat('old.txt', { baseDir: base });
         return String(info.mtime !== null && info.mtime.getUTCFullYear() < 1970);",
    )
    .await;

    assert_eq!(text, "true");
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
