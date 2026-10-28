use std::path::Path;
use std::time::Duration;

use yuke_js::TestSummary;

use super::{TIME_LIMIT, collect, run};

/// The time limit of a test that must run out of time.
const SHORT_LIMIT: Duration = Duration::from_secs(1);

#[tokio::test]
async fn the_typescript_tests_of_the_app_pass() {
    let root = Path::new(env!("CARGO_MANIFEST_DIR")).join("tests");
    let files = collect(std::slice::from_ref(&root)).unwrap();
    assert!(!files.is_empty(), "no test file below {}", root.display());

    let summary = run(&files, &yuke_testing::folder("app", "typescript"), TIME_LIMIT, true).await;

    assert!(summary.failures.is_empty(), "\n{}", summary.failures);
    assert!(summary.passed > 0);
}

/// Run the test file `source` with the time limit `limit` in a new folder of the test `name`, and return the summary.
async fn ran(name: &str, source: &str, limit: Duration) -> TestSummary {
    let place = yuke_testing::folder("app-runner", name);
    let file = place.join("a.test.ts");
    std::fs::write(&file, source).unwrap();
    run(&[file], &place.join("work"), limit, true).await
}

// The check of the script reaches the runner as a fault, so a test cannot hide it.
#[tokio::test]
async fn an_unused_reply_fails_the_test_also_when_the_test_catches_the_close() {
    let summary = ran(
        "an_unused_reply_fails_the_test_also_when_the_test_catches_the_close",
        r#"import { createHost, reply, test } from "yuke:test";
           test("caught", async () => {
             const host = await createHost({ plugins: [], replies: [reply.text("never")] });
             await host.close().catch(() => undefined);
           });"#,
        TIME_LIMIT,
    )
    .await;

    assert_eq!((summary.passed, summary.failed), (0, 1));
    assert!(
        summary.failures.contains("1 scripted reply(s) got no request"),
        "{}",
        summary.failures
    );
}

#[tokio::test]
async fn a_host_that_the_test_did_not_close_checks_its_script_at_the_end_of_the_test() {
    let summary = ran(
        "a_host_that_the_test_did_not_close_checks_its_script_at_the_end_of_the_test",
        r#"import { createHost, reply, test } from "yuke:test";
           test("open", async () => {
             await createHost({ plugins: [], replies: [reply.text("never")] });
           });"#,
        TIME_LIMIT,
    )
    .await;

    assert_eq!((summary.passed, summary.failed), (0, 1));
    assert!(
        summary.failures.contains("1 scripted reply(s) got no request"),
        "{}",
        summary.failures
    );
}

#[tokio::test]
async fn a_request_after_the_last_reply_fails_the_test() {
    let summary = ran(
        "a_request_after_the_last_reply_fails_the_test",
        r#"import { createHost, test } from "yuke:test";
           test("unscripted", async () => {
             await using host = await createHost({ plugins: [], replies: [] });
             const session = await host.openSession();
             await session.send("Hi.");
           });"#,
        TIME_LIMIT,
    )
    .await;

    assert_eq!((summary.passed, summary.failed), (0, 1));
    assert!(
        summary.failures.contains("request(s) after the last scripted reply"),
        "{}",
        summary.failures
    );
}

// The loop holds the thread, so the shutdown stops the JavaScript before it closes the sessions of the host.
#[tokio::test]
async fn a_test_with_a_host_past_the_time_limit_stops_and_the_next_test_runs() {
    let summary = ran(
        "a_test_with_a_host_past_the_time_limit_stops_and_the_next_test_runs",
        r#"import { createHost, test } from "yuke:test";
           test("loops", async () => {
             const host = await createHost({ plugins: [] });
             await host.openSession();
             for (;;) {}
           });
           test("later", () => {});"#,
        SHORT_LIMIT,
    )
    .await;

    assert_eq!((summary.passed, summary.failed), (1, 1));
    assert!(summary.failures.contains("loops\n  timed out"), "{}", summary.failures);
}

#[tokio::test]
async fn a_cleanup_that_never_settles_fails_the_test_and_the_next_test_runs() {
    let summary = ran(
        "a_cleanup_that_never_settles_fails_the_test_and_the_next_test_runs",
        r#"import { createHost, test } from "yuke:test";
           test("hangs", async () => {
             await createHost({ plugins: [{ name: "stuck", apply: () => () => new Promise(() => {}) }] });
           });
           test("later", () => {});"#,
        SHORT_LIMIT,
    )
    .await;

    assert_eq!((summary.passed, summary.failed), (1, 1));
    assert!(
        summary
            .failures
            .contains("hangs\n  Error: the end of the test ran longer than 1s"),
        "{}",
        summary.failures
    );
}

