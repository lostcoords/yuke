//! The globals of `yuke:internal/web` besides the events: `TextEncoder`, `TextDecoder`, `console`, and `performance`.

use std::time::Duration;

use tokio::sync::mpsc;
use yuke_protocol::NoticeLevel;

use super::{NAMES, evaluate, folder, run, start};
use crate::Report;

/// The next entry of `console`. A missing entry fails the test after five seconds.
async fn next_line(reports: &mut mpsc::UnboundedReceiver<Report>) -> (NoticeLevel, String) {
    let report = tokio::time::timeout(Duration::from_secs(5), reports.recv())
        .await
        .unwrap()
        .unwrap();
    match report {
        Report::Console { level, text } => (level, text),
        other => panic!("expected a console line, got {other:?}"),
    }
}

#[tokio::test]
async fn the_globals_are_properties_that_a_script_can_replace() {
    let text = run::<String>(
        "the_globals_are_properties_that_a_script_can_replace",
        "return ['TextEncoder', 'TextDecoder', 'console', 'performance'].map((name) => {
           const { writable, enumerable, configurable } = Object.getOwnPropertyDescriptor(globalThis, name);
           return `${name}:${writable}${enumerable}${configurable}`;
         }).join(' ');",
    )
    .await;

    assert_eq!(
        text,
        "TextEncoder:truefalsetrue TextDecoder:truefalsetrue console:truefalsetrue performance:truefalsetrue"
    );
}

#[tokio::test]
async fn text_encoder_gives_utf8_and_replaces_a_lone_surrogate() {
    let text = run::<String>(
        "text_encoder_gives_utf8_and_replaces_a_lone_surrogate",
        "const encoder = new TextEncoder();
         return [encoder.encoding, Array.from(encoder.encode('é\\uD800x')).join(','), encoder.encode().length,
           Array.from(encoder.encode(null)).join(',')].join(' ');",
    )
    .await;

    assert_eq!(text, "utf-8 195,169,239,191,189,120 0 110,117,108,108");
}

#[tokio::test]
async fn encode_into_writes_whole_characters_and_counts_utf16_units() {
    let text = run::<String>(
        "encode_into_writes_whole_characters_and_counts_utf16_units",
        "const encoder = new TextEncoder();
         const small = new Uint8Array(5);
         const first = encoder.encodeInto('é😀x', small);
         const large = new Uint8Array(8);
         const second = encoder.encodeInto('é😀x', large.subarray(1));
         return [first.read, first.written, Array.from(small).join(','), second.read, second.written,
           Array.from(large).join(',')].join(' ');",
    )
    .await;

    assert_eq!(text, "1 2 195,169,0,0,0 4 7 0,195,169,240,159,152,128,120");
}

#[tokio::test]
async fn the_encoder_refuses_a_destination_that_is_no_uint8_array_and_a_value_of_another_class() {
    let text = run::<String>(
        "the_encoder_refuses_a_destination_that_is_no_uint8_array_and_a_value_of_another_class",
        &format!(
            "{NAMES}
             const encoder = new TextEncoder();
             return names([
               () => encoder.encodeInto('a', new Uint16Array(2)),
               () => encoder.encodeInto('a', Object.defineProperties(Object.create(Uint8Array.prototype),
                 {{ length: {{ value: 1 }}, set: {{ value() {{}} }} }})),
               () => encoder.encodeInto('a'),
               () => TextEncoder.prototype.encode.call({{}}, 'a'),
               () => Object.getOwnPropertyDescriptor(TextDecoder.prototype, 'encoding').get.call({{}}),
               () => encoder.encode(Symbol()),
             ]);"
        ),
    )
    .await;

    assert_eq!(text, "TypeError TypeError TypeError TypeError TypeError TypeError");
}

#[tokio::test]
async fn text_decoder_reads_views_and_buffers() {
    let text = run::<String>(
        "text_decoder_reads_views_and_buffers",
        &format!(
            "{NAMES}
             const decoder = new TextDecoder();
             const bytes = new Uint8Array([0, 104, 105, 0]);
             return [
               decoder.decode(bytes.subarray(1, 3)),
               decoder.decode(bytes.buffer.slice(1, 3)),
               decoder.decode(new DataView(bytes.buffer, 1, 2)),
               decoder.decode(new Uint16Array(new Uint8Array([0, 0, 104, 105]).buffer, 2, 1)),
               decoder.decode(new SharedArrayBuffer(0)),
               JSON.stringify(decoder.decode()),
               names([() => decoder.decode('hi'), () => decoder.decode([104])]),
             ].join(' ');"
        ),
    )
    .await;

    assert_eq!(text, "hi hi hi hi  \"\" TypeError TypeError");
}

