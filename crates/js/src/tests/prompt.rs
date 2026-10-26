//! These tests cover the `prompt.build` hook: its order, its answers, its checks, its failures, and its cancel.

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
pub(super) async fn opened(
    name: &str,
    plugins: &[(&str, &str)],
) -> (Runtime, ScriptSession, mpsc::UnboundedReceiver<Report>) {
    let (runtime, session, _host, reports) = opened_with_host(name, plugins).await;
    (runtime, session, reports)
}

/// [`opened`], with the host of the session.
pub(super) async fn opened_with_host(
    name: &str,
    plugins: &[(&str, &str)],
) -> (Runtime, ScriptSession, Arc<TestHost>, mpsc::UnboundedReceiver<Report>) {
    let folder = folder(name);
    let (runtime, reports) = start(&folder).await;
    let specs: Vec<_> = plugins
        .iter()
        .map(|(plugin_name, source)| plugin(&folder, plugin_name, Some(source), &[], &[]))
        .collect();
    assert!(runtime.load_plugins(&specs).await.is_empty());
    let host = Arc::new(TestHost::new(&folder));
    let session = runtime.handle().open_session(host.clone()).await.unwrap();
    (runtime, session, host, reports)
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

// An answer replaces the sections, and `undefined` keeps them.
#[tokio::test]
async fn the_handlers_run_in_plugin_order_then_in_addition_order_and_each_gets_the_answer_before_it() {
    let (_runtime, session, _reports) = opened(
        "the_handlers_run_in_plugin_order_then_in_addition_order_and_each_gets_the_answer_before_it",
        &[
            (
                "first",
                "export function session(s) {
                   s.hook('prompt.build', ({ sections }) => ({ sections: { ...sections, rules: 'one' } }));
                   s.hook('prompt.build', async ({ sections }) => {
                     await null;
                     return { sections: { ...sections, base: 'Be brief.', rules: `${sections.rules} two` } };
                   });
                   s.hook('prompt.build', () => undefined);
                 }",
            ),
            (
                "second",
                "export function session(s) {
                   s.hook('prompt.build', ({ sections }) => {
                     const { environment, ...rest } = sections;
                     return { sections: { ...rest, seen: sections.rules } };
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
async fn the_order_of_the_answer_is_the_order_of_the_prompt() {
    let (_runtime, session, _reports) = opened(
        "the_order_of_the_answer_is_the_order_of_the_prompt",
        &[(
            "order",
            "export function session(s) {
               s.hook('prompt.build', ({ sections }) => ({ sections: { first: 'one', ...sections } }));
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

// The answers of a build stay in that build, so each build starts from the sections of the caller.
#[tokio::test]
async fn each_build_starts_from_the_sections_of_the_caller() {
    let (_runtime, session, _reports) = opened(
        "each_build_starts_from_the_sections_of_the_caller",
        &[(
            "count",
            "let count = 0;
             export function session(s) {
               s.hook('prompt.build', ({ sections }) => {
                 count += 1;
                 return { sections: { ...sections, base: `${sections.base} ${count}` } };
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
               s.hook('prompt.build', ({ sections }) => ({ sections: { ...sections, late: 'here' } }));
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
async fn an_answer_of_another_shape_fails_the_build_and_the_error_names_the_plugin() {
    let key = "does not match /^[a-z][a-z0-9_-]*$/";
    let cases = [
        (
            "return { sections: { Rules: 'x' } };",
            format!("the section key 'Rules' {key}"),
        ),
        (
            "return { sections: { '1st': 'x' } };",
            format!("the section key '1st' {key}"),
        ),
        (
            "return { sections: { rules: 1 } };",
            "the text of the section 'rules' is not a string".to_owned(),
        ),
        (
            "return { sections: ['x'] };",
            "the sections of the answer are not an object".to_owned(),
        ),
        ("return {};", "the sections of the answer are not an object".to_owned()),
        (
            "return { section: {} };",
            "the answer has the unknown field 'section'".to_owned(),
        ),
        ("return 'done';", "the answer is not an object".to_owned()),
    ];
    for (index, (body, problem)) in cases.into_iter().enumerate() {
        let (_runtime, session, _reports) = opened(
            &format!("an_answer_of_another_shape_fails_the_build_and_the_error_names_the_plugin_{index}"),
            &[(
                "check",
                &format!("export function session(s) {{ s.hook('prompt.build', () => {{ {body} }}); }}"),
            )],
        )
        .await;

        let error = script_error(build(&session).await);

        assert_eq!(
            error.message,
            format!("prompt.build of plugin check failed: TypeError: {problem}"),
            "{body}"
        );
    }
}

// A handler that changes the event in place would skip the check of an answer. The second handler gets the sections
// of the answer before it.
#[tokio::test]
async fn a_change_of_the_event_or_its_sections_throws_and_fails_the_build() {
    let first = "s.hook('prompt.build', () => undefined);";
    let answer = "s.hook('prompt.build', ({ sections }) => ({ sections: { ...sections } }));";
    let cases = [
        (first, "event.sections.rules = 'x';"),
        (first, "event.sections = {};"),
        (answer, "event.sections.rules = 'x';"),
    ];
    for (index, (before, body)) in cases.into_iter().enumerate() {
        let (_runtime, session, _reports) = opened(
            &format!("a_change_of_the_event_or_its_sections_throws_and_fails_the_build_{index}"),
            &[(
                "editor",
                &format!("export function session(s) {{ {before} s.hook('prompt.build', (event) => {{ {body} }}); }}"),
            )],
        )
        .await;

        let error = script_error(build(&session).await);

        assert!(
            error
                .message
                .starts_with("prompt.build of plugin editor failed: TypeError: "),
            "{before} {body}: {}",
            error.message
        );
    }
}

// A getter is code of the plugin, so its throw names the plugin as a handler throw does.
#[tokio::test]
async fn a_getter_that_throws_in_the_answer_fails_the_build_and_the_error_names_the_plugin() {
    let (_runtime, session, _reports) = opened(
        "a_getter_that_throws_in_the_answer_fails_the_build_and_the_error_names_the_plugin",
        &[(
            "getter",
            "export function session(s) {
               s.hook('prompt.build', () => ({ sections: { get bad() { throw new Error('late'); } } }));
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
               s.hook('prompt.build', ({ signal }) => new Promise((resolve, reject) => {
                 const stop = () => setTimeout(() => {
                   globalThis.rejected = true;
                   reject(new Error('stopped'));
                 }, 0);
                 if (signal.aborted) stop();
                 else signal.addEventListener('abort', stop);
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
               s.hook('prompt.build', ({ signal }) => {
                 signal.addEventListener('abort', () => { globalThis.aborted = signal.reason.name; });
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
                   const count = ({ sections }) => ({ sections: { ...sections, count: `${Number(sections.count ?? 0) + 1}` } });
                   s.hook('prompt.build', count);
                   const remove = s.hook('prompt.build', count);
                   remove();
                   remove();
                 }",
            ),
            (
                "failed",
                "export async function session(s) {
                   s.hook('prompt.build', ({ sections }) => ({ sections: { ...sections, failed: 'x' } }));
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
