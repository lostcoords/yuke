//! The public module `yuke:process`: arguments without a shell, the streams, the environment, the misuse, the stops,
//! and the end of the runtime.

use std::path::Path;
use std::time::{Duration, Instant};

use super::{evaluate, folder, start};

/// `path` as a JavaScript string literal.
fn js_string(path: &Path) -> String {
    format!(
        "'{}'",
        path.to_str().unwrap().replace('\\', "\\\\").replace('\'', "\\'")
    )
}

/// Run `body` in a new runtime with `Command`, `base` (the folder of the test), and `text` (bytes to UTF-8), and give
/// the value of its promise.
async fn run_process(name: &str, body: &str) -> (String, std::path::PathBuf) {
    let folder = folder(name);
    let (runtime, mut reports) = start(&folder).await;
    let base = js_string(&folder);
    let body = format!(
        "const {{ Command }} = await import('yuke:process');\nconst base = {base};\n\
         const text = (bytes) => new TextDecoder().decode(bytes);\n{body}"
    );
    let value = tokio::time::timeout(Duration::from_secs(10), evaluate::<String>(&runtime, &body))
        .await
        .unwrap()
        .unwrap();
    if let Ok(report) = reports.try_recv() {
        panic!("unexpected report: {report:?}");
    }
    (value, folder)
}

/// Whether the process `pid` is gone, after at most five seconds of waiting.
async fn gone(pid: i32) -> bool {
    let pid = rustix::process::Pid::from_raw(pid).unwrap();
    let deadline = Instant::now() + Duration::from_secs(5);
    while rustix::process::test_kill_process(pid) != Err(rustix::io::Errno::SRCH) {
        if Instant::now() > deadline {
            return false;
        }
        tokio::time::sleep(Duration::from_millis(20)).await;
    }
    true
}

#[tokio::test]
async fn each_argument_reaches_the_program_as_it_is_and_the_streams_stay_apart() {
    let (value, _) = run_process(
        "each_argument_reaches_the_program_as_it_is",
        r#"const out = await new Command("sh", {
             args: ["-c", 'printf "%s|" "$1" "$2"; echo err >&2; exit 3', "sh", "a b", "$HOME"],
             cwd: base,
           }).output();
           return JSON.stringify([text(out.stdout), text(out.stderr), out.code, out.success, out.signal]);"#,
    )
    .await;

    assert_eq!(value, r#"["a b|$HOME|","err\n",3,false,null]"#);
}

