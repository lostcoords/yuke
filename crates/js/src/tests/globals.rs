//! The `console` global of `yuke:internal/web`: each test reads its entries from the reports of the runtime.

use tokio::sync::mpsc;
use yuke_protocol::NoticeLevel;

use super::{evaluate, folder, next_report, start};
use crate::Report;

/// The next entry of `console`. A missing entry fails the test after five seconds.
async fn next_line(reports: &mut mpsc::UnboundedReceiver<Report>) -> (NoticeLevel, String) {
    match next_report(reports).await {
        Report::Console { level, text } => (level, text),
        other => panic!("expected a console line, got {other:?}"),
    }
}

#[tokio::test]
async fn console_writes_one_formatted_entry_at_the_level_of_its_method() {
    let folder = folder("console_writes_one_formatted_entry_at_the_level_of_its_method");
    let (runtime, mut reports) = start(&folder).await;

    evaluate::<()>(
        &runtime,
        "const cycle = { name: 'loop' };
         cycle.self = cycle;
         console.log('a %s %d%% %i %f %o%c', 'b', 4.7, 2n, 1.5, [1, 'x'], 'color: red', { extra: true });
         console.info(cycle, new Map([[1, 'one']]), new Set([2]));
         console.warn(Object.defineProperty({}, 'secret', { get() { throw new Error('read'); }, enumerable: true }));
         console.error(new Error('boom'));
         console.debug({ a: { b: { c: { d: { e: 1 } } } } }, 7n, Symbol('s'), undefined, null, function named() {});",
    )
    .await
    .unwrap();

    assert_eq!(
        next_line(&mut reports).await,
        (
            NoticeLevel::Debug,
            r#"a b 4% 2 1.5 [1, "x"] { extra: true }"#.to_owned()
        )
    );
    assert_eq!(
        next_line(&mut reports).await,
        (
            NoticeLevel::Info,
            r#"{ name: "loop", self: [Circular] } Map(1) { 1 => "one" } Set(1) { 2 }"#.to_owned()
        )
    );
    assert_eq!(
        next_line(&mut reports).await,
        (NoticeLevel::Warn, "{ secret: [Getter] }".to_owned())
    );
    let (level, text) = next_line(&mut reports).await;
    assert_eq!(level, NoticeLevel::Error);
    assert!(text.starts_with("Error: boom\n"), "{text}");
    assert_eq!(
        next_line(&mut reports).await,
        (
            NoticeLevel::Debug,
            "{ a: { b: { c: { d: [Object] } } } } 7n Symbol(s) undefined null [Function named]".to_owned()
        )
    );
}

#[tokio::test]
async fn console_asserts_counts_groups_and_tables_as_the_console_standard() {
    let folder = folder("console_asserts_counts_groups_and_tables_as_the_console_standard");
    let (runtime, mut reports) = start(&folder).await;

    evaluate::<()>(
        &runtime,
        "console.assert(true, 'never');
         console.assert(false, 'x is %d', 5);
         console.assert(0, { x: 1 });
         console.count(); console.count(); console.count('jobs');
         console.countReset(); console.count(); console.countReset('none');
         console.group('outer');
         console.groupCollapsed();
         console.log('two\\nlines');
         console.groupEnd(); console.groupEnd(); console.groupEnd();
         console.dir('text');
         console.table([{ a: 1, b: 'x' }, { a: 22 }, 7]);
         console.table({ first: { a: 1, b: 2 } }, ['b']);
         console.table('plain');",
    )
    .await
    .unwrap();

    let expected = [
        (NoticeLevel::Error, "Assertion failed: x is 5"),
        (NoticeLevel::Error, "Assertion failed { x: 1 }"),
        (NoticeLevel::Info, "default: 1"),
        (NoticeLevel::Info, "default: 2"),
        (NoticeLevel::Info, "jobs: 1"),
        (NoticeLevel::Info, "default: 1"),
        (NoticeLevel::Warn, "Count for 'none' does not exist"),
        (NoticeLevel::Debug, "outer"),
        (NoticeLevel::Debug, "    two\n    lines"),
        (NoticeLevel::Debug, "\"text\""),
        (
            NoticeLevel::Debug,
            "┌─────────┬────┬─────┬────────┐\n\
             │ (index) │ a  │ b   │ Values │\n\
             ├─────────┼────┼─────┼────────┤\n\
             │ 0       │ 1  │ \"x\" │        │\n\
             │ 1       │ 22 │     │        │\n\
             │ 2       │    │     │ 7      │\n\
             └─────────┴────┴─────┴────────┘",
        ),
        (
            NoticeLevel::Debug,
            "┌─────────┬───┐\n\
             │ (index) │ b │\n\
             ├─────────┼───┤\n\
             │ first   │ 2 │\n\
             └─────────┴───┘",
        ),
        (NoticeLevel::Debug, "plain"),
    ];
    for (level, text) in expected {
        assert_eq!(next_line(&mut reports).await, (level, text.to_owned()));
    }
}

