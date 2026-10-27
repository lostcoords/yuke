//! The public module `yuke:process`: the end of the runtime. crates/js/tests/process holds the other tests.

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
