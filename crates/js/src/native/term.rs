//! The terminal functions of the native module and the frame loop of the terminal interface. The text functions work
//! in the UTF-16 units of JavaScript strings, with the width rule of the grid. The drawing functions need the
//! [`Display`] of the runtime and throw without one.

use std::cell::{Cell, RefCell};
use std::rc::Rc;
use std::sync::Arc;
use std::time::Duration;

use crate::tools::Json;
use rquickjs::function::Opt;
use rquickjs::{Ctx, Function, Object, Persistent, TypedArray, Value};
use tokio::sync::{Notify, mpsc, oneshot};
use tokio::time::Instant;
use yuke_term::{
    Attributes, BACKGROUND_QUERY, Button, Code, Color, Event, Modifiers, MouseKind, Rgb, Style, graphemes,
};

use crate::display::{Display, Frame, Input, Request, Scheme, scheme_of};
use crate::error::{Error, ErrorClass, Report, caught, throw};

/// The shortest time between two asked frames: at most 120 frames each second, as in Codex. A frame after input does
/// not wait.
const FRAME_INTERVAL: Duration = Duration::from_micros(8_334);

/// The frame loop state of one runtime.
#[derive(Debug)]
pub(crate) struct Frames {
    display: Option<Arc<Display>>,
    handler: RefCell<Option<Handler>>,
    /// The time of the earliest asked frame.
    deadline: Cell<Option<Instant>>,
    last: Cell<Option<Instant>>,
    /// A run or an ask for a frame wakes the loop.
    changed: Notify,
}

/// The functions of `term.run`.
#[derive(Debug)]
struct Handler {
    event: Persistent<Function<'static>>,
    draw: Persistent<Function<'static>>,
}

impl Frames {
    pub(crate) fn new(display: Option<Arc<Display>>) -> Self {
        Self {
            display,
            handler: RefCell::new(None),
            deadline: Cell::new(None),
            last: Cell::new(None),
            changed: Notify::new(),
        }
    }

    /// Drop the saved functions before the runtime ends. A saved value that outlives the runtime aborts the process.
    pub(crate) fn clear(&self) {
        self.handler.take();
    }

    fn display(&self, ctx: &Ctx<'_>) -> rquickjs::Result<&Arc<Display>> {
        self.display
            .as_ref()
            .ok_or_else(|| throw(ctx, ErrorClass::Error, "the runtime has no terminal display"))
    }

    /// The time of the next asked frame, no earlier than one interval after the last frame.
    fn due(&self) -> Option<Instant> {
        let deadline = self.deadline.get()?;
        Some(
            self.last
                .get()
                .map_or(deadline, |last| deadline.max(last + FRAME_INTERVAL)),
        )
    }
}

/// Add the terminal functions to `object`, the export object of the native module.
pub(super) fn add<'js>(ctx: &Ctx<'js>, object: &Object<'js>, frames: &Rc<Frames>) -> rquickjs::Result<()> {
    add_drawing(ctx, object, frames)?;
    add_loop(ctx, object, frames)?;
    add_text(ctx, object)
}

