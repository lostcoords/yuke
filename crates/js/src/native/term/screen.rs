//! `TestScreen`: a cell grid for the frame tests of `yuke:test`. It draws with the rules of the terminal grid.
//! `frame()` gives its cells and its cursor without a terminal.

use std::cell::RefCell;

use rquickjs::class::Trace;
use rquickjs::function::Opt;
use rquickjs::{Array, Class, Ctx, JsLifetime, Object, Value};
use yuke_term::{Attributes, Color, CursorShape, Rgb, Screen, Size, Style};

use super::{cell, cursor_of, style_of};
use crate::error::{ErrorClass, throw};

/// A grid of cells that no terminal shows.
#[derive(Trace, JsLifetime)]
#[rquickjs::class(rename = "TestScreen")]
pub(crate) struct TestScreen {
    #[qjs(skip_trace)]
    screen: RefCell<Screen>,
}

#[rquickjs::methods]
#[expect(
    clippy::needless_pass_by_value,
    reason = "the methods of a class take their arguments by value"
)]
impl TestScreen {
    #[qjs(constructor)]
    fn new(ctx: Ctx<'_>, columns: f64, rows: f64) -> rquickjs::Result<Self> {
        Ok(Self {
            screen: RefCell::new(Screen::new(size(&ctx, columns, rows)?)),
        })
    }

    /// Change the size and blank the grid.
    fn resize(&self, ctx: Ctx<'_>, columns: f64, rows: f64) -> rquickjs::Result<()> {
        self.screen.borrow_mut().resize(size(&ctx, columns, rows)?);
        Ok(())
    }

    /// Blank the grid and hide the cursor.
    fn clear(&self) {
        self.screen.borrow_mut().clear();
    }

    fn text<'js>(&self, ctx: Ctx<'js>, x: f64, y: f64, text: String, style: Opt<Value<'js>>) -> rquickjs::Result<u16> {
        let style = style_of(&ctx, style.0)?;
        Ok(match (cell(x), cell(y)) {
            (Some(x), Some(y)) => self.screen.borrow_mut().text(x, y, &text, style),
            _ => 0,
        })
    }

    fn fill<'js>(
        &self,
        ctx: Ctx<'js>,
        x: f64,
        y: f64,
        width: f64,
        height: f64,
        style: Opt<Value<'js>>,
    ) -> rquickjs::Result<()> {
        let style = style_of(&ctx, style.0)?;
        if let (Some(x), Some(y), Some(width), Some(height)) = (cell(x), cell(y), cell(width), cell(height)) {
            self.screen.borrow_mut().fill(x, y, width, height, style);
        }
        Ok(())
    }

    fn cursor<'js>(&self, ctx: Ctx<'js>, cursor: Opt<Value<'js>>) -> rquickjs::Result<()> {
        let cursor = cursor_of(&ctx, cursor.0)?;
        self.screen.borrow_mut().cursor(cursor);
        Ok(())
    }

    /// The rows of cells `{ text, width, style }` and the cursor. A hidden cursor gives no `cursor` key.
    fn frame<'js>(&self, ctx: Ctx<'js>) -> rquickjs::Result<Object<'js>> {
        let screen = self.screen.borrow();
        let Size { columns, rows } = screen.size();
        let cells = Array::new(ctx.clone())?;
        for row in 0..rows {
            let line = Array::new(ctx.clone())?;
            for column in 0..columns {
                let Some((text, width, style)) = screen.cell(column, row) else {
                    continue;
                };
                let cell = Object::new(ctx.clone())?;
                cell.set("text", text)?;
                cell.set("width", width)?;
                cell.set("style", style_object(&ctx, style)?)?;
                line.set(usize::from(column), cell)?;
            }
            cells.set(usize::from(row), line)?;
        }
        let frame = Object::new(ctx.clone())?;
        frame.set("width", columns)?;
        frame.set("height", rows)?;
        frame.set("cells", cells)?;
        if let Some(cursor) = screen.next_cursor() {
            let object = Object::new(ctx.clone())?;
            object.set("column", cursor.column)?;
            object.set("row", cursor.row)?;
            let shape = match cursor.shape {
                CursorShape::Default => None,
                CursorShape::Block => Some("block"),
                CursorShape::Underline => Some("underline"),
                CursorShape::Bar => Some("bar"),
            };
            if let Some(shape) = shape {
                object.set("shape", shape)?;
            }
            frame.set("cursor", object)?;
        }
        Ok(frame)
    }
}

/// Add the class `TestScreen` to `object`, the export object of the native module.
pub(super) fn add<'js>(ctx: &Ctx<'js>, object: &Object<'js>) -> rquickjs::Result<()> {
    object.set("TestScreen", Class::<TestScreen>::create_constructor(ctx)?)
}

fn size(ctx: &Ctx<'_>, columns: f64, rows: f64) -> rquickjs::Result<Size> {
    match (cell(columns), cell(rows)) {
        (Some(columns), Some(rows)) => Ok(Size { columns, rows }),
        _ => Err(throw(
            ctx,
            ErrorClass::TypeError,
            "a screen size is two whole numbers from 0 to 65535",
        )),
    }
}

/// The style as the frame tests read it: each color that is not the default, and each attribute that is on.
fn style_object<'js>(ctx: &Ctx<'js>, style: Style) -> rquickjs::Result<Object<'js>> {
    let object = Object::new(ctx.clone())?;
    for (name, color) in [
        ("fg", style.fg),
        ("bg", style.bg),
        ("underlineColor", style.underline_color),
    ] {
        match color {
            Color::Default => {}
            Color::Index(index) => object.set(name, index)?,
            Color::Rgb(Rgb { red, green, blue }) => object.set(name, format!("#{red:02x}{green:02x}{blue:02x}"))?,
        }
    }
    for (name, attribute) in [
        ("bold", Attributes::BOLD),
        ("dim", Attributes::DIM),
        ("italic", Attributes::ITALIC),
        ("underline", Attributes::UNDERLINE),
        ("reverse", Attributes::REVERSE),
    ] {
        if style.attributes.contains(attribute) {
            object.set(name, true)?;
        }
    }
    Ok(object)
}