#[tokio::test]
async fn console_timers_and_traces_name_their_label_and_stack() {
    let folder = folder("console_timers_and_traces_name_their_label_and_stack");
    let (runtime, mut reports) = start(&folder).await;

    evaluate::<()>(
        &runtime,
        "console.time('load'); console.time('load');
         console.timeLog('load', 'half');
         console.timeEnd('load'); console.timeEnd('load');
         function inner() { console.trace('here %s', 'now'); }
         inner();",
    )
    .await
    .unwrap();

    assert_eq!(
        next_line(&mut reports).await,
        (NoticeLevel::Warn, "Timer 'load' already exists".to_owned())
    );
    let (level, text) = next_line(&mut reports).await;
    assert_eq!(level, NoticeLevel::Info);
    assert!(text.starts_with("load: ") && text.ends_with("ms half"), "{text}");
    let (level, text) = next_line(&mut reports).await;
    assert_eq!(level, NoticeLevel::Info);
    assert!(text.starts_with("load: ") && text.ends_with("ms"), "{text}");
    assert_eq!(
        next_line(&mut reports).await,
        (NoticeLevel::Warn, "Timer 'load' does not exist".to_owned())
    );
    let (level, text) = next_line(&mut reports).await;
    assert_eq!(level, NoticeLevel::Error);
    let mut lines = text.lines();
    assert_eq!(lines.next(), Some("Trace: here now"));
    assert!(lines.next().is_some_and(|frame| frame.contains("inner")), "{text}");
}

#[tokio::test]
async fn console_directives_convert_as_the_console_standard() {
    let folder = folder("console_directives_convert_as_the_console_standard");
    let (runtime, mut reports) = start(&folder).await;

    evaluate::<()>(
        &runtime,
        "console.log('%s %i %d %f %s', { toString: () => 'x' }, '12px', 2n, '1.5x', Symbol('s'));
         console.log('%d %f', Symbol(), Symbol());",
    )
    .await
    .unwrap();

    assert_eq!(next_line(&mut reports).await.1, "x 12 2 1.5 Symbol(s)");
    assert_eq!(next_line(&mut reports).await.1, "NaN NaN");
}

#[tokio::test]
async fn a_value_that_throws_when_console_reads_it_shows_as_unreadable() {
    let folder = folder("a_value_that_throws_when_console_reads_it_shows_as_unreadable");
    let (runtime, mut reports) = start(&folder).await;

    evaluate::<()>(
        &runtime,
        "const prototype = {};
         Object.defineProperty(prototype, 'constructor', { get() { throw new Error('read'); } });
         console.log(Object.create(prototype));
         const error = new Error('e');
         Object.defineProperty(error, 'stack', { get() { throw new Error('read'); } });
         console.error(error);
         console.warn('%s', { toString() { throw new Error('read'); } });",
    )
    .await
    .unwrap();

    assert_eq!(next_line(&mut reports).await.1, "[unreadable]");
    assert_eq!(next_line(&mut reports).await.1, "[unreadable]");
    assert_eq!(next_line(&mut reports).await.1, "[unreadable]");
}