/// Add the functions that draw on the grid. Each needs the display.
fn add_drawing<'js>(ctx: &Ctx<'js>, object: &Object<'js>, frames: &Rc<Frames>) -> rquickjs::Result<()> {
    let set = |name: &str, function: Function<'js>| object.set(name, function);

    let held = Rc::clone(frames);
    set(
        "termFill",
        Function::new(
            ctx.clone(),
            move |ctx: Ctx<'js>,
                  x: f64,
                  y: f64,
                  width: f64,
                  height: f64,
                  style: Opt<Value<'js>>|
                  -> rquickjs::Result<_> {
                let style = style_of(&ctx, style.0)?;
                let display = held.display(&ctx)?;
                if let (Some(x), Some(y), Some(width), Some(height)) = (cell(x), cell(y), cell(width), cell(height)) {
                    display.frame().screen.fill(x, y, width, height, style);
                }
                Ok(())
            },
        )?,
    )?;

    let held = Rc::clone(frames);
    set(
        "termText",
        Function::new(
            ctx.clone(),
            move |ctx: Ctx<'js>, x: f64, y: f64, text: String, style: Opt<Value<'js>>| -> rquickjs::Result<_> {
                let style = style_of(&ctx, style.0)?;
                let display = held.display(&ctx)?;
                Ok(match (cell(x), cell(y)) {
                    (Some(x), Some(y)) => display.frame().screen.text(x, y, &text, style),
                    _ => 0,
                })
            },
        )?,
    )?;

    let held = Rc::clone(frames);
    set(
        "termCursor",
        Function::new(
            ctx.clone(),
            move |ctx: Ctx<'js>, x: f64, y: f64, visible: bool| -> rquickjs::Result<_> {
                let display = held.display(&ctx)?;
                let at = match (visible, cell(x), cell(y)) {
                    (true, Some(x), Some(y)) => Some((x, y)),
                    _ => None,
                };
                display.frame().screen.cursor(at);
                Ok(())
            },
        )?,
    )?;

    let held = Rc::clone(frames);
    set(
        "termCopy",
        Function::new(ctx.clone(), move |ctx: Ctx<'js>, text: String| -> rquickjs::Result<_> {
            let display = held.display(&ctx)?;
            let mut frame = display.frame();
            let bytes = copy_bytes(&text, frame.tmux);
            if let Err(error) = frame.output.write_all(&bytes).and_then(|()| frame.output.flush()) {
                return Err(throw(
                    &ctx,
                    ErrorClass::Error,
                    &format!("the copy did not reach the terminal: {error}"),
                ));
            }
            Ok(())
        })?,
    )
}

/// Add the functions of the frame loop and of the host: the run, the frame asks, quit, suspend, reload, and the state of
/// the display. Each needs the display.
fn add_loop<'js>(ctx: &Ctx<'js>, object: &Object<'js>, frames: &Rc<Frames>) -> rquickjs::Result<()> {
    let set = |name: &str, function: Function<'js>| object.set(name, function);

    let held = Rc::clone(frames);
    set(
        "termRun",
        Function::new(
            ctx.clone(),
            move |ctx: Ctx<'js>, event: Function<'js>, draw: Function<'js>| -> rquickjs::Result<_> {
                held.display(&ctx)?;
                if held.handler.borrow().is_some() {
                    return Err(throw(&ctx, ErrorClass::TypeError, "term.run runs once in a runtime"));
                }
                *held.handler.borrow_mut() = Some(Handler {
                    event: Persistent::save(&ctx, event),
                    draw: Persistent::save(&ctx, draw),
                });
                held.changed.notify_one();
                Ok(())
            },
        )?,
    )?;

    let held = Rc::clone(frames);
    set(
        "termRequestFrame",
        Function::new(ctx.clone(), move |ctx: Ctx<'js>, delay: f64| -> rquickjs::Result<_> {
            held.display(&ctx)?;
            let delay = if delay.is_finite() && delay > 0.0 {
                delay / 1000.0
            } else {
                0.0
            };
            let due = Instant::now() + Duration::try_from_secs_f64(delay).unwrap_or(Duration::MAX / 2);
            held.deadline
                .set(Some(held.deadline.get().map_or(due, |deadline| deadline.min(due))));
            held.changed.notify_one();
            Ok(())
        })?,
    )?;

    for (name, request) in [("termQuit", Request::Quit), ("termSuspend", Request::Suspend)] {
        let held = Rc::clone(frames);
        set(
            name,
            Function::new(ctx.clone(), move |ctx: Ctx<'js>| -> rquickjs::Result<_> {
                held.display(&ctx)?.ask(request.clone());
                Ok(())
            })?,
        )?;
    }

    let held = Rc::clone(frames);
    set(
        "termReload",
        Function::new(
            ctx.clone(),
            move |ctx: Ctx<'js>, snapshot: String| -> rquickjs::Result<_> {
                held.display(&ctx)?.ask(Request::Reload(snapshot));
                Ok(())
            },
        )?,
    )?;

    let held = Rc::clone(frames);
    set(
        "termSize",
        Function::new(ctx.clone(), move |ctx: Ctx<'js>| -> rquickjs::Result<_> {
            let size = held.display(&ctx)?.frame().screen.size();
            Ok(vec![size.columns, size.rows])
        })?,
    )?;

    let held = Rc::clone(frames);
    set(
        "termBackground",
        Function::new(ctx.clone(), move |ctx: Ctx<'js>| -> rquickjs::Result<_> {
            Ok(scheme_name(held.display(&ctx)?.frame().scheme))
        })?,
    )?;

    let held = Rc::clone(frames);
    set(
        "termTruecolor",
        Function::new(ctx.clone(), move |ctx: Ctx<'js>| -> rquickjs::Result<_> {
            Ok(held.display(&ctx)?.frame().truecolor)
        })?,
    )
}

