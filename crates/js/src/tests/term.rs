//! The terminal module `yuke:internal/term`: its text functions, and the frame loop on a test display.

use std::io::Write;
use std::sync::{Arc, Mutex};
use std::time::Duration;

use rquickjs::{Ctx, Module, Object, Value};
use tokio::sync::mpsc;
use yuke_term::{Button, Code, Event, Key, Modifiers, Mouse, MouseKind, Rgb, Scheme, Size};

use super::{NAMES, evaluate, folder, next_fault, options, start, wait_until};
use crate::error::caught;
use crate::{Display, Input, Processes, Report, Request, Runtime};

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

/// Run `body` in a new runtime with no display and the global `term`, as the body of an async function.
async fn run_without_display(name: &str, body: &str) -> String {
    let (runtime, _reports) = start(&folder(name)).await;
    global_term(&runtime).await;
    evaluate::<String>(&runtime, body).await.unwrap()
}

/// Start a runtime on a 20×3 display. Its handler keeps each event in `seen` and counts the frames in `frames`. The
/// call returns after the start frame.
async fn started(name: &str) -> (Runtime, mpsc::UnboundedReceiver<Report>, Arc<Display>, Output) {
    let folder = folder(name);
    let output = Output::default();
    let size = Size { columns: 20, rows: 3 };
    let display = Display::new(size, Box::new(output.clone()), None, true, false);
    let mut options = options(&folder, Arc::new(Processes::new(folder.join("processes"))));
    options.display = Some(Arc::clone(&display));
    let (runtime, reports) = Runtime::start(options).await.unwrap();
    global_term(&runtime).await;
    evaluate::<()>(
        &runtime,
        "globalThis.seen = [];
         globalThis.frames = 0;
         term.run({
           event: (event) => { seen.push(event); },
           draw: () => { frames += 1; term.text(0, 0, `frame ${frames}`); },
         });",
    )
    .await
    .unwrap();
    wait_until(&runtime, "return frames === 1;").await;
    (runtime, reports, display, output)
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
    let (runtime, _reports, _display, output) = started("the_start_frame_writes_its_cells_to_the_output").await;
    let first = evaluate::<String>(&runtime, "return JSON.stringify(seen[0]);")
        .await
        .unwrap();
    assert_eq!(first, r#"{"type":"start"}"#);
    assert!(output.text().contains("frame 1"), "{:?}", output.text());
}

#[tokio::test]
async fn a_batch_of_inputs_draws_one_frame() {
    let (runtime, _reports, display, _output) = started("a_batch_of_inputs_draws_one_frame").await;
    for character in ['a', 'b', 'c'] {
        display.send(key(character));
    }
    wait_until(&runtime, "return seen.length === 4;").await;
    let text = evaluate::<String>(
        &runtime,
        "return seen.slice(1).map((event) => `${event.type}:${event.code}:${event.char}:${event.text}:${event.mods}`)
           .concat([frames]).join(' ');",
    )
    .await
    .unwrap();
    assert_eq!(text, "key:char:a:a:0 key:char:b:b:0 key:char:c:c:0 2");
}

#[tokio::test]
async fn asks_for_frames_give_one_frame() {
    let (runtime, _reports, _display, _output) = started("asks_for_frames_give_one_frame").await;
    evaluate::<()>(&runtime, "term.requestFrame(); term.requestFrame(5);")
        .await
        .unwrap();
    wait_until(&runtime, "return frames === 2;").await;
    tokio::time::sleep(Duration::from_millis(50)).await;
    assert_eq!(evaluate::<i32>(&runtime, "return frames;").await.unwrap(), 2);
}

#[tokio::test]
async fn a_throwing_handler_reports_and_the_next_event_runs() {
    let (runtime, mut reports, display, _output) = started("a_throwing_handler_reports_and_the_next_event_runs").await;
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
    assert_eq!(evaluate::<String>(&runtime, "return seen[1].char;").await.unwrap(), "b");
}

#[tokio::test]
async fn wheel_turns_at_one_cell_give_one_event_with_a_count() {
    let (runtime, _reports, display, _output) = started("wheel_turns_at_one_cell_give_one_event_with_a_count").await;
    for input in [
        wheel(Button::WheelUp, 1),
        wheel(Button::WheelUp, 1),
        wheel(Button::WheelUp, 1),
        wheel(Button::WheelUp, 2),
        wheel(Button::WheelDown, 2),
        key('x'),
        wheel(Button::WheelDown, 2),
    ] {
        display.send(input);
    }
    wait_until(&runtime, "return seen.length === 6;").await;
    let text = evaluate::<String>(
        &runtime,
        "return seen.slice(1).map((event) => event.type === 'mouse' ? `${event.button}@${event.col}x${event.count}` : event.char)
           .join(' ');",
    )
    .await
    .unwrap();
    assert_eq!(text, "wheel_up@1x3 wheel_up@2x1 wheel_down@2x1 x wheel_down@2x1");
}

#[tokio::test]
async fn a_resize_sets_the_size_before_its_event_and_writes_every_cell() {
    let (runtime, _reports, display, output) = started("a_resize_sets_the_size_before_its_event").await;
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
async fn quit_and_suspend_reach_the_host_and_a_scheme_change_asks_for_the_background() {
    let (runtime, _reports, display, output) = started("quit_and_suspend_reach_the_host").await;
    evaluate::<()>(&runtime, "term.quit(); term.suspend();").await.unwrap();
    assert_eq!(display.request().await, Request::Quit);
    assert_eq!(display.request().await, Request::Suspend);
    output.0.lock().unwrap().clear();
    display.send(Input::Event(Event::Scheme(Scheme::Light)));
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
    let (runtime, _reports, display, _output) = started("a_background_event_comes_only_when_the_class_changes").await;
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
    let display = Display::new(
        Size { columns: 20, rows: 3 },
        Box::new(Output::default()),
        None,
        true,
        false,
    );
    let mut options = options(&folder, Arc::new(Processes::new(folder.join("processes"))));
    options.display = Some(display);
    let (runtime, _reports) = Runtime::start(options).await.unwrap();
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
    let (runtime, _reports, _display, _output) = started("term_run_runs_once").await;
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
async fn text_functions_count_utf16_units_and_cells() {
    let text = run_without_display(
        "text_functions_count_utf16_units_and_cells",
        &format!(
            "{NAMES}
             const s = 'a\\u4e2de\\u0301\\ud834\\udd1e';
             const triples = Array.from(term.graphemes(s)).join(',');
             return [
               term.measure(''), term.measure('a\\tb'), term.measure('\\u4e2d'), term.measure('\\ud834'),
               triples,
               term.fit(s, 3), term.stepGrapheme(s, 4, true), term.stepGrapheme(s, 2, false),
               Array.from(term.wrap('hello world', 5).rows).join(','),
               names([() => term.wrap(s, 2, -1), () => term.wrap(s, 2, 0, 1), () => term.wrap(s, 2, 1.5),
                 () => term.stepGrapheme(s, 7, true)]),
             ].join(' ');"
        ),
    )
    .await;
    assert_eq!(
        text,
        "0 2 2 1 0,1,1,1,1,2,2,2,1,4,2,1 2 2 4 0,6,1,6,11,0 TypeError TypeError TypeError TypeError"
    );
}

#[tokio::test]
async fn styles_take_indices_hex_colors_and_names() {
    let (runtime, _reports, _display, _output) = started("styles_take_indices_hex_colors_and_names").await;
    let names = evaluate::<String>(
        &runtime,
        &format!(
            "{NAMES}
             return names([
               () => term.text(0, 0, 'a', {{ fg: 256 }}), () => term.text(0, 0, 'a', {{ fg: '#12345' }}),
               () => term.text(0, 0, 'a', {{ fg: 'teal' }}), () => term.text(0, 0, 'a', {{ bold: 1 }}),
               () => term.text(0, 0, 'a', {{ fg: 3, bg: '#102030', ul: 'light_red', bold: true }}),
               () => term.text(0, 0, 'a', null), () => term.text(0, 0, '\\ud800'),
             ]);"
        ),
    )
    .await
    .unwrap();
    assert_eq!(names, "TypeError TypeError TypeError TypeError none none none");
}
