//! These tests cover the `prompt.build` hook: its order, its edits, its checks, its failures, and its cancel.

use std::path::Path;
use std::sync::Arc;
use std::time::Duration;

use tokio::sync::mpsc;
use yuke_agent::PromptSection;
use yuke_engine::CancellationToken;

use super::plugins::plugin;
use super::tools::TestHost;
use super::{evaluate, folder, script_error, start};
use crate::{Error, Report, Runtime, ScriptSession};

/// The sections of a new session before any hook.
fn saved() -> Vec<PromptSection> {
    vec![
        PromptSection::new("base", "You are yuke."),
        PromptSection::new("environment", "workspace: /work"),
    ]
}

/// A runtime in a new folder `name` with one plugin per `(name, entry)`, in that order, an open session, and the
/// reports of the runtime.
async fn opened(name: &str, plugins: &[(&str, &str)]) -> (Runtime, ScriptSession, mpsc::UnboundedReceiver<Report>) {
    let folder = folder(name);
    let (runtime, reports) = start(&folder).await;
    let specs: Vec<_> = plugins
        .iter()
        .map(|(plugin_name, source)| plugin(&folder, plugin_name, Some(source), &[], &[]))
        .collect();
    assert!(runtime.load_plugins(&specs).await.is_empty());
    let session = runtime.open_session(host(&folder)).await.unwrap();
    (runtime, session, reports)
}

fn host(folder: &Path) -> Arc<TestHost> {
    Arc::new(TestHost::new(folder))
}

/// The sections that the hooks of `session` build from [`saved`], as `(key, text)` pairs.
async fn build(session: &ScriptSession) -> Result<Vec<(String, String)>, Error> {
    let built = tokio::time::timeout(
        Duration::from_secs(5),
        session.build_prompt(&saved(), &CancellationToken::new()),
    )
    .await
    .unwrap()?;
    Ok(built.into_iter().map(|section| (section.key, section.text)).collect())
}

fn pairs(sections: &[(&str, &str)]) -> Vec<(String, String)> {
    sections
        .iter()
        .map(|(key, text)| ((*key).to_owned(), (*text).to_owned()))
        .collect()
}

#[tokio::test]
async fn a_session_without_a_hook_keeps_its_sections() {
    let (_runtime, session, _reports) = opened(
        "a_session_without_a_hook_keeps_its_sections",
        &[("plain", "export function session(s) {}")],
    )
    .await;

    assert_eq!(
        build(&session).await.unwrap(),
        pairs(&[("base", "You are yuke."), ("environment", "workspace: /work")])
    );
}

// A set replaces a text in its place or adds a section at the end, and a delete removes a section.
#[tokio::test]
async fn the_handlers_run_in_plugin_order_then_in_addition_order_and_each_sees_the_edits_before_it() {
    let (_runtime, session, _reports) = opened(
        "the_handlers_run_in_plugin_order_then_in_addition_order_and_each_sees_the_edits_before_it",
        &[
            (
                "first",
                "export function session(s) {
                   s.hook('prompt.build', (build) => { build.sections.rules = 'one'; });
                   s.hook('prompt.build', async (build) => {
                     await null;
                     build.sections.base = 'Be brief.';
                     build.sections.rules += ' two';
                   });
                 }",
            ),
            (
                "second",
                "export function session(s) {
                   s.hook('prompt.build', (build) => {
                     delete build.sections.environment;
                     build.sections.seen = build.sections.rules;
                   });
                 }",
            ),
        ],
    )
    .await;

    assert_eq!(
        build(&session).await.unwrap(),
        pairs(&[("base", "Be brief."), ("rules", "one two"), ("seen", "one two")])
    );
}

#[tokio::test]
async fn a_new_object_sets_a_new_order() {
    let (_runtime, session, _reports) = opened(
        "a_new_object_sets_a_new_order",
        &[(
            "order",
            "export function session(s) {
               s.hook('prompt.build', (build) => {
                 build.sections = { first: 'one', ...build.sections };
               });
             }",
        )],
    )
    .await;

    assert_eq!(
        build(&session).await.unwrap(),
        pairs(&[
            ("first", "one"),
            ("base", "You are yuke."),
            ("environment", "workspace: /work")
        ])
    );
}