/// Add the text functions. They need no display.
fn add_text<'js>(ctx: &Ctx<'js>, object: &Object<'js>) -> rquickjs::Result<()> {
    let set = |name: &str, function: Function<'js>| object.set(name, function);

    set(
        "termMeasure",
        Function::new(ctx.clone(), |text: String| {
            small(graphemes(&text).map(|(_, cells)| cells).sum())
        })?,
    )?;

    set(
        "termGraphemes",
        Function::new(ctx.clone(), |ctx: Ctx<'js>, text: String| -> rquickjs::Result<_> {
            let mut triples = Vec::new();
            let mut offset = 0;
            for (grapheme, cells) in graphemes(&text) {
                let length = units(grapheme);
                triples.extend([offset, length, small(cells)]);
                offset += length;
            }
            TypedArray::<i32>::new(ctx, triples)
        })?,
    )?;

    set(
        "termFit",
        Function::new(ctx.clone(), |text: String, cells: f64| {
            fit(&text, whole(cells).unwrap_or(0))
        })?,
    )?;

    set(
        "termWrap",
        Function::new(
            ctx.clone(),
            |ctx: Ctx<'js>, text: String, width: f64, head: f64| -> rquickjs::Result<_> {
                let Some(head) = count(head) else {
                    return Err(throw(&ctx, ErrorClass::TypeError, "head is an integer from 0"));
                };
                TypedArray::<i32>::new(ctx, wrap(&text, whole(width).filter(|&width| width > 0), head))
            },
        )?,
    )
}

/// Run the frame loop of `frames` on the JavaScript thread once `shown` gives the snapshot: take each waiting input,
/// give its events to the handler, then draw one frame. An asked frame comes at its deadline, and no sooner than one
/// interval after the last frame. Without a display, or when the runtime ends before the show, the loop ends at once.
pub(crate) async fn drive(
    ctx: Ctx<'_>,
    frames: Rc<Frames>,
    shown: oneshot::Receiver<Option<String>>,
    faults: mpsc::UnboundedSender<Report>,
) {
    let Some(display) = frames.display.clone() else {
        return;
    };
    // A runtime that is not shown waits here, so it takes no input and draws nothing while another runtime draws.
    let Ok(mut snapshot) = shown.await else {
        return;
    };
    let mut started = false;
    loop {
        // An asked frame waits for `term.run`, so a deadline that is due cannot wake the loop again and again.
        let due = frames.handler.borrow().as_ref().and(frames.due());
        tokio::select! {
            () = display.arrived.notified() => {}
            () = frames.changed.notified() => {}
            () = sleep_until(due) => {}
        }
        let Some((event, draw)) = restore(&ctx, &frames) else {
            // The inputs wait for `term.run`.
            continue;
        };
        let mut redraw = false;
        if !started {
            started = true;
            redraw = true;
            let start = kind(&ctx, "start").and_then(|object| {
                if let Some(snapshot) = snapshot.take() {
                    object.set("snapshot", snapshot)?;
                }
                Ok(object)
            });
            dispatch(&ctx, &event, start, &faults);
        }
        let inputs = display.take_inputs();
        redraw |= !inputs.is_empty();
        // Each input changes the display state when its event comes, so a handler reads the state of its own event.
        for input in inputs {
            if let Some(value) = event_object(&ctx, &display, input) {
                dispatch(&ctx, &event, value, &faults);
            }
        }
        let now = Instant::now();
        redraw |= frames.due().is_some_and(|due| due <= now);
        if redraw {
            // The frame answers each ask that is due now, also one that the rate limit holds back.
            if frames.deadline.get().is_some_and(|deadline| deadline <= now) {
                frames.deadline.set(None);
            }
            frames.last.set(Some(now));
            paint(&ctx, &display, &draw, &faults);
        }
    }
}

