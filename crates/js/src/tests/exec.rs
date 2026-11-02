//! The tools `exec` and `stop`, the background jobs, and the declarations of the native module.

use std::ffi::OsStr;
use std::path::Path;
use std::sync::Arc;
use std::time::{Duration, Instant};

use yuke_ai::Block;
use yuke_engine::CancellationToken;
use yuke_protocol::{Input, JobState};

use super::tools::{TestHost, Tools, error_of, text_of, tools_in, tools_of};
use super::{folder, options, start};
use crate::native;
use crate::processes::{Request, recovered_home};
use crate::{Processes, Runtime};

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

/// The text that the model reads for `input`.
fn model_text(input: &Input) -> String {
    match input.model_content() {
        [Block::UserText(text)] => text.clone(),
        other => panic!("the input is not one text: {other:?}"),
    }
}

/// The longest wait of a test step.
const WAIT: Duration = Duration::from_secs(5);

#[tokio::test(flavor = "local")]
async fn a_cancel_stops_the_command_and_the_tool_still_answers() {
    let folder = folder("a_cancel_stops_the_command_and_the_tool_still_answers");
    let (_runtime, _host, tools) = tools_of(&folder, &["yuke:internal/builtins"]).await;
    let token = CancellationToken::new();
    let (output, mut texts) = tokio::sync::mpsc::unbounded_channel();
    let answer = tools["exec"].answer(
        r#"{"command": "echo ready; exec sleep 30"}"#,
        "call-1",
        token.clone(),
        output,
    );
    tokio::pin!(answer);
    let ready = tokio::select! {
        biased;
        result = &mut answer => panic!("the command ended before readiness: {result:?}"),
        text = tokio::time::timeout(WAIT, texts.recv()) => text.unwrap().unwrap(),
    };
    assert_eq!(ready, "ready\n");
    token.cancel();
    let answer = tokio::time::timeout(WAIT, answer).await.unwrap();

    let content = answer.unwrap();
    assert_eq!(content.text, "ready\n[stopped: the tool call was cancelled.]");
    assert!(content.is_error);
}

#[tokio::test(flavor = "local")]
async fn a_dropped_exec_call_stops_its_command() {
    let folder = folder("a_dropped_exec_call_stops_its_command");
    let (_runtime, _host, tools) = tools_of(&folder, &["yuke:internal/builtins"]).await;
    let pid_file = folder.join("pid");
    let command = format!(
        r#"{{"command": "echo $$ > {}; echo ready; exec sleep 30"}}"#,
        pid_file.display()
    );

    {
        let (output, mut texts) = tokio::sync::mpsc::unbounded_channel();
        let answer = tools["exec"].answer(&command, "call-1", CancellationToken::new(), output);
        tokio::pin!(answer);
        let ready = tokio::select! {
            biased;
            result = &mut answer => panic!("the command ended before readiness: {result:?}"),
            text = tokio::time::timeout(WAIT, texts.recv()) => text.unwrap().unwrap(),
        };
        assert_eq!(ready, "ready\n");
    }
    let pid: i32 = std::fs::read_to_string(&pid_file).unwrap().trim().parse().unwrap();
    let pid = rustix::process::Pid::from_raw(pid).unwrap();
    let deadline = Instant::now() + Duration::from_secs(5);
    while rustix::process::test_kill_process(pid).is_ok() {
        assert!(Instant::now() < deadline, "the command still runs");
        tokio::time::sleep(Duration::from_millis(20)).await;
    }
}

