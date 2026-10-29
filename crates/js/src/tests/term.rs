//! The terminal module `yuke:internal/term`: the frame loop on a test display.

use std::io::Write;
use std::sync::{Arc, Mutex};
use std::time::Duration;

use rquickjs::{Ctx, Module, Object, Value};
use tokio::sync::mpsc;
use yuke_protocol::{NoticeLevel, NoticeParams};
use yuke_term::{Button, Code, Event, Key, Modifiers, Mouse, MouseKind, Rgb, Size};

use super::{NAMES, evaluate, folder, next_fault, options, start, wait_until};
use crate::error::caught;
use crate::{Display, Input, Interface, Processes, Report, Request, Runtime, Startup};

/// An output that keeps what the frames write.
#[derive(Clone, Default)]
struct Output(Arc<Mutex<Vec<u8>>>);

impl Write for Output {
    fn write(&mut self, bytes: &[u8]) -> std::io::Result<usize> {
        self.0.lock().unwrap().extend_from_slice(bytes);
        Ok(bytes.len())
    }

    fn flush(&mut self) -> std::io::Result<()> {
        Ok(())
    }
}

impl Output {
    fn text(&self) -> String {
        String::from_utf8_lossy(&self.0.lock().unwrap()).into_owned()
    }
}

/// Put the `term` of `yuke:internal/term` on the global object. Only the host imports an internal module.
async fn global_term(runtime: &Runtime) {
    runtime
        .caller
        .run(async move |ctx: Ctx<'_>, _registry| {
            let promise = caught(&ctx, Module::import(&ctx, "yuke:internal/term"))?;
            let namespace = caught(&ctx, promise.into_future::<Object<'_>>().await)?;
            let term = caught(&ctx, namespace.get::<_, Value<'_>>("term"))?;
            caught(&ctx, ctx.globals().set("term", term))
        })
        .await
        .unwrap();
}

/// The interface of `display`. It starts in `/` with no session.
fn interface(display: Arc<Display>) -> Interface {
    Interface {
        display,
        startup: Startup {
            cwd: "/".to_owned(),
            session: None,
            model: None,
            reasoning: None,
        },
    }
}

/// Run `body` in a new runtime with no display and the global `term`, as the body of an async function.
async fn run_without_display(name: &str, body: &str) -> String {
    let (runtime, _reports) = start(&folder(name)).await;
    global_term(&runtime).await;
    evaluate::<String>(&runtime, body).await.unwrap()
}

/// The runtime, its reports, its display, the output of the display, and the requests of the JavaScript.
type Started = (
    Runtime,
    mpsc::UnboundedReceiver<Report>,
    Arc<Display>,
    Output,
    mpsc::UnboundedReceiver<Request>,
);

/// Start a hidden runtime on a 20×3 display, with the global `term`, and run its frame loop. The handler keeps each event
/// in `seen` and counts the frames in `frames`. Each frame shows `globalThis.cursor`.
async fn hidden(name: &str) -> Started {
    let folder = folder(name);
    let output = Output::default();
    let size = Size { columns: 20, rows: 3 };
    let (display, requests) = Display::new(size, Box::new(output.clone()), None, true, false);
    let mut options = options(&folder, Arc::new(Processes::new(folder.join("processes"))));
    options.interface = Some(interface(Arc::clone(&display)));
    let (runtime, reports) = Runtime::start(options).await.unwrap();
    global_term(&runtime).await;
    evaluate::<()>(
        &runtime,
        "globalThis.seen = [];
         globalThis.frames = 0;
         term.run({
           event: (event) => { seen.push(event); },
           draw: () => { frames += 1; term.text(0, 0, `frame ${frames}`); term.cursor(globalThis.cursor); },
         });",
    )
    .await
    .unwrap();
    (runtime, reports, display, output, requests)
}

/// [`hidden`], shown with no snapshot. The call returns after the start frame.
async fn started(name: &str) -> Started {
    let (mut runtime, reports, display, output, requests) = hidden(name).await;
    runtime.show(None);
    wait_until(&runtime, "return frames === 1;").await;
    (runtime, reports, display, output, requests)
}

fn notice(level: NoticeLevel, source: &str, message: &str) -> Input {
    Input::Notice(NoticeParams {
        session_id: None,
        level,
        source: source.to_owned(),
        message: message.to_owned(),
    })
}

fn key(character: char) -> Input {
    let mut key = Key::new(Code::Char(character));
    key.text = character.to_string();
    Input::Event(Event::Key(key))
}

fn wheel(button: Button, column: u16) -> Input {
    Input::Event(Event::Mouse(Mouse {
        column,
        row: 0,
        button,
        kind: MouseKind::Press,
        modifiers: Modifiers::NONE,
    }))
}

#[tokio::test]
async fn the_start_frame_writes_its_cells_to_the_output() {
    let (runtime, _reports, _display, output, _requests) =
        started("the_start_frame_writes_its_cells_to_the_output").await;
    let first = evaluate::<String>(&runtime, "return JSON.stringify(seen[0]);")
        .await
        .unwrap();
    assert_eq!(first, r#"{"type":"start"}"#);
    assert!(output.text().contains("frame 1"), "{:?}", output.text());
}

#[tokio::test]
async fn a_cursor_shape_reaches_the_terminal_and_an_unknown_shape_throws() {
    let (runtime, _reports, _display, output, _requests) = started("a_cursor_shape_reaches_the_terminal").await;
    output.0.lock().unwrap().clear();
    evaluate::<()>(
        &runtime,
        "globalThis.cursor = { column: 2, row: 1, shape: 'bar' }; term.requestFrame();",
    )
    .await
    .unwrap();
    wait_until(&runtime, "return frames === 2;").await;
    assert!(
        output.text().contains("\x1b[2;3H\x1b[6 q\x1b[?25h"),
        "{:?}",
        output.text()
    );
    let error = evaluate::<String>(
        &runtime,
        "try { term.cursor({ column: 0, row: 0, shape: 'beam' }); return 'no throw'; }
         catch (error) { return `${error.name}: ${error.message}`; }",
    )
    .await
    .unwrap();
    assert_eq!(error, "TypeError: a cursor shape is block, underline, or bar, not beam");
}

#[tokio::test]
async fn a_runtime_draws_and_takes_input_only_after_the_show() {
    let (mut runtime, _reports, display, output, _requests) =
        hidden("a_runtime_draws_and_takes_input_only_after_the_show").await;
    display.send(key('a'));
    tokio::time::sleep(Duration::from_millis(50)).await;
    assert_eq!(
        evaluate::<String>(&runtime, "return `${seen.length} ${frames}`;")
            .await
            .unwrap(),
        "0 0"
    );
    assert_eq!(output.text(), "");

    runtime.show(Some(r#"{"panes":2}"#.to_owned()));
    wait_until(&runtime, "return seen.length === 2 && frames === 1;").await;
    let text = evaluate::<String>(
        &runtime,
        "return `${JSON.stringify(seen[0])} ${seen[1].type}:${seen[1].character}`;",
    )
    .await
    .unwrap();
    assert_eq!(text, r#"{"type":"start","snapshot":"{\"panes\":2}"} key:a"#);
    assert!(output.text().contains("frame 1"), "{:?}", output.text());
}

#[tokio::test]
async fn a_notice_comes_as_an_event_with_its_level_source_and_text() {
    let (runtime, _reports, display, _output, _requests) =
        started("a_notice_comes_as_an_event_with_its_level_source_and_text").await;
    display.send(notice(NoticeLevel::Warn, "notes", "the index is stale"));
    wait_until(&runtime, "return seen.length === 2;").await;
    assert_eq!(
        evaluate::<String>(&runtime, "return JSON.stringify(seen[1]);")
            .await
            .unwrap(),
        r#"{"type":"notice","level":"warn","source":"notes","text":"the index is stale"}"#
    );
}

#[tokio::test]
async fn take_notices_gives_the_waiting_notices_and_drops_the_other_inputs() {
    let (display, _requests) = Display::new(
        Size { columns: 20, rows: 3 },
        Box::new(Output::default()),
        None,
        true,
        false,
    );
    display.send(key('a'));
    display.send(notice(NoticeLevel::Error, "host:yuke", "first"));
    display.send(Input::Resize(Size { columns: 30, rows: 4 }));
    display.send(notice(NoticeLevel::Debug, "console", "second"));

    let messages: Vec<String> = display
        .take_notices()
        .into_iter()
        .map(|notice| notice.message)
        .collect();
    assert_eq!(messages, ["first", "second"]);
    assert_eq!(display.take_notices(), []);
}

#[tokio::test]
async fn a_batch_of_inputs_draws_one_frame() {
    let (runtime, _reports, display, _output, _requests) = started("a_batch_of_inputs_draws_one_frame").await;
    for character in ['a', 'b', 'c'] {
        display.send(key(character));
    }
    wait_until(&runtime, "return seen.length === 4;").await;
    let text = evaluate::<String>(
        &runtime,
        "return seen.slice(1).map((event) => `${event.type}:${event.code}:${event.character}:${event.text}:${JSON.stringify(event.modifiers)}`)
           .concat([frames]).join(' ');",
    )
    .await
    .unwrap();
    let none = r#"{"shift":false,"alt":false,"ctrl":false,"super":false,"hyper":false,"meta":false}"#;
    assert_eq!(
        text,
        format!("key:character:a:a:{none} key:character:b:b:{none} key:character:c:c:{none} 2")
    );
}

#[tokio::test]
async fn asks_for_frames_give_one_frame() {
    let (runtime, _reports, _display, _output, _requests) = started("asks_for_frames_give_one_frame").await;
    evaluate::<()>(&runtime, "term.requestFrame(); term.requestFrame(5);")
        .await
        .unwrap();
    wait_until(&runtime, "return frames === 2;").await;
    tokio::time::sleep(Duration::from_millis(50)).await;
    assert_eq!(evaluate::<i32>(&runtime, "return frames;").await.unwrap(), 2);
}

#[tokio::test]
async fn the_frame_of_an_input_answers_an_ask_of_its_handler() {
    let (runtime, _reports, display, _output, _requests) = started("the_frame_of_an_input_answers_an_ask").await;
    evaluate::<()>(
        &runtime,
        "const keep = seen.push.bind(seen); seen.push = (event) => { term.requestFrame(); return keep(event); };",
    )
    .await
    .unwrap();
    display.send(key('a'));
    wait_until(&runtime, "return frames === 2;").await;
    tokio::time::sleep(Duration::from_millis(50)).await;
    assert_eq!(evaluate::<i32>(&runtime, "return frames;").await.unwrap(), 2);
}

#[tokio::test]
async fn an_ask_of_the_draw_gives_the_next_frame() {
    let (runtime, _reports, _display, _output, _requests) = started("an_ask_of_the_draw_gives_the_next_frame").await;
    evaluate::<()>(
        &runtime,
        "globalThis.drawn = 0;
         const keep = term.text;
         term.text = (...args) => { drawn += 1; if (drawn < 3) term.requestFrame(); return keep(...args); };
         term.requestFrame();",
    )
    .await
    .unwrap();
    wait_until(&runtime, "return frames === 4;").await;
}

#[tokio::test]
async fn a_focus_event_says_whether_the_window_has_the_focus() {
    let (runtime, _reports, display, _output, _requests) = started("a_focus_event_says_whether").await;
    display.send(Input::Event(Event::FocusLost));
    display.send(Input::Event(Event::FocusGained));
    wait_until(&runtime, "return seen.length === 3;").await;
    let text = evaluate::<String>(
        &runtime,
        "return seen.slice(1).map((event) => `${event.type}:${event.focused}`).join(' ');",
    )
    .await
    .unwrap();
    assert_eq!(text, "focus:false focus:true");
}

#[tokio::test]
async fn a_mouse_event_gives_column_row_button_action_and_modifiers() {
    let (runtime, _reports, display, _output, _requests) = started("a_mouse_event_gives_column_row").await;
    display.send(Input::Event(Event::Mouse(Mouse {
        column: 3,
        row: 1,
        button: Button::Left,
        kind: MouseKind::Drag,
        modifiers: Modifiers::CTRL,
    })));
    wait_until(&runtime, "return seen.length === 2;").await;
    assert_eq!(
        evaluate::<String>(&runtime, "return JSON.stringify(seen[1]);")
            .await
            .unwrap(),
        r#"{"type":"mouse","column":3,"row":1,"button":"left","action":"drag","modifiers":{"shift":false,"alt":false,"ctrl":true,"super":false,"hyper":false,"meta":false}}"#
    );
}

#[tokio::test]
async fn a_throwing_handler_reports_and_the_next_event_runs() {
    let (runtime, mut reports, display, _output, _requests) =
        started("a_throwing_handler_reports_and_the_next_event_runs").await;
    evaluate::<()>(
        &runtime,
        "const keep = seen.push.bind(seen);
         let thrown = false;
         seen.push = (event) => { if (!thrown) { thrown = true; throw new Error('a broken handler'); } return keep(event); };",
    )
    .await
    .unwrap();
    display.send(key('a'));
    let fault = next_fault(&mut reports).await;
    assert!(fault.message.contains("a broken handler"), "{fault:?}");
    display.send(key('b'));
    wait_until(&runtime, "return seen.length === 2;").await;
    assert_eq!(
        evaluate::<String>(&runtime, "return seen[1].character;").await.unwrap(),
        "b"
    );
}

#[tokio::test]
async fn each_event_of_a_batch_comes_alone_with_the_state_of_its_time() {
    let folder = folder("each_event_of_a_batch_comes_alone_with_the_state_of_its_time");
    let (display, _requests) = Display::new(
        Size { columns: 20, rows: 3 },
        Box::new(Output::default()),
        None,
        true,
        false,
    );
    let mut options = options(&folder, Arc::new(Processes::new(folder.join("processes"))));
    options.interface = Some(interface(Arc::clone(&display)));
    let (mut runtime, _reports) = Runtime::start(options).await.unwrap();
    runtime.show(None);
    global_term(&runtime).await;
    // The inputs wait for `term.run`, so they come in one batch after the start event.
    for input in [
        wheel(Button::WheelUp, 1),
        wheel(Button::WheelUp, 1),
        Input::Resize(Size { columns: 30, rows: 4 }),
        Input::Resize(Size { columns: 40, rows: 5 }),
    ] {
        display.send(input);
    }
    evaluate::<()>(
        &runtime,
        "globalThis.seen = [];
         term.run({ event: (event) => { seen.push(`${event.type}@${term.width}`); }, draw() {} });",
    )
    .await
    .unwrap();
    wait_until(&runtime, "return seen.length === 5;").await;
    let text = evaluate::<String>(&runtime, "return seen.join(' ');").await.unwrap();
    assert_eq!(text, "start@20 mouse@20 mouse@20 resize@30 resize@40");
}

#[tokio::test]
async fn a_resize_sets_the_size_before_its_event_and_writes_every_cell() {
    let (runtime, _reports, display, output, _requests) = started("a_resize_sets_the_size_before_its_event").await;
    evaluate::<()>(&runtime, "globalThis.widths = []; const keep = seen.push.bind(seen); seen.push = (event) => { widths.push(term.width); return keep(event); };")
        .await
        .unwrap();
    output.0.lock().unwrap().clear();
    display.send(Input::Resize(Size { columns: 30, rows: 4 }));
    wait_until(&runtime, "return seen.length === 2 && frames === 2;").await;
    let text = evaluate::<String>(
        &runtime,
        "return `${seen[1].w}x${seen[1].h} ${widths[0]} ${term.height}`;",
    )
    .await
    .unwrap();
    assert_eq!(text, "30x4 30 4");
    // The resize writes every cell of the new size: the frame text, and also row 4.
    let written = output.text();
    assert!(written.contains("frame 2"), "{written:?}");
    assert!(written.contains("\x1b[4;1H"), "{written:?}");
}

#[tokio::test]
async fn quit_suspend_and_reload_reach_the_host_and_a_scheme_change_asks_for_the_background() {
    let (runtime, _reports, display, output, mut requests) = started("quit_and_suspend_reach_the_host").await;
    evaluate::<()>(&runtime, "term.quit(); term.suspend(); term.reload('{\"panes\":2}');")
        .await
        .unwrap();
    assert_eq!(requests.recv().await, Some(Request::Quit));
    assert_eq!(requests.recv().await, Some(Request::Suspend));
    assert_eq!(
        requests.recv().await,
        Some(Request::Reload(r#"{"panes":2}"#.to_owned()))
    );
    output.0.lock().unwrap().clear();
    display.send(Input::Event(Event::SchemeChanged));
    // The scheme change gives the handler no event, so the key is the next event.
    display.send(key('x'));
    wait_until(&runtime, "return seen.length === 2;").await;
    assert!(output.text().starts_with("\x1b]11;?\x1b\\"), "{:?}", output.text());
    assert_eq!(
        evaluate::<String>(&runtime, "return seen[1].type;").await.unwrap(),
        "key"
    );
}

#[tokio::test]
async fn a_background_event_comes_only_when_the_class_changes() {
    let (runtime, _reports, display, _output, _requests) =
        started("a_background_event_comes_only_when_the_class_changes").await;
    let black = Rgb {
        red: 0,
        green: 0,
        blue: 0,
    };
    let white = Rgb {
        red: 255,
        green: 255,
        blue: 255,
    };
    for color in [black, white, white] {
        display.send(Input::Event(Event::Background(color)));
    }
    display.send(key('x'));
    wait_until(&runtime, "return seen.length === 3;").await;
    let text = evaluate::<String>(
        &runtime,
        "return `${seen[1].background} ${term.background} ${seen[2].type}`;",
    )
    .await
    .unwrap();
    assert_eq!(text, "light light key");
}

#[tokio::test]
async fn a_frame_asked_before_the_run_waits_for_it() {
    let folder = folder("a_frame_asked_before_the_run_waits_for_it");
    let (display, _requests) = Display::new(
        Size { columns: 20, rows: 3 },
        Box::new(Output::default()),
        None,
        true,
        false,
    );
    let mut options = options(&folder, Arc::new(Processes::new(folder.join("processes"))));
    options.interface = Some(interface(display));
    let (mut runtime, _reports) = Runtime::start(options).await.unwrap();
    runtime.show(None);
    global_term(&runtime).await;
    evaluate::<()>(&runtime, "term.requestFrame();").await.unwrap();
    tokio::time::sleep(Duration::from_millis(20)).await;
    evaluate::<()>(
        &runtime,
        "globalThis.frames = 0; term.run({ event() {}, draw() { frames += 1; } });",
    )
    .await
    .unwrap();
    wait_until(&runtime, "return frames === 1;").await;
}

#[tokio::test]
async fn term_run_runs_once_and_draws_need_a_display() {
    let (runtime, _reports, _display, _output, _requests) = started("term_run_runs_once").await;
    let second = evaluate::<String>(
        &runtime,
        &format!("{NAMES} return names([() => term.run({{ event() {{}}, draw() {{}} }})]);"),
    )
    .await
    .unwrap();
    assert_eq!(second, "TypeError");

    let without = run_without_display(
        "draws_need_a_display",
        &format!(
            "{NAMES}
             return [names([() => term.text(0, 0, 'a'), () => term.run({{ event() {{}}, draw() {{}} }}), () => term.width]),
               term.measure('ab')].join(' ');"
        ),
    )
    .await;
    assert_eq!(without, "Error Error Error 2");
}

#[tokio::test]
async fn styles_take_indices_hex_colors_and_reset() {
    let (runtime, _reports, _display, _output, _requests) = started("styles_take_indices_hex_colors_and_reset").await;
    let names = evaluate::<String>(
        &runtime,
        &format!(
            "{NAMES}
             return names([
               () => term.text(0, 0, 'a', {{ fg: 256 }}), () => term.text(0, 0, 'a', {{ fg: '#12345' }}),
               () => term.text(0, 0, 'a', {{ fg: '#12+456' }}), () => term.text(0, 0, 'a', {{ fg: 'red' }}),
               () => term.text(0, 0, 'a', {{ bold: 1 }}),
               () => term.text(0, 0, 'a', {{ fg: 3, bg: '#102030', ul: 9, bold: true }}),
               () => term.text(0, 0, 'a', {{ bg: 'reset' }}), () => term.text(0, 0, 'a', null),
               () => term.text(0, 0, '\\ud800'),
             ]);"
        ),
    )
    .await
    .unwrap();
    assert_eq!(
        names,
        "TypeError TypeError TypeError TypeError TypeError none none none none"
    );
}