async fn sleep_until(due: Option<Instant>) {
    match due {
        Some(due) => tokio::time::sleep_until(due).await,
        None => std::future::pending().await,
    }
}

fn restore<'js>(ctx: &Ctx<'js>, frames: &Frames) -> Option<(Function<'js>, Function<'js>)> {
    let handler = frames.handler.borrow();
    let handler = handler.as_ref()?;
    Some((
        handler.event.clone().restore(ctx).ok()?,
        handler.draw.clone().restore(ctx).ok()?,
    ))
}

/// Call `event` with `value`, then run the promise reactions, so they settle before the frame.
fn dispatch<'js>(
    ctx: &Ctx<'js>,
    event: &Function<'js>,
    value: rquickjs::Result<Object<'js>>,
    faults: &mpsc::UnboundedSender<Report>,
) {
    let called = value.and_then(|value| event.call::<_, ()>((value,)));
    report(ctx, called, faults);
    while ctx.execute_pending_job() {}
}

/// Clear the grid, call `draw`, and write the changed cells. A failed write repaints the whole next frame.
fn paint<'js>(ctx: &Ctx<'js>, display: &Display, draw: &Function<'js>, faults: &mpsc::UnboundedSender<Report>) {
    display.frame().screen.clear();
    report(ctx, draw.call::<_, ()>(()), faults);
    while ctx.execute_pending_job() {}
    let mut frame = display.frame();
    let Frame {
        screen, output, bytes, ..
    } = &mut *frame;
    bytes.clear();
    screen.render(bytes);
    if output.write_all(bytes).and_then(|()| output.flush()).is_err() {
        // The output holds an unknown part of the frame, so the next frame writes every cell.
        screen.repaint();
    }
}

/// Send the throw of a handler as a fault. The loop goes on, so one broken handler does not stop the interface.
fn report(ctx: &Ctx<'_>, result: rquickjs::Result<()>, faults: &mpsc::UnboundedSender<Report>) {
    // The main loop reports each interrupt once, so a handler reports only its throw.
    if let Err(Error::Script(error)) = caught(ctx, result)
        && faults.send(Report::Fault(error)).is_err()
    {
        // The owner dropped the receiver, so it ignores faults.
    }
}

