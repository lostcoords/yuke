//! The tools `exec` and `stop`, the background jobs, and the declarations of the native module.

use std::ffi::OsStr;
use std::path::Path;
use std::sync::Arc;
use std::time::{Duration, Instant};

use yuke_ai::Block;
use yuke_engine::CancellationToken;
use yuke_protocol::{Input, JobState};

use super::tools::{TestHost, Tools, call, call_with, error_of, text_of, tools_in, tools_of};
use super::{folder, options, start};
use crate::native;
use crate::processes::{Request, recovered_home};
use crate::{Processes, Runtime, SessionHost};

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

/// The model texts of the job ends that `host` has received, after at most five seconds of waiting for `count` of
/// them.
async fn ended_texts(host: &TestHost, count: usize) -> Vec<String> {
    let deadline = Instant::now() + Duration::from_secs(5);
    loop {
        let texts: Vec<String> = host.inputs.lock().unwrap().iter().map(model_text).collect();
        if texts.len() >= count || Instant::now() > deadline {
            return texts;
        }
        tokio::time::sleep(Duration::from_millis(20)).await;
    }
}

#[tokio::test]
async fn a_cancel_stops_the_command_and_the_tool_still_answers() {
    let folder = folder("a_cancel_stops_the_command_and_the_tool_still_answers");
    let (_runtime, _host, tools) = tools_of(&folder, &["yuke:internal/builtins"]).await;
    let token = CancellationToken::new();
    let cancel = token.clone();
    tokio::spawn(async move {
        tokio::time::sleep(Duration::from_millis(100)).await;
        cancel.cancel();
    });

    let (answer, _texts) = call_with(&tools["exec"], r#"{"command": "sleep 30"}"#, token).await;

    let content = answer.unwrap();
    assert_eq!(content.text, "[no output]\n[stopped: the tool call was cancelled.]");
    assert!(content.is_error);
}

#[tokio::test]
async fn a_dropped_exec_call_stops_its_command() {
    let folder = folder("a_dropped_exec_call_stops_its_command");
    let (_runtime, _host, tools) = tools_of(&folder, &["yuke:internal/builtins"]).await;
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
    assert_eq!(
        ended_texts(&host, 1).await,
        [format!(
            "<system_notification plugin=\"host:jobs\">{id} exited 4.\nLog: {}\nhello</system_notification>",
            log.display()
        )]
    );
    assert_eq!(
        host.inputs.lock().unwrap()[0].content(),
        [Block::user_text(format!("{id} ended"))]
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

#[tokio::test]
async fn stop_ends_a_job_and_no_end_message_follows() {
    let folder = folder("stop_ends_a_job_and_no_end_message_follows");
    let (_runtime, host, tools) = tools_of(&folder, &["yuke:internal/builtins"]).await;
    let id = job_id(&text_of(&tools["exec"], r#"{"command": "sleep 30", "background": true}"#).await);

    let text = text_of(&tools["stop"], &format!(r#"{{"id": "{id}"}}"#)).await;

    assert_eq!(
        text,
        format!(
            "[{id} stopped.] Log: {}",
            folder.join(format!("processes/{id}.log")).display()
        )
    );
    assert!(host.inputs.lock().unwrap().is_empty());
}

#[tokio::test]
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

#[tokio::test]
async fn a_background_command_takes_no_timeout() {
    let folder = folder("a_background_command_takes_no_timeout");
    let (_runtime, _host, tools) = tools_of(&folder, &["yuke:internal/builtins"]).await;

    let error = error_of(
        &tools["exec"],
        r#"{"command": "sleep 1", "background": true, "timeout_ms": 10}"#,
    )
    .await;

    assert_eq!(error, "Remove timeout_ms, or set background to false.");
}

/// A runtime with `processes` and the built-in tools, for the session of `host`.
async fn runtime_with(folder: &Path, processes: &Arc<Processes>, host: &Arc<TestHost>) -> (Runtime, Tools) {
    let started = Runtime::start(options(folder, Arc::clone(processes)));
    let (runtime, _faults) = tokio::time::timeout(WAIT, started).await.unwrap().unwrap();
    let (runtime, _host, tools) = tools_in(runtime, Arc::clone(host), &["yuke:internal/builtins"]).await;
    (runtime, tools)
}

#[tokio::test]
async fn a_job_outlives_a_reload_of_the_runtime() {
    let folder = folder("a_job_outlives_a_reload_of_the_runtime");
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

    let texts = ended_texts(&host, 1).await;
    assert_eq!(texts.len(), 1, "{texts:?}");
    assert!(
        texts[0].contains(">job-") && texts[0].contains(" exited 0."),
        "{}",
        texts[0]
    );
    assert!(texts[0].ends_with("\ndone</system_notification>"), "{}", texts[0]);
}

#[tokio::test]
async fn a_shutdown_of_the_processes_removes_their_folder() {
    let folder = folder("a_shutdown_of_the_processes_removes_their_folder");
    let processes = Arc::new(Processes::new(folder.join("processes")));
    let host = Arc::new(TestHost::new(&folder));
    let (_runtime, exec) = runtime_with(&folder, &processes, &host).await;
    text_of(&exec["exec"], r#"{"command": "sleep 30", "background": true}"#).await;
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
    let host = Arc::new(TestHost::new(&folder));
    let (_runtime, exec) = runtime_with(&folder, &processes, &host).await;
    processes.shutdown().await.unwrap();

    let error = error_of(&exec["exec"], r#"{"command": "sleep 30", "background": true}"#).await;

    assert!(error.contains("yuke is shutting down"), "{error}");
    let owner: Arc<dyn SessionHost> = host;
    assert_eq!(processes.running_jobs(&owner), []);
    assert!(!folder.join("processes").exists());
}

#[tokio::test]
async fn close_owner_stops_only_the_jobs_of_its_owner_and_refuses_its_later_jobs() {
    let folder = folder("close_owner_stops_only_the_jobs_of_its_owner_and_refuses_its_later_jobs");
    let processes = Arc::new(Processes::new(folder.join("processes")));
    let (first, second) = (Arc::new(TestHost::new(&folder)), Arc::new(TestHost::new(&folder)));
    let (_first_runtime, first_exec) = runtime_with(&folder, &processes, &first).await;
    let (_second_runtime, second_exec) = runtime_with(&folder, &processes, &second).await;
    text_of(&first_exec["exec"], r#"{"command": "sleep 30", "background": true}"#).await;
    let kept = job_id(&text_of(&second_exec["exec"], r#"{"command": "sleep 31", "background": true}"#).await);
    let (first_owner, second_owner): (Arc<dyn SessionHost>, Arc<dyn SessionHost>) = (first.clone(), second);

    tokio::time::timeout(WAIT, processes.close_owner(&first_owner))
        .await
        .unwrap();
    let late = error_of(&first_exec["exec"], r#"{"command": "sleep 32", "background": true}"#).await;

    assert!(late.contains("its session is closed"), "{late}");
    assert_eq!(processes.running_jobs(&first_owner), []);
    let running = processes.running_jobs(&second_owner);
    assert_eq!(
        running
            .iter()
            .map(|job| (job.id.as_str(), job.command.as_str()))
            .collect::<Vec<_>>(),
        [(kept.as_str(), "sleep 31")]
    );
    assert!(first.inputs.lock().unwrap().is_empty());
    processes.shutdown().await.unwrap();
}

#[tokio::test]
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
    let owner: Arc<dyn SessionHost> = host.clone();
    // The process has ended when the job leaves the running list. The delivery of its end waits at the gate.
    let deadline = Instant::now() + WAIT;
    while !processes.running_jobs(&owner).is_empty() {
        assert!(Instant::now() < deadline, "the job did not end");
        tokio::time::sleep(Duration::from_millis(20)).await;
    }

    let mut shutdown = std::pin::pin!(processes.shutdown());
    let waited = tokio::time::timeout(Duration::from_millis(100), &mut shutdown).await;
    gate.notify_one();
    tokio::time::timeout(WAIT, shutdown).await.unwrap().unwrap();

    assert!(waited.is_err(), "the shutdown did not wait for the end");
    let texts = ended_texts(&host, 1).await;
    assert_eq!(texts.len(), 1);
    assert!(texts[0].ends_with("\nhello</system_notification>"), "{}", texts[0]);
}

#[tokio::test]
async fn a_shutdown_of_the_processes_stops_each_job_without_an_end_message() {
    let folder = folder("a_shutdown_of_the_processes_stops_each_job_without_an_end_message");
    let processes = Arc::new(Processes::new(folder.join("processes")));
    let host = Arc::new(TestHost::new(&folder));
    let (_runtime, exec) = runtime_with(&folder, &processes, &host).await;
    text_of(&exec["exec"], r#"{"command": "sleep 30", "background": true}"#).await;

    tokio::time::timeout(Duration::from_secs(5), processes.shutdown())
        .await
        .unwrap()
        .unwrap();

    assert!(host.inputs.lock().unwrap().is_empty());
}

#[tokio::test]
async fn a_dropped_processes_kills_its_jobs_without_an_end_message() {
    let folder = folder("a_dropped_processes_kills_its_jobs_without_an_end_message");
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
    tokio::time::sleep(Duration::from_millis(200)).await;
    assert!(host.inputs.lock().unwrap().is_empty());
}

#[tokio::test]
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

#[tokio::test]
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

#[tokio::test]
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

#[tokio::test]
async fn the_host_sees_each_start_and_end_of_a_job_before_a_stop_answers() {
    let folder = folder("the_host_sees_each_start_and_end_of_a_job_before_a_stop_answers");
    let processes = Arc::new(Processes::new(folder.join("processes")));
    let host = Arc::new(TestHost::new(&folder));
    let (_runtime, exec) = runtime_with(&folder, &processes, &host).await;
    let owner: Arc<dyn SessionHost> = Arc::clone(&host) as Arc<dyn SessionHost>;
    let start = |command: &'static str| {
        let exec = &exec["exec"];
        async move {
            let arguments = serde_json::json!({ "command": command, "background": true }).to_string();
            job_id(&text_of(exec, &arguments).await)
        }
    };
    let ended = start("exit 3").await;
    let deadline = Instant::now() + Duration::from_secs(10);
    while host.changed.lock().unwrap().len() < 2 {
        assert!(Instant::now() < deadline, "the job did not end");
        tokio::time::sleep(Duration::from_millis(10)).await;
    }
    let stopped = start("exec sleep 30").await;
    let first_closed = start("exec sleep 31").await;
    let second_closed = start("exec sleep 32").await;

    let answered = processes.stop_job(&stopped, &owner).await;
    let changed_at_answer = host.changed.lock().unwrap().len();
    processes.close_owner(&owner).await;

    assert_eq!(answered.map(|(label, _)| label), Some("stopped".to_owned()));
    // The host has the end of the stopped job before the stop answers.
    assert_eq!(changed_at_answer, 6);
    let job = |id: &str, command: &str, state| yuke_protocol::Job {
        id: id.to_owned(),
        command: command.to_owned(),
        log: folder.join("processes").join(format!("{id}.log")),
        state,
    };
    let end = |exit_code, signal, stopped| JobState::Ended {
        exit_code,
        signal,
        stopped,
    };
    let changed = host.changed.lock().unwrap().clone();
    assert_eq!(
        changed[..6],
        [
            job(&ended, "exit 3", JobState::Running),
            job(&ended, "exit 3", end(Some(3), None, false)),
            job(&stopped, "exec sleep 30", JobState::Running),
            job(&first_closed, "exec sleep 31", JobState::Running),
            job(&second_closed, "exec sleep 32", JobState::Running),
            job(&stopped, "exec sleep 30", end(None, Some(15), true)),
        ]
    );
    // The close stops both of its jobs, in any order.
    let mut closed = changed[6..].to_vec();
    closed.sort_by(|left, right| left.id.cmp(&right.id));
    let mut expected = vec![
        job(&first_closed, "exec sleep 31", end(None, Some(15), true)),
        job(&second_closed, "exec sleep 32", end(None, Some(15), true)),
    ];
    expected.sort_by(|left, right| left.id.cmp(&right.id));
    assert_eq!(closed, expected);
    // A stopped job sends no end message.
    assert_eq!(host.inputs.lock().unwrap().len(), 1);
}

#[tokio::test]
async fn a_dropped_command_stops_its_process() {
    let folder = folder("a_dropped_command_stops_its_process");
    let processes = Processes::new(folder.join("processes"));
    let (chunks, _texts) = tokio::sync::mpsc::unbounded_channel();
    let running = processes.run(
        Request {
            command: "sleep 0.3; touch late".to_owned(),
            folder: folder.clone(),
            timeout: Duration::from_secs(10),
            max_bytes: 1024,
            stop: CancellationToken::new(),
        },
        chunks,
    );

    // The wait starts the command, and the timeout drops the wait before the command ends.
    assert!(tokio::time::timeout(Duration::from_millis(100), running).await.is_err());
    tokio::time::sleep(Duration::from_millis(800)).await;

    assert!(!folder.join("late").exists());
}