// The host cancels the question, so the error fails the test before the time limit.
#[tokio::test]
async fn an_answer_that_does_not_fit_the_question_fails_the_test_at_once() {
    let summary = ran(
        "an_answer_that_does_not_fit_the_question_fails_the_test_at_once",
        r#"import { createHost, test } from "yuke:test";
           async function ask(question, answer) {
             await using host = await createHost({
               plugins: [{
                 name: "ask",
                 session: (s) => {
                   s.tools.define({
                     name: "ask",
                     description: "Ask the user.",
                     concurrency: "serial",
                     parameters: { type: "object", properties: {} },
                     execute: (_args, context) => question(s, context.signal),
                   });
                 },
               }],
               answer: typeof answer === "function" ? answer : () => answer,
             });
             const session = await host.openSession();
             await session.call("ask", {});
           }
           test("no option", () => ask((s, signal) => s.select("Which?", ["red"], { signal }), "blue"));
           test("thrown", () => ask((s, signal) => s.confirm("Go on?", undefined, { signal }), () => { throw new Error("no answer"); }));
           test("no boolean", () => ask((s, signal) => s.confirm("Go on?", undefined, { signal }), "yes"));"#,
        TIME_LIMIT,
    )
    .await;

    assert_eq!((summary.passed, summary.failed), (0, 3));
    for failure in [
        "no option\n  Error: the question offers no option \"blue\"",
        "thrown\n  Error: no answer",
        "no boolean\n  TypeError: the answer to the confirm \"Go on?\" is no boolean",
    ] {
        assert!(summary.failures.contains(failure), "{}", summary.failures);
    }
}

// The first file waits for a mark of the second file, so the files must run in parallel and the first file ends last.
#[tokio::test]
async fn the_failures_keep_the_order_of_the_files() {
    let place = yuke_testing::folder("app-runner", "the_failures_keep_the_order_of_the_files");
    let mark = place.join("mark");
    let slow = place.join("a.test.ts");
    let fast = place.join("b.test.ts");
    std::fs::write(
        &slow,
        format!(
            r#"import {{ readTextFile }} from "yuke:fs";
               import {{ test }} from "yuke:test";
               test("slow", async () => {{
                 while ((await readTextFile({mark:?}).catch(() => "")) === "") {{
                   await new Promise((resolve) => setTimeout(resolve, 10));
                 }}
                 throw new Error("first");
               }});"#
        ),
    )
    .unwrap();
    std::fs::write(
        &fast,
        format!(
            r#"import {{ writeTextFile }} from "yuke:fs";
               import {{ test }} from "yuke:test";
               test("fast", async () => {{
                 await writeTextFile({mark:?}, "done");
                 throw new Error("second");
               }});"#
        ),
    )
    .unwrap();

    let summary = run(&[slow, fast], &place.join("work"), TIME_LIMIT, true).await;

    let first = summary.failures.find("Error: first").unwrap();
    let second = summary.failures.find("Error: second").unwrap();
    assert!(first < second, "{}", summary.failures);
}

#[test]
fn an_explicit_file_without_the_test_suffix_is_an_error() {
    let place = yuke_testing::folder("app-runner", "an_explicit_file_without_the_test_suffix_is_an_error");
    let file = place.join("script.ts");
    std::fs::write(&file, "").unwrap();

    let error = collect(&[file]).unwrap_err();

    assert!(error.ends_with("script.ts: the file is not a .test.ts file"), "{error}");
}

// The error of the close comes from the host, so it has no frame to show.
#[tokio::test]
async fn an_error_of_the_host_shows_its_text_without_an_empty_stack_line() {
    let summary = ran(
        "an_error_of_the_host_shows_its_text_without_an_empty_stack_line",
        r#"import { createHost, reply, test } from "yuke:test";
           test("close", async () => {
             const host = await createHost({ plugins: [], replies: [reply.text("never")] });
             await host.close();
           });"#,
        TIME_LIMIT,
    )
    .await;

    let text = "the fake model: 1 scripted reply(s) got no request";
    assert!(
        summary
            .failures
            .ends_with(&format!("close\n  Error: {text}\n  | Error: {text}\n")),
        "{}",
        summary.failures
    );
}