/// The JavaScript event of `input`, or `None` for an input that gives none, such as an unchanged background.
fn event_object<'js>(ctx: &Ctx<'js>, display: &Display, input: Input) -> Option<rquickjs::Result<Object<'js>>> {
    let value = match input {
        Input::Resize(size) => {
            display.frame().screen.resize(size);
            kind(ctx, "resize").and_then(|object| {
                object.set("w", size.columns)?;
                object.set("h", size.rows)?;
                Ok(object)
            })
        }
        Input::Event(Event::Key(key)) => kind(ctx, "key").and_then(|object| {
            let character = match key.code {
                Code::Char(character) => character.to_string(),
                _ => String::new(),
            };
            object.set("code", code_name(key.code))?;
            object.set("character", character)?;
            object.set("shifted", key.shifted.map(String::from).unwrap_or_default())?;
            object.set("baseLayout", key.base_layout.map(String::from).unwrap_or_default())?;
            object.set("text", key.text)?;
            object.set("modifiers", modifiers_object(ctx, key.modifiers)?)?;
            Ok(object)
        }),
        Input::Event(Event::Mouse(mouse)) => mouse_object(ctx, mouse),
        Input::Notice(notice) => kind(ctx, "notice").and_then(|object| {
            object.set("level", Json(notice.level))?;
            object.set("source", notice.source)?;
            object.set("text", notice.message)?;
            Ok(object)
        }),
        Input::Event(Event::Paste(text)) => kind(ctx, "paste").and_then(|object| {
            object.set("text", text)?;
            Ok(object)
        }),
        Input::Event(event @ (Event::FocusGained | Event::FocusLost)) => kind(ctx, "focus").and_then(|object| {
            object.set("focused", event == Event::FocusGained)?;
            Ok(object)
        }),
        Input::Event(Event::Background(color)) => {
            let scheme = scheme_of(color);
            if std::mem::replace(&mut display.frame().scheme, scheme) == scheme {
                return None;
            }
            kind(ctx, "background").and_then(|object| {
                object.set("background", scheme_name(scheme))?;
                Ok(object)
            })
        }
        Input::Event(Event::SchemeChanged) => {
            let mut frame = display.frame();
            if frame
                .output
                .write_all(BACKGROUND_QUERY)
                .and_then(|()| frame.output.flush())
                .is_err()
            {
                // The background stays as it is, and the next frame meets the same broken output.
            }
            return None;
        }
    };
    Some(value)
}

fn mouse_object<'js>(ctx: &Ctx<'js>, mouse: yuke_term::Mouse) -> rquickjs::Result<Object<'js>> {
    let object = kind(ctx, "mouse")?;
    object.set("column", mouse.column)?;
    object.set("row", mouse.row)?;
    let button = match mouse.button {
        Button::Left => "left".to_owned(),
        Button::Middle => "middle".to_owned(),
        Button::Right => "right".to_owned(),
        Button::None => "none".to_owned(),
        Button::WheelUp => "wheel_up".to_owned(),
        Button::WheelDown => "wheel_down".to_owned(),
        Button::WheelLeft => "wheel_left".to_owned(),
        Button::WheelRight => "wheel_right".to_owned(),
        Button::Extra(number) => format!("button_{number}"),
    };
    object.set("button", button)?;
    let event = match mouse.kind {
        MouseKind::Press => "press",
        MouseKind::Release => "release",
        MouseKind::Motion => "motion",
        MouseKind::Drag => "drag",
    };
    object.set("action", event)?;
    object.set("modifiers", modifiers_object(ctx, mouse.modifiers)?)?;
    Ok(object)
}

/// The modifiers of an event as booleans. The lock modifiers stay out.
fn modifiers_object<'js>(ctx: &Ctx<'js>, modifiers: Modifiers) -> rquickjs::Result<Object<'js>> {
    let object = Object::new(ctx.clone())?;
    for (name, modifier) in [
        ("shift", Modifiers::SHIFT),
        ("alt", Modifiers::ALT),
        ("ctrl", Modifiers::CTRL),
        ("super", Modifiers::SUPER),
        ("hyper", Modifiers::HYPER),
        ("meta", Modifiers::META),
    ] {
        object.set(name, modifiers.contains(modifier))?;
    }
    Ok(object)
}

fn kind<'js>(ctx: &Ctx<'js>, name: &str) -> rquickjs::Result<Object<'js>> {
    let object = Object::new(ctx.clone())?;
    object.set("type", name)?;
    Ok(object)
}