#[tokio::test]
async fn env_adds_variables_clear_env_leaves_only_env_and_a_null_stream_is_empty() {
    let (value, _) = run_process(
        "env_adds_variables_clear_env_leaves_only_env",
        r#"const added = await new Command("/usr/bin/env", { cwd: base, env: { YUKE_A: "1" } }).output();
           const only = await new Command("/usr/bin/env", { cwd: base, env: { YUKE_A: "1" }, clearEnv: true }).output();
           const dropped = await new Command("/usr/bin/env", { cwd: base, stdout: "null" }).output();
           const lines = text(added.stdout).split("\n");
           return JSON.stringify([lines.includes("YUKE_A=1"), lines.some((line) => line.startsWith("PATH=")),
             text(only.stdout), dropped.stdout.length, dropped.success]);"#,
    )
    .await;

    assert_eq!(value, r#"[true,true,"YUKE_A=1\n",0,true]"#);
}

#[tokio::test]
async fn a_misuse_throws_a_type_error_before_any_start() {
    let (value, _) = run_process(
        "a_misuse_throws_a_type_error_before_any_start",
        r#"const failures = [];
           const cases = [
             () => new Command("ls"),
             () => new Command("ls", { cwd: "relative" }),
             () => new Command("ls", { cwd: base, stdout: "inherit" }),
             () => new Command("ls", { cwd: base, stdin: "piped" }),
             () => new Command("ls", { cwd: base, shell: true }),
             () => new Command("ls", { cwd: base, args: [1] }),
             () => new Command("ls", { cwd: base, env: { A: 1 } }),
           ];
           for (const make of cases) {
             try { make(); failures.push("no throw"); } catch (error) { failures.push(`${error.name}: ${error.message}`); }
           }
           return JSON.stringify(failures);"#,
    )
    .await;

    assert_eq!(
        value,
        "[\"TypeError: the options is not an object\",\
          \"TypeError: the option cwd is not an absolute path\",\
          \"TypeError: the option stdout is not \\\"piped\\\" or \\\"null\\\"\",\
          \"TypeError: the option stdin is not \\\"null\\\"\",\
          \"TypeError: the options has the unknown field 'shell'\",\
          \"TypeError: the option args is not an array of strings\",\
          \"TypeError: the option env has a value that is not a string\"]"
    );
}

#[tokio::test]
async fn an_abort_before_the_start_rejects_and_an_abort_during_the_run_stops_the_group() {
    let (value, folder) = run_process(
        "an_abort_before_the_start_rejects",
        r#"const early = new AbortController();
           early.abort(new Error("too early"));
           let rejected;
           try { await new Command("sh", { cwd: base, signal: early.signal }).output(); }
           catch (error) { rejected = error.message; }
           const late = new AbortController();
           // The background child writes its id, so the test sees that the stop reached the whole group.
           const running = new Command("sh", { args: ["-c", "sleep 30 & echo $! > child; wait"], cwd: base,
             signal: late.signal }).output();
           setTimeout(() => late.abort(), 300);
           const out = await running;
           return JSON.stringify([rejected, out.success, out.code, out.signal]);"#,
    )
    .await;
    let child: i32 = std::fs::read_to_string(folder.join("child"))
        .unwrap()
        .trim()
        .parse()
        .unwrap();

    assert_eq!(value, r#"["too early",false,143,"SIGTERM"]"#);
    assert!(gone(child).await, "the child of the program still runs");
}

#[tokio::test]
async fn an_abort_after_the_exit_stops_a_left_process_that_holds_the_output() {
    let (value, folder) = run_process(
        "an_abort_after_the_exit_stops_a_left_process",
        r#"const controller = new AbortController();
           // The shell exits at once, and its background child keeps stdout open.
           const running = new Command("sh", { args: ["-c", "sleep 30 & echo $! > child; echo done"], cwd: base,
             signal: controller.signal }).output();
           setTimeout(() => controller.abort(), 300);
           const out = await running;
           return JSON.stringify([text(out.stdout), out.code, out.signal]);"#,
    )
    .await;
    let child: i32 = std::fs::read_to_string(folder.join("child"))
        .unwrap()
        .trim()
        .parse()
        .unwrap();

    assert_eq!(value, r#"["done\n",0,null]"#);
    assert!(gone(child).await, "the left process still runs");
}

#[tokio::test]
async fn a_program_that_does_not_start_rejects_with_its_name() {
    let (value, _) = run_process(
        "a_program_that_does_not_start_rejects_with_its_name",
        r#"try { await new Command("/no/such/program", { cwd: base }).output(); return "ran"; }
           catch (error) { return `${error.name}: ${error.message}`; }"#,
    )
    .await;

    assert_eq!(
        value,
        "Error: /no/such/program did not start: No such file or directory (os error 2)"
    );
}

#[tokio::test]
async fn the_end_of_the_runtime_stops_a_running_program() {
    let folder = folder("the_end_of_the_runtime_stops_a_running_program");
    let (runtime, _reports) = start(&folder).await;
    let body = format!(
        "const {{ Command }} = await import('yuke:process');\n\
         globalThis.running = new Command('sh', {{ args: ['-c', 'echo $$ > pid; exec sleep 30'], cwd: {} }}).output();\n\
         return 'started';",
        js_string(&folder)
    );
    evaluate::<String>(&runtime, &body).await.unwrap();
    let file = folder.join("pid");
    let deadline = Instant::now() + Duration::from_secs(5);
    while std::fs::read_to_string(&file).map_or(true, |text| text.trim().is_empty()) {
        assert!(Instant::now() < deadline, "the program did not start");
        tokio::time::sleep(Duration::from_millis(20)).await;
    }
    let pid: i32 = std::fs::read_to_string(&file).unwrap().trim().parse().unwrap();

    tokio::time::timeout(Duration::from_secs(10), runtime.shutdown())
        .await
        .unwrap()
        .unwrap();

    assert!(gone(pid).await, "the program still runs");
}