#[tokio::test]
async fn text_decoder_replaces_an_invalid_sequence_unless_it_is_fatal() {
    let text = run::<String>(
        "text_decoder_replaces_an_invalid_sequence_unless_it_is_fatal",
        &format!(
            "{NAMES}
             const fatal = new TextDecoder('utf-8', {{ fatal: true }});
             return [
               JSON.stringify(new TextDecoder().decode(new Uint8Array([0x61, 0x80, 0xe2, 0x82]))),
               fatal.fatal,
               names([() => fatal.decode(new Uint8Array([0x61, 0x80]))]),
               fatal.decode(new Uint8Array([0x61])),
               fatal.decode(new Uint8Array([0xe2]), {{ stream: true }}).length,
               names([() => fatal.decode(new Uint8Array([0x41]))]),
               fatal.decode(new Uint8Array([0x42])),
             ].join(' ');"
        ),
    )
    .await;

    assert_eq!(text, "\"a\u{fffd}\u{fffd}\" true TypeError a 0 TypeError B");
}

#[tokio::test]
async fn a_stream_decode_keeps_a_split_character_for_the_next_call() {
    let text = run::<String>(
        "a_stream_decode_keeps_a_split_character_for_the_next_call",
        "const decoder = new TextDecoder();
         const parts = [
           decoder.decode(new Uint8Array([0x61, 0xe2, 0x82]), { stream: true }),
           decoder.decode(new Uint8Array([0xac]), { stream: true }),
           decoder.decode(new Uint8Array([0xe2])),
         ];
         return JSON.stringify(parts);",
    )
    .await;

    assert_eq!(text, "[\"a\",\"€\",\"\u{fffd}\"]");
}

#[tokio::test]
async fn a_decoder_removes_one_byte_order_mark_at_the_start_of_each_stream_unless_it_ignores_it() {
    let text = run::<String>(
        "a_decoder_removes_one_byte_order_mark_at_the_start_of_each_stream_unless_it_ignores_it",
        "const bom = [0xef, 0xbb, 0xbf];
         const decoder = new TextDecoder();
         const split = [decoder.decode(new Uint8Array([0xef]), { stream: true }),
           decoder.decode(new Uint8Array([0xbb, 0xbf, 0x61, ...bom]))];
         const again = decoder.decode(new Uint8Array([...bom, 0x62]));
         const kept = new TextDecoder('utf-8', { ignoreBOM: true }).decode(new Uint8Array([...bom, 0x63]));
         return JSON.stringify([...split, again, kept]);",
    )
    .await;

    assert_eq!(text, "[\"\",\"a\u{feff}\",\"b\",\"\u{feff}c\"]");
}

#[tokio::test]
async fn text_decoder_accepts_each_utf8_label_and_refuses_other_encodings() {
    let text = run::<String>(
        "text_decoder_accepts_each_utf8_label_and_refuses_other_encodings",
        &format!(
            "{NAMES}
             return [
               new TextDecoder(' UTF8 ').encoding,
               new TextDecoder('unicode-1-1-utf-8').encoding,
               names([() => new TextDecoder('latin1'), () => new TextDecoder('utf-16le')]),
             ].join(' ');"
        ),
    )
    .await;

    assert_eq!(text, "utf-8 utf-8 RangeError RangeError");
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
async fn performance_gives_its_origin_as_epoch_time() {
    let text = run::<String>(
        "performance_gives_its_origin_as_epoch_time",
        "const gap = Math.abs(performance.timeOrigin + performance.now() - Date.now());
         const first = performance.now();
         await new Promise((resolve) => setTimeout(resolve, 5));
         return [gap < 50, performance.now() > first,
           JSON.stringify(performance.toJSON()) === JSON.stringify({ timeOrigin: performance.timeOrigin })].join(' ');",
    )
    .await;

    assert_eq!(text, "true true true");
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

#[tokio::test]
async fn the_engine_gives_base64_and_microtasks() {
    let text = run::<String>(
        "the_engine_gives_base64_and_microtasks",
        "const order = [];
         queueMicrotask(() => order.push('microtask'));
         order.push('now');
         await new Promise((resolve) => setTimeout(resolve, 0));
         return [btoa('hi'), atob('aGk='), order.join(',')].join(' ');",
    )
    .await;

    assert_eq!(text, "aGk= hi now,microtask");
}

#[tokio::test]
async fn a_resizable_buffer_throws_and_a_detached_one_has_no_bytes() {
    let text = run::<String>(
        "a_resizable_buffer_throws_and_a_detached_one_has_no_bytes",
        &format!(
            "{NAMES}
             const decoder = new TextDecoder();
             const encoder = new TextEncoder();
             const resizable = () => new ArrayBuffer(2, {{ maxByteLength: 4 }});
             const refused = names([
               () => decoder.decode(resizable()),
               () => decoder.decode(new Uint8Array(resizable())),
               () => encoder.encodeInto('a', new Uint8Array(resizable())),
             ]);
             const buffer = new ArrayBuffer(2);
             const view = new Uint8Array(buffer);
             const data = new DataView(buffer);
             buffer.transfer();
             const written = encoder.encodeInto('a', view);
             const shared = new SharedArrayBuffer(3);
             new Uint8Array(shared).set([0, 104, 105]);
             return [refused, JSON.stringify(decoder.decode(view)), JSON.stringify(decoder.decode(buffer)),
               JSON.stringify(decoder.decode(data)),
               written.read, written.written, decoder.decode(shared).slice(1), decoder.decode(new Uint8Array(shared, 1))]
               .join(' ');"
        ),
    )
    .await;

    assert_eq!(text, "TypeError TypeError TypeError \"\" \"\" \"\" 0 0 hi hi");
}