// The edits of a build stay in that build, so each build starts from the sections of the caller.
#[tokio::test]
async fn each_build_starts_from_the_sections_of_the_caller() {
    let (_runtime, session, _reports) = opened(
        "each_build_starts_from_the_sections_of_the_caller",
        &[(
            "count",
            "let count = 0;
             export function session(s) {
               s.hook('prompt.build', (build) => {
                 count += 1;
                 build.sections.base += ` ${count}`;
               });
             }",
        )],
    )
    .await;

    build(&session).await.unwrap();
    let second = build(&session).await.unwrap();

    assert_eq!(second[0], ("base".to_owned(), "You are yuke. 2".to_owned()));
}

#[tokio::test]
async fn the_first_build_waits_for_the_setup_of_the_session() {
    let (_runtime, session, _reports) = opened(
        "the_first_build_waits_for_the_setup_of_the_session",
        &[(
            "late",
            "export async function session(s) {
               await new Promise((resolve) => setTimeout(resolve, 20));
               s.hook('prompt.build', (build) => { build.sections.late = 'here'; });
             }",
        )],
    )
    .await;

    let built = build(&session).await.unwrap();

    assert_eq!(built.last().unwrap(), &("late".to_owned(), "here".to_owned()));
}

#[tokio::test]
async fn a_handler_that_throws_fails_the_build_and_the_error_names_the_plugin() {
    let (_runtime, session, _reports) = opened(
        "a_handler_that_throws_fails_the_build_and_the_error_names_the_plugin",
        &[(
            "broken",
            "export function session(s) {
               s.hook('prompt.build', () => { throw new RangeError('no prompt today'); });
             }",
        )],
    )
    .await;

    let error = script_error(build(&session).await);

    assert_eq!(error.name.as_deref(), Some("Error"));
    assert_eq!(
        error.message,
        "prompt.build of plugin broken failed: RangeError: no prompt today"
    );
    // The stack is the stack of the handler, which names the module of the plugin.
    assert!(error.stack.unwrap().contains("broken"));
}

#[tokio::test]
async fn a_handler_that_leaves_an_invalid_section_or_returns_a_value_fails_the_build() {
    let cases = [
        (
            "build.sections.Rules = 'x';",
            "prompt.build of plugin check left the key 'Rules', which does not match /^[a-z][a-z0-9_-]*$/",
        ),
        (
            "build.sections['1st'] = 'x';",
            "prompt.build of plugin check left the key '1st', which does not match /^[a-z][a-z0-9_-]*$/",
        ),
        (
            "build.sections.rules = 1;",
            "prompt.build of plugin check left the section 'rules' with a text that is not a string",
        ),
        (
            "build.sections = ['x'];",
            "prompt.build of plugin check set build.sections to a value that is not an object",
        ),
        (
            "return 'done';",
            "prompt.build of plugin check returned a value: a handler returns nothing",
        ),
    ];
    for (index, (body, expected)) in cases.into_iter().enumerate() {
        let (_runtime, session, _reports) = opened(
            &format!("a_handler_that_leaves_an_invalid_section_or_returns_a_value_fails_the_build_{index}"),
            &[(
                "check",
                &format!("export function session(s) {{ s.hook('prompt.build', (build) => {{ {body} }}); }}"),
            )],
        )
        .await;

        let error = script_error(build(&session).await);

        assert_eq!(error.name.as_deref(), Some("TypeError"), "{body}");
        assert_eq!(error.message, expected, "{body}");
    }
}

// A getter is code of the plugin, so its throw names the plugin as a handler throw does.
#[tokio::test]
async fn a_getter_that_throws_in_the_sections_fails_the_build_and_the_error_names_the_plugin() {
    let (_runtime, session, _reports) = opened(
        "a_getter_that_throws_in_the_sections_fails_the_build_and_the_error_names_the_plugin",
        &[(
            "getter",
            "export function session(s) {
               s.hook('prompt.build', (build) => { build.sections = { get bad() { throw new Error('late'); } }; });
             }",
        )],
    )
    .await;

    let error = script_error(build(&session).await);

    assert_eq!(error.message, "prompt.build of plugin getter failed: Error: late");
}

