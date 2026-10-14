//! The tools `exec` and `stop`, the background jobs, and the declarations of the native modules.

use std::ffi::OsStr;
use std::fmt::Write as _;
use std::path::Path;
use std::sync::Arc;
use std::time::{Duration, Instant};

use yuke_engine::CancellationToken;

use super::tools::{TestHost, call, call_with, error_of, text_of, tools_in, tools_of};
use super::{LIMITS, folder};
use crate::native;
use crate::processes::{recovered_home, whole_characters};
use crate::{Options, Processes, Runtime, SessionHost};

/// The id of the job that the start text `started` names, for example `job-a1b2`.
fn job_id(started: &str) -> String {
    let id = started.trim_start_matches('[').split(' ').next().unwrap_or_default();
    let digits = id.strip_prefix("job-").unwrap_or_default();
    assert!(
        digits.len() == 4
            && digits
                .chars()
                .all(|digit| digit.is_ascii_digit() || digit.is_ascii_lowercase()),
        "{started}"
    );
    id.to_owned()
}

/// The longest wait of a test step.
const WAIT: Duration = Duration::from_secs(5);

/// The job ends that `host` has received, after at most five seconds of waiting for `count` of them.
async fn ended_texts(host: &TestHost, count: usize) -> Vec<String> {
    let deadline = Instant::now() + Duration::from_secs(5);
    loop {
        let texts: Vec<String> = host
            .ended
            .lock()
            .unwrap()
            .iter()
            .map(|ended| ended.text.clone())
            .collect();
        if texts.len() >= count || Instant::now() > deadline {
            return texts;
        }
        tokio::time::sleep(Duration::from_millis(20)).await;
    }
}

