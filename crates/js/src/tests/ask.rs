//! These tests cover `confirm`, `select`, and `input` of the session context: the question, the answer, and its end.

use yuke_protocol::{InteractionRequest, InteractionResponse};

use super::evaluate;
use super::prompt::opened_with_host;
use super::tools::text_of;

/// The tool `ask` of the plugin `asker` runs `body` with `s` and the `signal` of the call, and gives its result as
/// JSON text.
fn asker(body: &str) -> String {
    format!(
        "export function session(s) {{
           s.tools.define({{
             name: 'ask',
             description: 'Ask the user.',
             parameters: {{ type: 'object', properties: {{}} }},
             concurrency: 'serial',
             async execute(_args, {{ signal }}) {{ return {{ text: JSON.stringify(await (async () => {{ {body} }})()) }}; }},
           }});
         }}"
    )
}

fn confirm(title: &str, message: &str) -> (String, InteractionRequest) {
    (
        "asker".to_owned(),
        InteractionRequest::Confirm {
            title: title.to_owned(),
            message: message.to_owned(),
        },
    )
}

#[tokio::test]
async fn each_question_names_its_plugin_and_gives_the_answer_of_the_user() {
    let source = asker(
        "return [
           await s.confirm('Run the migration?', 'It drops a table.', { signal }),
           await s.select('Deploy to?', ['staging', 'production'], { signal }),
           await s.input('Name?', { placeholder: 'main', secret: true, signal }),
         ];",
    );
    let (_runtime, session, host, _reports) = opened_with_host(
        "each_question_names_its_plugin_and_gives_the_answer_of_the_user",
        &[("asker", &source)],
    )
    .await;
    host.answers.lock().unwrap().extend([
        InteractionResponse::Confirm { value: true },
        InteractionResponse::Select {
            value: "production".to_owned(),
        },
        InteractionResponse::Input { value: "v2".to_owned() },
    ]);
    let tools = session.tools().await.unwrap();
    let (_, ask) = tools.iter().find(|(definition, _)| definition.name == "ask").unwrap();

    let text = text_of(ask, "{}").await;

    assert_eq!(text, r#"[true,"production","v2"]"#);
    assert_eq!(
        *host.questions.lock().unwrap(),
        [
            confirm("Run the migration?", "It drops a table."),
            (
                "asker".to_owned(),
                InteractionRequest::Select {
                    title: "Deploy to?".to_owned(),
                    options: vec!["staging".to_owned(), "production".to_owned()],
                }
            ),
            (
                "asker".to_owned(),
                InteractionRequest::Input {
                    title: "Name?".to_owned(),
                    placeholder: Some("main".to_owned()),
                    secret: true,
                }
            ),
        ]
    );
}

#[tokio::test]
async fn a_cancel_or_an_abort_answers_undefined_and_an_aborted_signal_asks_nothing() {
    let source = asker(
        "const canceled = await s.confirm('First?');
         const controller = new AbortController();
         const waiting = s.confirm('Second?', '', { signal: controller.signal });
         controller.abort();
         const aborted = await waiting;
         const late = await s.input('Third?', { signal: controller.signal });
         return [canceled, aborted, late].map((answer) => answer === undefined);",
    );
    let (_runtime, session, host, _reports) = opened_with_host(
        "a_cancel_or_an_abort_answers_undefined_and_an_aborted_signal_asks_nothing",
        &[("asker", &source)],
    )
    .await;
    host.answers.lock().unwrap().push_back(InteractionResponse::Canceled);
    let tools = session.tools().await.unwrap();
    let (_, ask) = tools.iter().find(|(definition, _)| definition.name == "ask").unwrap();

    let text = text_of(ask, "{}").await;

    assert_eq!(text, "[true,true,true]");
    assert_eq!(
        *host.questions.lock().unwrap(),
        [confirm("First?", ""), confirm("Second?", "")]
    );
}

#[tokio::test]
async fn the_close_of_the_session_ends_an_open_question() {
    let source = "export function session(s) { globalThis.kept = s.confirm('Keep the branch?'); }";
    let (runtime, session, host, _reports) =
        opened_with_host("the_close_of_the_session_ends_an_open_question", &[("asker", source)]).await;
    session.tools().await.unwrap();

    session.close().await.unwrap();
    let kept = evaluate::<bool>(&runtime, "return (await globalThis.kept) === undefined;").await;

    assert!(kept.unwrap());
    assert_eq!(*host.questions.lock().unwrap(), [confirm("Keep the branch?", "")]);
}

#[tokio::test]
async fn select_refuses_no_choice_and_a_repeated_choice() {
    let source = asker(
        "const failures = [];
         for (const choices of [[], ['a', 'a']]) {
           try { await s.select('Pick?', choices); } catch (error) { failures.push(`${error.name}: ${error.message}`); }
         }
         return failures;",
    );
    let (_runtime, session, host, _reports) =
        opened_with_host("select_refuses_no_choice_and_a_repeated_choice", &[("asker", &source)]).await;
    let tools = session.tools().await.unwrap();
    let (_, ask) = tools.iter().find(|(definition, _)| definition.name == "ask").unwrap();

    let text = text_of(ask, "{}").await;

    assert_eq!(
        text,
        r#"["TypeError: select: choices is empty","TypeError: select: choices has a choice twice"]"#
    );
    assert!(host.questions.lock().unwrap().is_empty());
}
