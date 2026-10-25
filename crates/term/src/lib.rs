//! The terminal of yuke, with no terminal library. [`Terminal`] puts the device in raw mode on the alternate screen
//! and probes it. Its reader thread parses the bytes into [`Event`]s. [`Screen`] is a cell grid whose render writes
//! only the changed cells, and every cell after a resize or a repaint.

mod event;
mod parser;
mod reader;
mod screen;
mod terminal;
mod width;

pub use event::{Button, Code, Event, Key, Media, Modifier, Modifiers, Mouse, MouseKind, Rgb, Scheme};
pub use screen::{Attributes, Color, Screen, Size, Style};
pub use terminal::Terminal;