/// The name of a key: `character` for a key of one code point. A function key outside F1 to F35 is `unknown`.
fn code_name(code: Code) -> &'static str {
    const FUNCTION_KEYS: [&str; 35] = [
        "f1", "f2", "f3", "f4", "f5", "f6", "f7", "f8", "f9", "f10", "f11", "f12", "f13", "f14", "f15", "f16", "f17",
        "f18", "f19", "f20", "f21", "f22", "f23", "f24", "f25", "f26", "f27", "f28", "f29", "f30", "f31", "f32", "f33",
        "f34", "f35",
    ];
    match code {
        Code::Enter => "enter",
        Code::Tab => "tab",
        Code::Backspace => "backspace",
        Code::Escape => "esc",
        Code::Insert => "insert",
        Code::Delete => "delete",
        Code::Left => "left",
        Code::Right => "right",
        Code::Up => "up",
        Code::Down => "down",
        Code::PageUp => "page_up",
        Code::PageDown => "page_down",
        Code::Home => "home",
        Code::End => "end",
        Code::Menu => "menu",
        Code::F(number) => FUNCTION_KEYS
            .get(usize::from(number).wrapping_sub(1))
            .copied()
            .unwrap_or("unknown"),
        Code::Char(_) => "character",
    }
}

fn scheme_name(scheme: Scheme) -> &'static str {
    match scheme {
        Scheme::Dark => "dark",
        Scheme::Light => "light",
    }
}

/// A finite number from 0, cut to an integer. A number past `i32::MAX` counts as `i32::MAX`.
fn whole(value: f64) -> Option<usize> {
    #[expect(
        clippy::cast_possible_truncation,
        clippy::cast_sign_loss,
        reason = "the value is finite, from 0, and at most i32::MAX"
    )]
    (value.is_finite() && value >= 0.0).then(|| value.min(f64::from(i32::MAX)) as usize)
}

/// A cell coordinate or a size: a finite number from 0 to `u16::MAX`, cut to an integer. Others draw nothing.
fn cell(value: f64) -> Option<u16> {
    whole(value).and_then(|value| u16::try_from(value).ok())
}

/// An integer count from 0 to `i32::MAX`.
fn count(value: f64) -> Option<usize> {
    (value.fract() == 0.0 && value <= f64::from(i32::MAX))
        .then(|| whole(value))
        .flatten()
}

/// A small number for an `Int32Array`. The callers count UTF-16 units and cells of one string.
fn small(value: usize) -> i32 {
    i32::try_from(value).unwrap_or(i32::MAX)
}

/// The UTF-16 units of `text`.
fn units(text: &str) -> i32 {
    small(text.encode_utf16().count())
}

/// The style of a `term` call: `fg`, `bg`, `ul`, `bold`, `dim`, `italic`, `reverse`, and `underline`.
fn style_of<'js>(ctx: &Ctx<'js>, value: Option<Value<'js>>) -> rquickjs::Result<Style> {
    let Some(object) = value.filter(|value| !value.is_undefined() && !value.is_null()) else {
        return Ok(Style::default());
    };
    let Some(object) = object.as_object() else {
        return Err(throw(ctx, ErrorClass::TypeError, "a style is an object"));
    };
    let mut attributes = Attributes::NONE;
    for (name, attribute) in [
        ("bold", Attributes::BOLD),
        ("dim", Attributes::DIM),
        ("italic", Attributes::ITALIC),
        ("underline", Attributes::UNDERLINE),
        ("reverse", Attributes::REVERSE),
    ] {
        let flag: Value<'js> = object.get(name)?;
        match flag.as_bool() {
            Some(true) => attributes |= attribute,
            Some(false) => {}
            None if flag.is_undefined() => {}
            None => {
                return Err(throw(
                    ctx,
                    ErrorClass::TypeError,
                    &format!("the style field {name} is a boolean"),
                ));
            }
        }
    }
    Ok(Style {
        fg: color_of(ctx, &object.get("fg")?)?,
        bg: color_of(ctx, &object.get("bg")?)?,
        underline_color: color_of(ctx, &object.get("ul")?)?,
        attributes,
    })
}