// The host stops its wait at a cancel, so a handler that rejects later sends no fault.
#[tokio::test]
async fn a_build_that_fails_after_a_cancel_sends_no_fault() {
    let (runtime, session, mut reports) = opened(
        "a_build_that_fails_after_a_cancel_sends_no_fault",
        &[(
            "late",
            "export function session(s) {
               s.hook('prompt.build', (build) => new Promise((resolve, reject) => {
                 const stop = () => setTimeout(() => {
                   globalThis.rejected = true;
                   reject(new Error('stopped'));
                 }, 0);
                 if (build.signal.aborted) stop();
                 else build.signal.addEventListener('abort', stop);
               }));
             }",
        )],
    )
    .await;
    let token = CancellationToken::new();
    token.cancel();

    let built = session.build_prompt(&saved(), &token).await.unwrap();
    let rejected = evaluate::<bool>(
        &runtime,
        "await new Promise((resolve) => setTimeout(resolve, 20)); return globalThis.rejected === true;",
    )
    .await
    .unwrap();

    assert_eq!(built, saved());
    assert!(rejected);
    assert!(reports.try_recv().is_err(), "a report came");
}

#[tokio::test]
async fn a_cancel_aborts_the_signal_and_returns_the_sections_of_the_caller_at_once() {
    let (runtime, session, _reports) = opened(
        "a_cancel_aborts_the_signal_and_returns_the_sections_of_the_caller_at_once",
        &[(
            "slow",
            "export function session(s) {
               s.hook('prompt.build', (build) => {
                 build.sections.base = 'changed';
                 build.signal.addEventListener('abort', () => { globalThis.aborted = build.signal.reason.name; });
                 return new Promise(() => {});
               });
             }",
        )],
    )
    .await;
    let token = CancellationToken::new();
    let sections = saved();

    let built = tokio::join!(session.build_prompt(&sections, &token), async {
        tokio::time::sleep(Duration::from_millis(20)).await;
        token.cancel();
    })
    .0
    .unwrap();

    assert_eq!(built, saved());
    let aborted = evaluate::<String>(&runtime, "return globalThis.aborted;")
        .await
        .unwrap();
    assert_eq!(aborted, "AbortError");
}

// A handler can be in a list twice, so a remover removes one entry, and a second call of it removes nothing.
#[tokio::test]
async fn a_remover_removes_one_entry_once_and_the_handler_of_a_failed_session_does_not_run() {
    let (_runtime, session, _reports) = opened(
        "a_remover_removes_one_entry_once_and_the_handler_of_a_failed_session_does_not_run",
        &[
            (
                "removed",
                "export function session(s) {
                   const count = (build) => { build.sections.count = `${Number(build.sections.count ?? 0) + 1}`; };
                   s.hook('prompt.build', count);
                   const remove = s.hook('prompt.build', count);
                   remove();
                   remove();
                 }",
            ),
            (
                "failed",
                "export async function session(s) {
                   s.hook('prompt.build', (build) => { build.sections.failed = 'x'; });
                   await null;
                   throw new Error('broken');
                 }",
            ),
        ],
    )
    .await;

    assert_eq!(
        build(&session).await.unwrap(),
        pairs(&[
            ("base", "You are yuke."),
            ("environment", "workspace: /work"),
            ("count", "1")
        ])
    );
}

#[tokio::test]
async fn hook_refuses_an_unknown_point_a_handler_that_is_no_function_and_a_closed_session() {
    let (runtime, session, _reports) = opened(
        "hook_refuses_an_unknown_point_a_handler_that_is_no_function_and_a_closed_session",
        &[(
            "refused",
            "export function session(s) {
               globalThis.s = s;
               const refusal = (add) => { try { add(); return 'added'; } catch (error) { return error.message; } };
               globalThis.refusals = [
                 refusal(() => s.hook('turn.start', () => {})),
                 refusal(() => s.hook('prompt.build', 'x')),
               ];
             }",
        )],
    )
    .await;
    build(&session).await.unwrap();
    session.close().await.unwrap();

    let refusals = evaluate::<Vec<String>>(
        &runtime,
        "try { globalThis.s.hook('prompt.build', () => {}); }
         catch (error) { return [...globalThis.refusals, error.message]; }",
    )
    .await
    .unwrap();

    assert_eq!(
        refusals,
        [
            "hook: 'turn.start' is no hook point",
            "hook: the handler is no function",
            "plugin refused adds a hook after the end of its session",
        ]
    );
}