#[tokio::test(flavor = "local")]
async fn a_background_job_starts_and_its_end_reaches_the_session() {
    let folder = folder("a_background_job_starts_and_its_end_reaches_the_session");
    let (_runtime, host, tools) = tools_of(&folder, &["yuke:internal/builtins"]).await;

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
    tokio::time::timeout(WAIT, host.input_received.notified())
        .await
        .unwrap();
    assert_eq!(
        host.inputs.lock().unwrap().iter().map(model_text).collect::<Vec<_>>(),
        [format!(
            "<system_notification plugin=\"host:jobs\">{id} exited 4.\nLog: {}\nhello</system_notification>",
            log.display()
        )]
    );
    assert_eq!(
        host.inputs.lock().unwrap()[0].content(),
        [Block::user_text(format!("{id} exited 4"))]
    );
    // An ended job leaves the list: its report has told the model already.
    assert_eq!(
        error_of(&tools["stop"], &format!(r#"{{"id": "{id}"}}"#)).await,
        format!("The id {id} does not exist. Nothing runs.")
    );
}

#[tokio::test(flavor = "local")]
async fn a_background_start_fails_when_the_processes_start_no_jobs() {
    let folder = folder("a_background_start_fails_when_the_processes_start_no_jobs");
    let (runtime, _faults) = Runtime::start(options(
        &folder,
        Arc::new(Processes::without_jobs(folder.join("processes"))),
    ))
    .await
    .unwrap();
    let (_runtime, host, tools) =
        tools_in(runtime, Arc::new(TestHost::new(&folder)), &["yuke:internal/builtins"]).await;

    let error = error_of(&tools["exec"], r#"{"command": "touch started", "background": true}"#).await;

    assert_eq!(
        error,
        "This run ends with its turn, so it cannot start a background job. Run the command without background."
    );
    assert!(!folder.join("started").exists());
    assert!(host.inputs.lock().unwrap().is_empty());
    // A command in the foreground still runs.
    assert_eq!(
        text_of(&tools["exec"], r#"{"command": "echo ran"}"#).await,
        "ran\n[exit code: 0]"
    );
}

#[tokio::test(flavor = "local")]
async fn stop_of_an_unknown_id_names_the_running_jobs() {
    let folder = folder("stop_of_an_unknown_id_names_the_running_jobs");
    let (_runtime, _host, tools) = tools_of(&folder, &["yuke:internal/builtins"]).await;

    let before = error_of(&tools["stop"], r#"{"id": "job-zz"}"#).await;
    let id = job_id(&text_of(&tools["exec"], r#"{"command": "sleep 30", "background": true}"#).await);
    let after = error_of(&tools["stop"], r#"{"id": "job-zz"}"#).await;

    assert_eq!(before, "The id job-zz does not exist. Nothing runs.");
    assert_eq!(after, format!("The id job-zz does not exist. The ids are: {id}."));
    text_of(&tools["stop"], &format!(r#"{{"id": "{id}"}}"#)).await;
}

#[tokio::test(flavor = "local")]
async fn a_background_job_with_a_timeout_ends_and_reports_it() {
    let folder = folder("a_background_job_with_a_timeout_ends_and_reports_it");
    let processes = Arc::new(Processes::new(folder.join("processes")));
    let host = Arc::new(TestHost::new(&folder));
    let (_runtime, exec) = runtime_with(&folder, &processes, &host).await;

    let started = text_of(
        &exec["exec"],
        r#"{"command": "echo started; exec sleep 30", "background": true, "timeout_ms": 200}"#,
    )
    .await;

    let id = job_id(&started);
    tokio::time::timeout(WAIT, host.input_received.notified())
        .await
        .unwrap();
    let texts: Vec<String> = host.inputs.lock().unwrap().iter().map(model_text).collect();
    assert!(
        texts[0].contains(&format!("{id} timed out after 200 ms.")),
        "{}",
        texts[0]
    );
    assert!(texts[0].contains("started"), "{}", texts[0]);
    assert_eq!(processes.jobs().running(host.session), []);
    let changed = host.changed.lock().unwrap().clone();
    assert_eq!(changed.last().map(|job| job.state), Some(JobState::Ended));
    processes.shutdown().await.unwrap();
}

/// A runtime with `processes` and the built-in tools, for the session of `host`.
async fn runtime_with(folder: &Path, processes: &Arc<Processes>, host: &Arc<TestHost>) -> (Runtime, Tools) {
    let started = Runtime::start(options(folder, Arc::clone(processes)));
    let (runtime, _faults) = tokio::time::timeout(WAIT, started).await.unwrap().unwrap();
    let (runtime, _host, tools) = tools_in(runtime, Arc::clone(host), &["yuke:internal/builtins"]).await;
    (runtime, tools)
}

#[tokio::test(flavor = "local")]
async fn a_process_job_outlives_a_reload_of_the_runtime() {
    let folder = folder("a_process_job_outlives_a_reload_of_the_runtime");
    let processes = Arc::new(Processes::new(folder.join("processes")));
    let host = Arc::new(TestHost::new(&folder));
    let (runtime, exec) = runtime_with(&folder, &processes, &host).await;
    text_of(
        &exec["exec"],
        r#"{"command": "sleep 0.5; echo done", "background": true}"#,
    )
    .await;

    tokio::time::timeout(WAIT, runtime.shutdown()).await.unwrap().unwrap();
    let (_runtime, _exec) = runtime_with(&folder, &processes, &host).await;

    tokio::time::timeout(WAIT, host.input_received.notified())
        .await
        .unwrap();
    let texts: Vec<String> = host.inputs.lock().unwrap().iter().map(model_text).collect();
    assert_eq!(texts.len(), 1, "{texts:?}");
    assert!(
        texts[0].contains(">job-") && texts[0].contains(" exited 0."),
        "{}",
        texts[0]
    );
    assert!(texts[0].ends_with("\ndone</system_notification>"), "{}", texts[0]);
}

#[tokio::test(flavor = "local")]
async fn a_shutdown_stops_each_job_without_a_report_and_removes_the_folder() {
    let folder = folder("a_shutdown_stops_each_job_without_a_report_and_removes_the_folder");
    let processes = Arc::new(Processes::new(folder.join("processes")));
    let host = Arc::new(TestHost::new(&folder));
    let (_runtime, exec) = runtime_with(&folder, &processes, &host).await;
    text_of(&exec["exec"], r#"{"command": "sleep 30", "background": true}"#).await;
    let had_log = folder.join("processes").exists();

    processes.shutdown().await.unwrap();

    assert!(had_log);
    assert!(!folder.join("processes").exists());
    // A shutdown stops each job, and a stopped job sends no report.
    assert!(host.inputs.lock().unwrap().is_empty());
}

// A job start after the shutdown fails, and it leaves no job and no folder.
#[tokio::test(flavor = "local")]
async fn a_job_start_after_the_shutdown_fails_and_leaves_no_job() {
    let folder = folder("a_job_start_after_the_shutdown_fails_and_leaves_no_job");
    let processes = Arc::new(Processes::new(folder.join("processes")));
    let host = Arc::new(TestHost::new(&folder));
    let (_runtime, exec) = runtime_with(&folder, &processes, &host).await;
    processes.shutdown().await.unwrap();

    let error = error_of(&exec["exec"], r#"{"command": "sleep 30", "background": true}"#).await;

    assert!(error.contains("yuke is shutting down"), "{error}");
    assert_eq!(processes.jobs().running(host.session), []);
    assert!(!folder.join("processes").exists());
}

#[tokio::test(flavor = "local")]
async fn closing_a_session_stops_only_its_jobs_and_refuses_its_later_jobs() {
    let folder = folder("closing_a_session_stops_only_its_jobs_and_refuses_its_later_jobs");
    let processes = Arc::new(Processes::new(folder.join("processes")));
    let (first, second) = (Arc::new(TestHost::new(&folder)), Arc::new(TestHost::new(&folder)));
    let (_first_runtime, first_exec) = runtime_with(&folder, &processes, &first).await;
    let (_second_runtime, second_exec) = runtime_with(&folder, &processes, &second).await;
    text_of(&first_exec["exec"], r#"{"command": "sleep 30", "background": true}"#).await;
    let kept = job_id(&text_of(&second_exec["exec"], r#"{"command": "sleep 31", "background": true}"#).await);

    first.closed.store(true, std::sync::atomic::Ordering::Relaxed);
    tokio::time::timeout(WAIT, processes.jobs().close_session(first.session))
        .await
        .unwrap();
    let late = error_of(&first_exec["exec"], r#"{"command": "sleep 32", "background": true}"#).await;

    assert!(late.contains("its session is closed"), "{late}");
    assert_eq!(processes.jobs().running(first.session), []);
    let running = processes.jobs().running(second.session);
    assert_eq!(
        running
            .iter()
            .map(|job| (job.id.as_str(), job.label.as_str()))
            .collect::<Vec<_>>(),
        [(kept.as_str(), "sleep 31")]
    );
    assert!(first.inputs.lock().unwrap().is_empty());
    processes.shutdown().await.unwrap();
}

#[tokio::test(flavor = "local")]
async fn a_shutdown_waits_until_a_job_that_ended_has_delivered_its_end() {
    let folder = folder("a_shutdown_waits_until_a_job_that_ended_has_delivered_its_end");
    let processes = Arc::new(Processes::new(folder.join("processes")));
    let gate = Arc::new(tokio::sync::Notify::new());
    let host = Arc::new(TestHost {
        end_gate: Some(Arc::clone(&gate)),
        ..TestHost::new(&folder)
    });
    let (_runtime, exec) = runtime_with(&folder, &processes, &host).await;
    text_of(&exec["exec"], r#"{"command": "echo hello", "background": true}"#).await;
    tokio::time::timeout(WAIT, host.job_ended.notified()).await.unwrap();
    assert_eq!(processes.jobs().running(host.session), []);

    let mut shutdown = std::pin::pin!(processes.shutdown());
    tokio::select! {
        biased;
        result = &mut shutdown => panic!("the shutdown ended before delivery: {result:?}"),
        () = crate::settled() => {}
    }
    gate.notify_one();
    tokio::time::timeout(WAIT, shutdown).await.unwrap().unwrap();

    let texts: Vec<String> = host.inputs.lock().unwrap().iter().map(model_text).collect();
    assert_eq!(texts.len(), 1);
    assert!(texts[0].ends_with("\nhello</system_notification>"), "{}", texts[0]);
}

#[tokio::test(flavor = "local")]
async fn a_dropped_processes_kills_its_jobs_without_a_report() {
    let folder = folder("a_dropped_processes_kills_its_jobs_without_a_report");
    let processes = Arc::new(Processes::new(folder.join("processes")));
    let host = Arc::new(TestHost::new(&folder));
    let (runtime, exec) = runtime_with(&folder, &processes, &host).await;
    let pid_file = folder.join("pid");
    // The rename writes the whole process id at once, so the read never sees a part of it.
    let command = format!(
        r#"{{"command": "echo $$ > {pid}.part && mv {pid}.part {pid} && exec sleep 3600", "background": true}}"#,
        pid = pid_file.display()
    );
    text_of(&exec["exec"], &command).await;
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
    tokio::time::timeout(WAIT, host.job_ended.notified()).await.unwrap();
    assert_eq!(host.changed.lock().unwrap().last().unwrap().state, JobState::Stopped);
    assert!(host.inputs.lock().unwrap().is_empty());
}

#[tokio::test(flavor = "local")]
async fn each_job_of_a_process_gets_a_new_id() {
    let folder = folder("each_job_of_a_process_gets_a_new_id");
    let (_runtime, _host, tools) = tools_of(&folder, &["yuke:internal/builtins"]).await;

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

#[tokio::test(flavor = "local")]
async fn processes_start_their_job_ids_at_different_numbers() {
    let folder = folder("processes_start_their_job_ids_at_different_numbers");

    let mut firsts: Vec<String> = (0..5)
        .map(|number| Processes::new(folder.join(number.to_string())).next_job_id())
        .collect();

    // Two random starts are equal once in 1,632,960 runs. Five equal starts are about 1 in 10^25.
    firsts.sort_unstable();
    firsts.dedup();
    assert!(firsts.len() > 1, "{firsts:?}");
}

#[test]
fn a_child_gets_the_home_folder_of_the_user_when_home_is_missing_or_empty() {
    let user_home = std::env::home_dir().filter(|home| home.is_absolute());

    assert_eq!(recovered_home(None), user_home);
    assert_eq!(recovered_home(Some(OsStr::new(""))), user_home);
    assert_eq!(recovered_home(Some(OsStr::new("/home/someone"))), None);
}

#[tokio::test(flavor = "local")]
async fn the_native_module_declares_the_names_that_it_exports() {
    let folder = folder("the_native_module_declares_the_names_that_it_exports");
    let (runtime, _reports) = start(&folder).await;
    let declarations = include_str!("../../types/native.d.ts");
    let mut declared: Vec<String> = declarations
        .lines()
        .filter_map(|line| {
            let line = line.trim();
            line.strip_prefix("export function ")
                .or_else(|| line.strip_prefix("export class "))
        })
        .map(|line| line.split(['(', ' ']).next().unwrap_or_default().to_owned())
        .collect();
    declared.sort_unstable();
    // Each overload declares its name again.
    declared.dedup();

    let mut exported = runtime
        .caller
        .run(async |ctx: rquickjs::Ctx<'_>, _registry| Ok(native::names(&ctx).unwrap()))
        .await
        .unwrap();
    exported.sort_unstable();

    assert_eq!(declared, exported);
}

#[tokio::test(flavor = "local")]
async fn the_host_sees_each_start_and_end_of_a_job_before_a_stop_answers() {
    let folder = folder("the_host_sees_each_start_and_end_of_a_job_before_a_stop_answers");
    let processes = Arc::new(Processes::new(folder.join("processes")));
    let host = Arc::new(TestHost::new(&folder));
    let (_runtime, exec) = runtime_with(&folder, &processes, &host).await;
    let start = |command: &'static str| {
        let exec = &exec["exec"];
        async move {
            let arguments = serde_json::json!({ "command": command, "background": true }).to_string();
            job_id(&text_of(exec, &arguments).await)
        }
    };
    let ended = start("exit 3").await;
    tokio::time::timeout(WAIT, host.job_ended.notified()).await.unwrap();
    assert_eq!(host.changed.lock().unwrap().len(), 2);
    let stopped = start("exec sleep 30").await;
    let first_closed = start("exec sleep 31").await;
    let second_closed = start("exec sleep 32").await;

    let answered = processes.jobs().stop(host.session, &stopped).await;
    let changed_at_answer = host.changed.lock().unwrap().len();
    processes.jobs().close_session(host.session).await;

    assert!(answered);
    // The host has the end of the stopped job before the stop answers.
    assert_eq!(changed_at_answer, 6);
    let job = |id: &str, command: &str, state, exit_code| yuke_protocol::Job {
        id: id.to_owned(),
        label: command.to_owned(),
        state,
        kind: yuke_protocol::JobKind::Process {
            command: command.to_owned(),
            log: folder.join("processes").join(format!("{id}.log")),
            exit_code,
        },
    };
    let changed = host.changed.lock().unwrap().clone();
    assert_eq!(
        changed[..6],
        [
            job(&ended, "exit 3", JobState::Running, None),
            job(&ended, "exit 3", JobState::Ended, Some(3)),
            job(&stopped, "exec sleep 30", JobState::Running, None),
            job(&first_closed, "exec sleep 31", JobState::Running, None),
            job(&second_closed, "exec sleep 32", JobState::Running, None),
            job(&stopped, "exec sleep 30", JobState::Stopped, None),
        ]
    );
    // The close stops both of its jobs, in any order.
    let mut closed = changed[6..].to_vec();
    closed.sort_by(|left, right| left.id.cmp(&right.id));
    let mut expected = vec![
        job(&first_closed, "exec sleep 31", JobState::Stopped, None),
        job(&second_closed, "exec sleep 32", JobState::Stopped, None),
    ];
    expected.sort_by(|left, right| left.id.cmp(&right.id));
    assert_eq!(closed, expected);
    // A stopped job sends no report.
    tokio::time::timeout(WAIT, host.input_received.notified())
        .await
        .unwrap();
    assert_eq!(host.inputs.lock().unwrap().len(), 1);
}

#[tokio::test(flavor = "local")]
async fn a_job_that_a_signal_ends_names_the_signal_in_its_report() {
    let folder = folder("a_job_that_a_signal_ends_names_the_signal_in_its_report");
    let processes = Arc::new(Processes::new(folder.join("processes")));
    let host = Arc::new(TestHost::new(&folder));
    let (_runtime, exec) = runtime_with(&folder, &processes, &host).await;

    text_of(&exec["exec"], r#"{"command": "kill -TERM $$", "background": true}"#).await;

    tokio::time::timeout(WAIT, host.input_received.notified())
        .await
        .unwrap();
    let texts: Vec<String> = host.inputs.lock().unwrap().iter().map(model_text).collect();
    assert!(texts[0].contains(" signal 15."), "{}", texts[0]);
    processes.shutdown().await.unwrap();
}

#[tokio::test(flavor = "local")]
async fn a_job_label_is_the_first_line_of_its_command_and_at_most_60_characters() {
    let folder = folder("a_job_label_is_the_first_line_of_its_command_and_at_most_60_characters");
    let processes = Arc::new(Processes::new(folder.join("processes")));
    let host = Arc::new(TestHost::new(&folder));
    let (_runtime, exec) = runtime_with(&folder, &processes, &host).await;
    let label = |command: String| {
        let exec = &exec["exec"];
        async move {
            let arguments = serde_json::json!({ "command": command, "background": true }).to_string();
            let started = text_of(exec, &arguments).await;
            let label = started.split_once(" started: ").unwrap().1;
            label.split_once(". Log: ").unwrap().0.to_owned()
        }
    };
    let comment = |length: usize| format!("exit 0 # {}", "é".repeat(length - 9));

    let fits = label(comment(60)).await;
    let long = label(comment(61)).await;
    let lines = label("  exit 0\nexit 1".to_owned()).await;

    assert_eq!(fits, comment(60));
    assert_eq!(long, format!("{}...", comment(57)));
    assert_eq!(lines, "exit 0...");
    processes.shutdown().await.unwrap();
}

/// The text of `exec` with `arguments` once `host` asks to move the command. The file `ready` in `folder` tells that the
/// command runs.
async fn moved_text(exec: &crate::ScriptTool, host: &TestHost, folder: &Path, arguments: &str) -> String {
    let answer = text_of(exec, arguments);
    let mut answer = std::pin::pin!(answer);
    let deadline = Instant::now() + WAIT;
    while !folder.join("ready").exists() {
        assert!(Instant::now() < deadline, "the command did not start");
        tokio::select! {
            biased;
            text = &mut answer => panic!("the command ended first: {text}"),
            () = tokio::time::sleep(Duration::from_millis(10)) => {}
        }
    }
    host.background.cancel();
    tokio::time::timeout(WAIT, answer).await.unwrap()
}

#[tokio::test(flavor = "local")]
async fn a_moved_command_becomes_a_job_keeps_its_whole_output_and_reports_its_end() {
    let folder = folder("a_moved_command_becomes_a_job_keeps_its_whole_output_and_reports_its_end");
    let processes = Arc::new(Processes::new(folder.join("processes")));
    let host = Arc::new(TestHost::new(&folder));
    let (_runtime, exec) = runtime_with(&folder, &processes, &host).await;

    let arguments = r#"{"command": "echo before; touch ready; sleep 0.3; echo after; exit 3"}"#;
    let text = moved_text(&exec["exec"], &host, &folder, arguments).await;

    let id = text.split(" as ").nth(1).unwrap().split('.').next().unwrap().to_owned();
    assert!(
        text.starts_with("[The user moved the command to the background as job-"),
        "{text}"
    );
    let listed = processes.jobs().running(host.session);
    assert_eq!(
        listed.iter().map(|job| job.id.as_str()).collect::<Vec<_>>(),
        [id.as_str()]
    );
    tokio::time::timeout(WAIT, host.input_received.notified())
        .await
        .unwrap();
    let texts: Vec<String> = host.inputs.lock().unwrap().iter().map(model_text).collect();
    assert!(texts[0].contains(&format!("{id} exited 3.")), "{}", texts[0]);
    assert!(texts[0].contains("before\nafter"), "{}", texts[0]);
    assert_eq!(processes.jobs().running(host.session), []);
    processes.shutdown().await.unwrap();
}

#[tokio::test(flavor = "local")]
async fn a_moved_command_outlives_its_timeout_and_a_stop_ends_it_without_a_report() {
    let folder = folder("a_moved_command_outlives_its_timeout_and_a_stop_ends_it_without_a_report");
    let processes = Arc::new(Processes::new(folder.join("processes")));
    let host = Arc::new(TestHost::new(&folder));
    let (_runtime, exec) = runtime_with(&folder, &processes, &host).await;
    let arguments = r#"{"command": "touch ready; exec sleep 30", "timeout_ms": 400}"#;
    let text = moved_text(&exec["exec"], &host, &folder, arguments).await;
    let id = text.split(" as ").nth(1).unwrap().split('.').next().unwrap().to_owned();

    tokio::time::sleep(Duration::from_millis(600)).await;
    let after_the_timeout = processes.jobs().running(host.session).len();
    let stopped = tokio::time::timeout(WAIT, processes.jobs().stop(host.session, &id))
        .await
        .unwrap();

    assert_eq!(after_the_timeout, 1);
    assert!(stopped);
    assert!(host.inputs.lock().unwrap().is_empty());
    processes.shutdown().await.unwrap();
}

#[tokio::test(flavor = "local")]
async fn a_background_request_in_a_run_without_jobs_keeps_the_command_in_the_call() {
    let folder = folder("a_background_request_in_a_run_without_jobs_keeps_the_command_in_the_call");
    let processes = Arc::new(Processes::without_jobs(folder.join("processes")));
    let host = Arc::new(TestHost::new(&folder));
    let (_runtime, exec) = runtime_with(&folder, &processes, &host).await;
    host.background.cancel();

    let text = text_of(&exec["exec"], r#"{"command": "sleep 0.1; echo done"}"#).await;

    assert_eq!(text, "done\n[exit code: 0]");
    processes.shutdown().await.unwrap();
}

#[tokio::test(flavor = "local")]
async fn a_call_dropped_during_a_move_stops_its_process() {
    let folder = folder("a_call_dropped_during_a_move_stops_its_process");
    let processes = Processes::new(folder.join("processes"));
    let host = Arc::new(TestHost::new(&folder));
    let pid_file = folder.join("pid");
    let (chunks, _texts) = tokio::sync::mpsc::unbounded_channel();
    let running = processes.run(
        Request {
            command: format!(
                "echo $$ > {pid}.part && mv {pid}.part {pid} && exec sleep 3600",
                pid = pid_file.display()
            ),
            folder: folder.clone(),
            timeout: Duration::from_secs(600),
            max_bytes: 1024,
            stop: CancellationToken::new(),
            owner: host.clone(),
        },
        chunks,
    );
    let mut running = Box::pin(running);
    let deadline = Instant::now() + WAIT;
    while !pid_file.exists() {
        assert!(Instant::now() < deadline, "the command did not start");
        tokio::select! {
            biased;
            _ = &mut running => panic!("the command ended first"),
            () = tokio::time::sleep(Duration::from_millis(10)) => {}
        }
    }
    let pid: i32 = std::fs::read_to_string(&pid_file).unwrap().trim().parse().unwrap();

    // The wait task finishes its move, and no call takes the command.
    host.background.cancel();
    tokio::time::sleep(Duration::from_millis(100)).await;
    drop(running);

    let pid = rustix::process::Pid::from_raw(pid).unwrap();
    while rustix::process::test_kill_process(pid).is_ok() {
        assert!(Instant::now() < deadline, "the command still runs");
        tokio::time::sleep(Duration::from_millis(20)).await;
    }
}

#[tokio::test(flavor = "local")]
async fn the_report_of_a_job_holds_the_end_of_a_large_output() {
    let folder = folder("the_report_of_a_job_holds_the_end_of_a_large_output");
    let processes = Arc::new(Processes::new(folder.join("processes")));
    let host = Arc::new(TestHost::new(&folder));
    let (_runtime, exec) = runtime_with(&folder, &processes, &host).await;

    text_of(&exec["exec"], r#"{"command": "seq 1 200000", "background": true}"#).await;

    tokio::time::timeout(WAIT, host.input_received.notified())
        .await
        .unwrap();
    let texts: Vec<String> = host.inputs.lock().unwrap().iter().map(model_text).collect();
    assert!(
        texts[0].ends_with("\n200000\n</system_notification>") || texts[0].ends_with("\n200000</system_notification>"),
        "{}",
        &texts[0][texts[0].len() - 60..]
    );
    processes.shutdown().await.unwrap();
}

#[tokio::test(flavor = "local")]
async fn a_dropped_command_stops_its_process() {
    let folder = folder("a_dropped_command_stops_its_process");
    let processes = Processes::new(folder.join("processes"));
    let (chunks, mut texts) = tokio::sync::mpsc::unbounded_channel();
    let running = processes.run(
        Request {
            command: "echo $$; exec sleep 30".to_owned(),
            folder: folder.clone(),
            timeout: Duration::from_secs(10),
            max_bytes: 1024,
            stop: CancellationToken::new(),
            owner: Arc::new(TestHost::new(&folder)),
        },
        chunks,
    );

    let pid: i32 = {
        tokio::pin!(running);
        let pid = tokio::select! {
            biased;
            result = &mut running => panic!("the command ended before it started: {result:?}"),
            text = tokio::time::timeout(WAIT, texts.recv()) => text.unwrap().unwrap(),
        };
        pid.trim().parse().unwrap()
    };

    assert!(super::process::gone(pid).await, "the process {pid} still runs");
}