/// A color: a palette index from 0 to 255, `#rrggbb`, or `reset`.
fn color_of<'js>(ctx: &Ctx<'js>, value: &Value<'js>) -> rquickjs::Result<Color> {
    if value.is_undefined() {
        return Ok(Color::Default);
    }
    if let Some(index) = value
        .as_number()
        .filter(|number| number.fract() == 0.0)
        .and_then(whole)
        .and_then(|number| u8::try_from(number).ok())
    {
        return Ok(Color::Index(index));
    }
    if let Some(text) = value.as_string() {
        let text = text.to_string()?;
        if text == "reset" {
            return Ok(Color::Default);
        }
        if let Some(rgb) = hex(&text) {
            return Ok(Color::Rgb(rgb));
        }
    }
    Err(throw(
        ctx,
        ErrorClass::TypeError,
        "a color is an index from 0 to 255, #rrggbb, or reset",
    ))
}

fn hex(text: &str) -> Option<Rgb> {
    let digits = text
        .strip_prefix('#')
        // `from_str_radix` takes a sign too, so each byte must be a hex digit.
        .filter(|digits| digits.len() == 6 && digits.bytes().all(|byte| byte.is_ascii_hexdigit()))?;
    let channel = |at: usize| u8::from_str_radix(&digits[at..at + 2], 16).ok();
    Some(Rgb {
        red: channel(0)?,
        green: channel(2)?,
        blue: channel(4)?,
    })
}

/// The OSC 52 sequence that puts `text` on the clipboard, inside a tmux passthrough as well when `tmux` holds.
fn copy_bytes(text: &str, tmux: bool) -> Vec<u8> {
    let mut encoded = Vec::new();
    yuke_ai::encode_base64_into(&mut encoded, text.as_bytes());
    let mut bytes = b"\x1b]52;c;".to_vec();
    bytes.extend_from_slice(&encoded);
    bytes.push(0x07);
    if tmux {
        bytes.extend_from_slice(b"\x1bPtmux;\x1b\x1b]52;c;");
        bytes.extend_from_slice(&encoded);
        bytes.extend_from_slice(b"\x07\x1b\\");
    }
    bytes
}

/// The UTF-16 length of the longest grapheme prefix of `text` that fits in `cells`.
fn fit(text: &str, cells: usize) -> i32 {
    let mut used = 0;
    let mut length = 0;
    for (grapheme, width) in graphemes(text) {
        if used + width > cells {
            break;
        }
        used += width;
        length += units(grapheme);
    }
    length
}

/// Wrap `text` at `width` cells, as `[start, end, soft]` triples of UTF-16 offsets. A line end (`\n` or `\r\n`) ends
/// a row (soft 0). A soft break (soft 1) comes before a grapheme that is no space and does not fit. The break goes
/// after the last space when the text from that space to the grapheme fits, else before the grapheme. Spaces never
/// break, and one wide grapheme can exceed `width`. Without a width, the text is one row. A nonzero `head` keeps
/// only the first `head` rows.
fn wrap(text: &str, width: Option<usize>, head: usize) -> Vec<i32> {
    let Some(width) = width else {
        return vec![0, units(text), 0];
    };
    let mut rows = Vec::new();
    let full = |rows: &Vec<i32>| head > 0 && rows.len() == head * 3;
    let (mut start, mut offset) = (0, 0);
    let (mut cells, mut break_at, mut break_cells) = (0, None, 0);
    for (grapheme, grapheme_cells) in graphemes(text) {
        let length = units(grapheme);
        if grapheme == "\n" || grapheme == "\r\n" {
            rows.extend([start, offset, 0]);
            if full(&rows) {
                return rows;
            }
            start = offset + length;
            cells = 0;
            break_at = None;
        } else {
            let space = grapheme == " ";
            if !space && cells + grapheme_cells > width && offset > start {
                let broke = break_at.filter(|&at| at > start && cells - break_cells + grapheme_cells <= width);
                let end = broke.unwrap_or(offset);
                rows.extend([start, end, 1]);
                if full(&rows) {
                    return rows;
                }
                cells = if broke.is_some() { cells - break_cells } else { 0 };
                start = end;
                break_at = None;
            }
            cells += grapheme_cells;
            if space {
                break_at = Some(offset + length);
                break_cells = cells;
            }
        }
        offset += length;
    }
    rows.extend([start, offset, 0]);
    rows
}

#[cfg(test)]
mod tests;