/// The text of a call that `exec` answers for `command`.
async fn run(tools: &std::collections::HashMap<String, crate::ScriptTool>, command: &str) -> String {
    let arguments = json_string(command);
    text_of(&tools["exec"], &format!(r#"{{"command": {arguments}}}"#)).await
}

/// `text` as a JSON string.
fn json_string(text: &str) -> String {
    let mut quoted = String::from("\"");
    for character in text.chars() {
        match character {
            '"' => quoted.push_str("\\\""),
            '\\' => quoted.push_str("\\\\"),
            '\n' => quoted.push_str("\\n"),
            other => quoted.push(other),
        }
    }
    quoted.push('"');
    quoted
}

#[tokio::test]
async fn exec_answers_the_output_in_write_order_and_the_exit_code() {
    let folder = folder("exec_answers_the_output_in_write_order_and_the_exit_code");
    let (_runtime, _host, tools) = tools_of(&folder, &["yuke:builtins"]).await;

    let text = run(&tools, "printf 'a\\n'; printf 'b\\n' >&2; printf 'c\\n'; pwd; exit 3").await;

    assert_eq!(text, format!("a\nb\nc\n{}\n[exit code: 3]", folder.display()));
}

#[tokio::test]
async fn a_command_leads_its_own_session_without_the_terminal_of_yuke() {
    let folder = folder("a_command_leads_its_own_session_without_the_terminal_of_yuke");
    let (_runtime, _host, tools) = tools_of(&folder, &["yuke:builtins"]).await;

    // The `ps` of Linux and of macOS both mark a session leader with `s` in the process state.
    let text = run(&tools, "ps -o stat= -p $$").await;

    let state = text.lines().next().unwrap().trim();
    assert!(state.contains('s'), "{text}");
}

#[tokio::test]
async fn exec_without_output_says_so() {
    let folder = folder("exec_without_output_says_so");
    let (_runtime, _host, tools) = tools_of(&folder, &["yuke:builtins"]).await;

    assert_eq!(run(&tools, "true").await, "[no output]\n[exit code: 0]");
}

#[tokio::test]
async fn exec_gives_its_output_as_live_texts() {
    let folder = folder("exec_gives_its_output_as_live_texts");
    let (_runtime, _host, tools) = tools_of(&folder, &["yuke:builtins"]).await;

    let (answer, texts) = call(&tools["exec"], r#"{"command": "echo one; sleep 0.1; echo two"}"#).await;

    assert_eq!(answer.unwrap().text, "one\ntwo\n[exit code: 0]");
    assert_eq!(texts.concat(), "one\ntwo\n");
}

#[tokio::test]
async fn exec_at_its_deadline_stops_the_process_group() {
    let folder = folder("exec_at_its_deadline_stops_the_process_group");
    let (_runtime, _host, tools) = tools_of(&folder, &["yuke:builtins"]).await;
    let started = Instant::now();

    let text = text_of(
        &tools["exec"],
        r#"{"command": "echo begun; sleep 30", "timeout_ms": 200}"#,
    )
    .await;

    assert!(started.elapsed() < Duration::from_secs(4), "{:?}", started.elapsed());
    assert!(
        text.starts_with("begun\n[timeout: 200 ms. yuke stopped the process group."),
        "{text}"
    );
}

// The shell ends at once on SIGTERM, but another process of its group needs time to clean up.
#[tokio::test]
async fn each_process_of_a_stopped_group_gets_the_grace() {
    let folder = folder("each_process_of_a_stopped_group_gets_the_grace");
    let (_runtime, _host, tools) = tools_of(&folder, &["yuke:builtins"]).await;
    let command = "sh -c 'trap \"sleep 0.3; echo done > cleaned; exit 0\" TERM; while :; do sleep 0.05; done' & wait";

    text_of(
        &tools["exec"],
        &format!(r#"{{"command": {}, "timeout_ms": 300}}"#, json_string(command)),
    )
    .await;

    assert_eq!(std::fs::read_to_string(folder.join("cleaned")).unwrap(), "done\n");
}

#[tokio::test]
async fn a_cancel_stops_the_command_and_the_tool_still_answers() {
    let folder = folder("a_cancel_stops_the_command_and_the_tool_still_answers");
    let (_runtime, _host, tools) = tools_of(&folder, &["yuke:builtins"]).await;
    let token = CancellationToken::new();
    let cancel = token.clone();
    tokio::spawn(async move {
        tokio::time::sleep(Duration::from_millis(100)).await;
        cancel.cancel();
    });

    let (answer, _texts) = call_with(&tools["exec"], r#"{"command": "sleep 30"}"#, token).await;

    assert_eq!(
        answer.unwrap().text,
        "[no output]\n[stopped: the tool call was cancelled.]"
    );
}

#[tokio::test]
async fn exec_ends_every_process_that_it_starts() {
    let folder = folder("exec_ends_every_process_that_it_starts");
    let (_runtime, _host, tools) = tools_of(&folder, &["yuke:builtins"]).await;
    let started = Instant::now();

    // The background sleep holds the output pipe. Only its end lets the read finish before the grace.
    let text = run(&tools, "sleep 30 & echo started").await;

    assert_eq!(text, "started\n[exit code: 0]");
    assert!(
        started.elapsed() < Duration::from_millis(1500),
        "{:?}",
        started.elapsed()
    );
}

#[tokio::test]
async fn a_character_across_the_end_of_the_head_stays_whole() {
    let folder = folder("a_character_across_the_end_of_the_head_stays_whole");
    let (_runtime, _host, tools) = tools_of(&folder, &["yuke:builtins"]).await;

    // The head holds 25600 bytes, so the four bytes of the emoji start one byte before its end.
    let text = run(
        &tools,
        "head -c 25599 /dev/zero | tr '\\0' a; printf '\\360\\237\\230\\200b'",
    )
    .await;

    assert!(
        text.ends_with("a\u{1f600}b\n[exit code: 0]"),
        "{}",
        &text[text.len() - 30..]
    );
    assert!(!text.contains('\u{fffd}'));
}

#[tokio::test]
async fn exec_output_over_the_cap_keeps_a_head_a_tail_and_the_full_file() {
    let folder = folder("exec_output_over_the_cap_keeps_a_head_a_tail_and_the_full_file");
    let (_runtime, _host, tools) = tools_of(&folder, &["yuke:builtins"]).await;

    let text = run(&tools, "seq 1 30000").await;

    assert!(text.starts_with("1\n2\n3\n"), "{}", &text[..20]);
    assert!(
        text.ends_with("29999\n30000\n[exit code: 0]"),
        "{}",
        &text[text.len() - 40..]
    );
    assert!(text.len() < 52 * 1024, "{}", text.len());
    let marker = text.lines().find(|line| line.starts_with("[yuke cut ")).unwrap();
    let path = marker
        .split("Full output: ")
        .nth(1)
        .unwrap()
        .split(". Read it")
        .next()
        .unwrap();
    let full = std::fs::read_to_string(path).unwrap();
    let mut expected = String::new();
    for number in 1..=30_000 {
        writeln!(expected, "{number}").unwrap();
    }
    assert_eq!(full, expected);
}

#[tokio::test]
async fn a_dropped_exec_call_stops_its_command() {
    let folder = folder("a_dropped_exec_call_stops_its_command");
    let (_runtime, _host, tools) = tools_of(&folder, &["yuke:builtins"]).await;
    let pid_file = folder.join("pid");
    let command = format!(r#"{{"command": "echo $$ > {}; exec sleep 30"}}"#, pid_file.display());

    let dropped = tokio::time::timeout(Duration::from_millis(300), call(&tools["exec"], &command)).await;

    assert!(dropped.is_err());
    let pid: i32 = std::fs::read_to_string(&pid_file).unwrap().trim().parse().unwrap();
    let pid = rustix::process::Pid::from_raw(pid).unwrap();
    let deadline = Instant::now() + Duration::from_secs(5);
    while rustix::process::test_kill_process(pid).is_ok() {
        assert!(Instant::now() < deadline, "the command still runs");
        tokio::time::sleep(Duration::from_millis(20)).await;
    }
}

#[tokio::test]
async fn a_background_job_starts_and_its_end_reaches_the_session() {
    let folder = folder("a_background_job_starts_and_its_end_reaches_the_session");
    let (_runtime, host, tools) = tools_of(&folder, &["yuke:builtins"]).await;

    let text = text_of(
        &tools["exec"],
        r#"{"command": "echo hello; exit 4", "background": true}"#,
    )
    .await;

    let id = job_id(&text);
    let log = folder.join(format!("processes/{id}.log"));
    assert_eq!(
        text,
        format!(
            "[{id} started: echo hello; exit 4. Log: {}. Its end arrives as a message, so never sleep or poll. Use \
             stop with {id} to end it.]",
            log.display()
        )
    );
    assert_eq!(
        ended_texts(&host, 1).await,
        [format!(
            "[{id} exited 4. This message is not from the user.]\nLog: {}\nhello",
            log.display()
        )]
    );
    // An ended job leaves the list: its end message has told the model already.
    assert_eq!(
        error_of(&tools["stop"], &format!(r#"{{"id": "{id}"}}"#)).await,
        format!("The id {id} does not exist. Nothing runs.")
    );
}

#[tokio::test]
async fn a_background_start_fails_when_the_processes_start_no_jobs() {
    let folder = folder("a_background_start_fails_when_the_processes_start_no_jobs");
    let (runtime, _faults) = Runtime::start(Options {
        limits: LIMITS,
        cache: folder.join("cache"),
        processes: Arc::new(Processes::without_jobs(folder.join("processes"))),
    })
    .await
    .unwrap();
    let (_runtime, host, tools) = tools_in(runtime, &folder, &["yuke:builtins"]).await;

    let error = error_of(&tools["exec"], r#"{"command": "touch started", "background": true}"#).await;

    assert_eq!(
        error,
        "This run ends with its turn, so it cannot start a background job. Run the command without background."
    );
    assert!(!folder.join("started").exists());
    assert!(host.ended.lock().unwrap().is_empty());
    // A command in the foreground still runs.
    assert_eq!(run(&tools, "echo ran").await, "ran\n[exit code: 0]");
}

#[tokio::test]
async fn stop_ends_a_job_and_no_end_message_follows() {
    let folder = folder("stop_ends_a_job_and_no_end_message_follows");
    let (_runtime, host, tools) = tools_of(&folder, &["yuke:builtins"]).await;
    let id = job_id(&text_of(&tools["exec"], r#"{"command": "sleep 30", "background": true}"#).await);

    let text = text_of(&tools["stop"], &format!(r#"{{"id": "{id}"}}"#)).await;

    assert_eq!(
        text,
        format!(
            "[{id} stopped.] Log: {}",
            folder.join(format!("processes/{id}.log")).display()
        )
    );
    tokio::time::sleep(Duration::from_millis(200)).await;
    assert!(host.ended.lock().unwrap().is_empty());
}

#[tokio::test]
async fn stop_of_an_unknown_id_names_the_running_jobs() {
    let folder = folder("stop_of_an_unknown_id_names_the_running_jobs");
    let (_runtime, _host, tools) = tools_of(&folder, &["yuke:builtins"]).await;

    let before = error_of(&tools["stop"], r#"{"id": "job-zz"}"#).await;
    let id = job_id(&text_of(&tools["exec"], r#"{"command": "sleep 30", "background": true}"#).await);
    let after = error_of(&tools["stop"], r#"{"id": "job-zz"}"#).await;

    assert_eq!(before, "The id job-zz does not exist. Nothing runs.");
    assert_eq!(after, format!("The id job-zz does not exist. The ids are: {id}."));
    text_of(&tools["stop"], &format!(r#"{{"id": "{id}"}}"#)).await;
}

#[tokio::test]
async fn a_background_command_takes_no_timeout() {
    let folder = folder("a_background_command_takes_no_timeout");
    let (_runtime, _host, tools) = tools_of(&folder, &["yuke:builtins"]).await;

    let error = error_of(
        &tools["exec"],
        r#"{"command": "sleep 1", "background": true, "timeout_ms": 10}"#,
    )
    .await;

    assert_eq!(error, "Remove timeout_ms, or set background to false.");
}

/// A runtime with `processes` and the built-in tools, for the session of `host`.
async fn runtime_with(folder: &Path, processes: &Arc<Processes>, host: &Arc<TestHost>) -> (Runtime, crate::ScriptTool) {
    let started = Runtime::start(Options {
        limits: LIMITS,
        cache: folder.join("cache"),
        processes: Arc::clone(processes),
    });
    let (runtime, _faults) = tokio::time::timeout(WAIT, started).await.unwrap().unwrap();
    tokio::time::timeout(WAIT, runtime.import("yuke:builtins"))
        .await
        .unwrap()
        .unwrap();
    let exec = runtime
        .tools(Arc::clone(host) as Arc<dyn SessionHost>)
        .await
        .unwrap()
        .into_iter()
        .find(|(definition, _)| definition.name == "exec")
        .unwrap()
        .1;
    (runtime, exec)
}

#[tokio::test]
async fn a_job_outlives_a_reload_of_the_runtime() {
    let folder = folder("a_job_outlives_a_reload_of_the_runtime");
    let processes = Arc::new(Processes::new(folder.join("processes")));
    let host = Arc::new(TestHost {
        folder: folder.clone(),
        ..TestHost::default()
    });
    let (runtime, exec) = runtime_with(&folder, &processes, &host).await;
    text_of(&exec, r#"{"command": "sleep 0.5; echo done", "background": true}"#).await;

    tokio::time::timeout(WAIT, runtime.shutdown()).await.unwrap().unwrap();
    let (_runtime, _exec) = runtime_with(&folder, &processes, &host).await;

    let texts = ended_texts(&host, 1).await;
    assert_eq!(texts.len(), 1, "{texts:?}");
    assert!(
        texts[0].starts_with("[job-") && texts[0].contains(" exited 0."),
        "{}",
        texts[0]
    );
    assert!(texts[0].ends_with("\ndone"), "{}", texts[0]);
}

#[tokio::test]
async fn a_shutdown_of_the_processes_removes_their_folder() {
    let folder = folder("a_shutdown_of_the_processes_removes_their_folder");
    let processes = Arc::new(Processes::new(folder.join("processes")));
    let host = Arc::new(TestHost {
        folder: folder.clone(),
        ..TestHost::default()
    });
    let (_runtime, exec) = runtime_with(&folder, &processes, &host).await;
    text_of(&exec, r#"{"command": "sleep 30", "background": true}"#).await;
    let had_log = folder.join("processes").exists();

    processes.shutdown().await.unwrap();

    assert!(had_log);
    assert!(!folder.join("processes").exists());
}

// A job start after the shutdown fails, and it leaves no job and no folder.
#[tokio::test]
async fn a_job_start_after_the_shutdown_fails_and_leaves_no_job() {
    let folder = folder("a_job_start_after_the_shutdown_fails_and_leaves_no_job");
    let processes = Arc::new(Processes::new(folder.join("processes")));
    let host = Arc::new(TestHost {
        folder: folder.clone(),
        ..TestHost::default()
    });
    let (_runtime, exec) = runtime_with(&folder, &processes, &host).await;
    processes.shutdown().await.unwrap();

    let error = error_of(&exec, r#"{"command": "sleep 30", "background": true}"#).await;

    assert!(error.contains("yuke is shutting down"), "{error}");
    let owner: Arc<dyn SessionHost> = host;
    assert_eq!(processes.running_jobs(&owner), Vec::<String>::new());
    assert!(!folder.join("processes").exists());
}

#[tokio::test]
async fn a_shutdown_of_the_processes_stops_each_job_without_an_end_message() {
    let folder = folder("a_shutdown_of_the_processes_stops_each_job_without_an_end_message");
    let processes = Arc::new(Processes::new(folder.join("processes")));
    let host = Arc::new(TestHost {
        folder: folder.clone(),
        ..TestHost::default()
    });
    let (_runtime, exec) = runtime_with(&folder, &processes, &host).await;
    text_of(&exec, r#"{"command": "sleep 30", "background": true}"#).await;

    tokio::time::timeout(Duration::from_secs(5), processes.shutdown())
        .await
        .unwrap()
        .unwrap();

    tokio::time::sleep(Duration::from_millis(200)).await;
    assert!(host.ended.lock().unwrap().is_empty());
}

#[tokio::test]
async fn a_dropped_processes_kills_its_jobs_without_an_end_message() {
    let folder = folder("a_dropped_processes_kills_its_jobs_without_an_end_message");
    let processes = Arc::new(Processes::new(folder.join("processes")));
    let host = Arc::new(TestHost {
        folder: folder.clone(),
        ..TestHost::default()
    });
    let (runtime, exec) = runtime_with(&folder, &processes, &host).await;
    let pid_file = folder.join("pid");
    let command = format!(
        r#"{{"command": "echo $$ > {}; exec sleep 30", "background": true}}"#,
        pid_file.display()
    );
    text_of(&exec, &command).await;
    let deadline = Instant::now() + WAIT;
    while !pid_file.exists() {
        assert!(Instant::now() < deadline, "the job did not start");
        tokio::time::sleep(Duration::from_millis(20)).await;
    }
    let pid: i32 = std::fs::read_to_string(&pid_file).unwrap().trim().parse().unwrap();

    drop(exec);
    tokio::time::timeout(WAIT, runtime.shutdown()).await.unwrap().unwrap();
    drop(processes);

    let pid = rustix::process::Pid::from_raw(pid).unwrap();
    while rustix::process::test_kill_process(pid).is_ok() {
        assert!(Instant::now() < deadline, "the job still runs");
        tokio::time::sleep(Duration::from_millis(20)).await;
    }
    tokio::time::sleep(Duration::from_millis(200)).await;
    assert!(host.ended.lock().unwrap().is_empty());
}

#[tokio::test]
async fn each_job_of_a_process_gets_a_new_id() {
    let folder = folder("each_job_of_a_process_gets_a_new_id");
    let (_runtime, _host, tools) = tools_of(&folder, &["yuke:builtins"]).await;

    let mut ids = Vec::new();
    for _ in 0..3 {
        ids.push(job_id(
            &text_of(&tools["exec"], r#"{"command": "true", "background": true}"#).await,
        ));
    }

    ids.sort_unstable();
    ids.dedup();
    assert_eq!(ids.len(), 3, "{ids:?}");
}

#[tokio::test]
async fn processes_start_their_job_ids_at_different_numbers() {
    let folder = folder("processes_start_their_job_ids_at_different_numbers");

    let mut firsts: Vec<String> = (0..5)
        .map(|number| Processes::new(folder.join(number.to_string())).job_id())
        .collect();

    // Two random starts are equal once in 1,632,960 runs. Five equal starts are about 1 in 10^25.
    firsts.sort_unstable();
    firsts.dedup();
    assert!(firsts.len() > 1, "{firsts:?}");
}

// A read can end inside a character after an invalid byte. Only the incomplete character waits for the next read.
#[test]
fn live_output_keeps_an_incomplete_character_after_an_invalid_byte() {
    let mut bytes = vec![0xFF, 0xE2];
    let first = whole_characters(&mut bytes);
    bytes.extend_from_slice(&[0x82, 0xAC]);
    let second = whole_characters(&mut bytes);

    assert_eq!(first + &second, "\u{FFFD}\u{20AC}");
    assert_eq!(bytes, Vec::<u8>::new());
}

#[test]
fn a_child_gets_the_home_folder_of_the_user_when_home_is_missing_or_empty() {
    let user_home = std::env::home_dir().filter(|home| home.is_absolute());

    assert_eq!(recovered_home(None), user_home);
    assert_eq!(recovered_home(Some(OsStr::new(""))), user_home);
    assert_eq!(recovered_home(Some(OsStr::new("/home/someone"))), None);
}

#[test]
fn each_native_module_declares_the_names_that_it_exports() {
    let declarations = include_str!("../../types/native.d.ts");
    for (name, exports) in native::modules() {
        let start = declarations
            .find(&format!("declare module \"{name}\""))
            .unwrap_or_else(|| panic!("native.d.ts does not declare {name}"));
        let block = &declarations[start..];
        let block = &block[..block[1..].find("\ndeclare module").map_or(block.len(), |end| end + 1)];
        let mut declared: Vec<&str> = block
            .lines()
            .filter_map(|line| line.trim().strip_prefix("export function "))
            .map(|line| line.split('(').next().unwrap_or_default())
            .collect();
        declared.sort_unstable();
        let mut exported = exports.to_vec();
        exported.sort_unstable();
        assert_eq!(declared, exported, "{name}");
    }
}
