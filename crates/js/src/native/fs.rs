//! The file functions of the native module: reads and writes. A relative path starts in the folder that the caller gives. Each
//! function runs off the JavaScript thread, because a blocking call would hold up the other JavaScript.

use std::fs::File;
use std::io::{self, BufRead, BufReader};
use std::path::Path;

use rquickjs::function::Async;
use rquickjs::{Ctx, Function, Object};

use crate::error::throw;

/// Add the file functions to `object`, the export object of the native module.
pub(super) fn add<'js>(ctx: &Ctx<'js>, object: &Object<'js>) -> rquickjs::Result<()> {
    object.set("readLines", Function::new(ctx.clone(), Async(read_lines))?)?;
    object.set("readText", Function::new(ctx.clone(), Async(read_text))?)?;
    object.set("writeText", Function::new(ctx.clone(), Async(write_text))?)?;
    Ok(())
}

/// What a read of lines gives.
#[derive(Debug, PartialEq, Eq)]
enum Lines {
    /// Numbered lines. `next` is the first line that the read left out. `cut` is a line that the read cut, because it
    /// alone is longer than the limit.
    Text {
        text: String,
        next: Option<u32>,
        cut: Option<u32>,
    },

    /// The file is an image of the media type `mime`.
    Image { path: String, mime: &'static str },
}

/// `readLines(path, folder, offset, limit, maxBytes)`: at most `limit` lines from line `offset` (from 1), each as
/// `N: text`, while they fit in `maxBytes`. An image gives its path and media type.
async fn read_lines(
    ctx: Ctx<'_>,
    path: String,
    folder: String,
    offset: u32,
    limit: u32,
    max_bytes: u32,
) -> rquickjs::Result<Object<'_>> {
    let full = Path::new(&folder).join(&path);
    let read = run_blocking(move || lines(&full, offset, limit, max_bytes as usize)).await;
    // A throw comes last: a pending exception across an await can reach other code.
    let lines = read.map_err(|message| throw(&ctx, "Error", &message))?;

    let object = Object::new(ctx.clone())?;
    match lines {
        Lines::Text { text, next, cut } => {
            object.set("text", text)?;
            object.set("next", next)?;
            object.set("cut", cut)?;
        }
        Lines::Image { path, mime } => {
            let image = Object::new(ctx.clone())?;
            image.set("path", path)?;
            image.set("mime", mime)?;
            object.set("image", image)?;
        }
    }
    Ok(object)
}

/// `readText(path, folder)`: the whole file as text.
async fn read_text(ctx: Ctx<'_>, path: String, folder: String) -> rquickjs::Result<String> {
    let full = Path::new(&folder).join(&path);
    let read = run_blocking(move || {
        let bytes = std::fs::read(&full).map_err(|error| describe(&error))?;
        String::from_utf8(bytes).map_err(|_| INVALID_UTF8.to_owned())
    })
    .await;
    read.map_err(|message| throw(&ctx, "Error", &message))
}

/// `writeText(path, folder, text)`: write the file, and make its missing parent folders. It answers the byte count.
async fn write_text(ctx: Ctx<'_>, path: String, folder: String, text: String) -> rquickjs::Result<usize> {
    let full = Path::new(&folder).join(&path);
    let written = run_blocking(move || {
        if let Some(parent) = full.parent() {
            std::fs::create_dir_all(parent).map_err(|error| describe(&error))?;
        }
        std::fs::write(&full, &text).map_err(|error| describe(&error))?;
        Ok(text.len())
    })
    .await;
    written.map_err(|message| throw(&ctx, "Error", &message))
}

/// Run `work` on the blocking threads of tokio.
async fn run_blocking<T: Send + 'static>(
    work: impl FnOnce() -> Result<T, String> + Send + 'static,
) -> Result<T, String> {
    tokio::task::spawn_blocking(work)
        .await
        .unwrap_or_else(|error| Err(format!("the file work failed: {error}")))
}

/// The text of a file that is not UTF-8.
const INVALID_UTF8: &str = "the file holds invalid UTF-8";

/// The text of a path that names a folder or a special file.
const NOT_A_FILE: &str = "the path names a directory or a special file";

/// The text of a failed file operation for the model.
fn describe(error: &io::Error) -> String {
    match error.kind() {
        io::ErrorKind::NotFound => "the path does not exist".to_owned(),
        io::ErrorKind::IsADirectory | io::ErrorKind::NotADirectory => NOT_A_FILE.to_owned(),
        io::ErrorKind::PermissionDenied => "the file system denied access to the path".to_owned(),
        _ => format!("the file system reported a failure: {error}"),
    }
}

/// The media type of an image by its first bytes: PNG, JPEG, GIF, or WebP (WHATWG MIME Sniffing, section 6.1).
fn image_type(start: &[u8]) -> Option<&'static str> {
    if start.starts_with(b"\x89PNG\r\n\x1a\n") {
        Some("image/png")
    } else if start.starts_with(b"\xff\xd8\xff") {
        Some("image/jpeg")
    } else if start.starts_with(b"GIF87a") || start.starts_with(b"GIF89a") {
        Some("image/gif")
    } else if start.len() >= 12 && start.starts_with(b"RIFF") && &start[8..12] == b"WEBP" {
        Some("image/webp")
    } else {
        None
    }
}

/// Read lines of the file at `full`.
fn lines(full: &Path, offset: u32, limit: u32, max_bytes: usize) -> Result<Lines, String> {
    let file = File::open(full).map_err(|error| describe(&error))?;
    let is_folder = file.metadata().map_err(|error| describe(&error))?.is_dir();
    if is_folder {
        return Err(NOT_A_FILE.to_owned());
    }
    let mut reader = BufReader::new(file);

    let start = reader.fill_buf().map_err(|error| describe(&error))?;
    if let Some(mime) = image_type(start) {
        return Ok(Lines::Image {
            // A path from the root, so a later read finds the same file.
            path: std::path::absolute(full)
                .unwrap_or_else(|_| full.to_owned())
                .to_string_lossy()
                .into_owned(),
            mime,
        });
    }

    let mut text = String::new();
    let mut taken = 0;
    let mut number: u32 = 0;
    let mut line = Vec::new();
    loop {
        if reader.fill_buf().map_err(|error| describe(&error))?.is_empty() {
            return Ok(Lines::Text {
                text,
                next: None,
                cut: None,
            });
        }
        number = number.saturating_add(1);
        if number < offset {
            reader.skip_until(b'\n').map_err(|error| describe(&error))?;
            continue;
        }
        if taken == limit {
            return Ok(Lines::Text {
                text,
                next: Some(number),
                cut: None,
            });
        }

        // A line longer than the limit cannot fit, so the read keeps only its start.
        let whole = read_line(&mut reader, max_bytes, &mut line).map_err(|error| describe(&error))?;
        let content = match std::str::from_utf8(&line) {
            Ok(content) => content,
            Err(error) if !whole && error.error_len().is_none() => {
                std::str::from_utf8(&line[..error.valid_up_to()]).unwrap_or_default()
            }
            Err(_) => return Err(INVALID_UTF8.to_owned()),
        };
        let entry = format!("{number}: {content}\n");

        if text.len() + entry.len() > max_bytes {
            if !text.is_empty() {
                return Ok(Lines::Text {
                    text,
                    next: Some(number),
                    cut: None,
                });
            }
            // The first line alone is over the limit: the read gives its start.
            let end = entry.floor_char_boundary(max_bytes);
            if !whole {
                reader.skip_until(b'\n').map_err(|error| describe(&error))?;
            }
            let more = !reader.fill_buf().map_err(|error| describe(&error))?.is_empty();
            return Ok(Lines::Text {
                text: entry[..end].to_owned(),
                next: more.then(|| number.saturating_add(1)),
                cut: Some(number),
            });
        }
        text.push_str(&entry);
        taken += 1;
    }
}

/// Read one line into `line` without its line feed. The line keeps at most `max_bytes + 1` bytes, so the caller sees a
/// line over the limit. The read then stops in the line. The answer tells whether the whole line was read.
fn read_line(reader: &mut impl BufRead, max_bytes: usize, line: &mut Vec<u8>) -> io::Result<bool> {
    line.clear();
    loop {
        let buffer = reader.fill_buf()?;
        if buffer.is_empty() {
            return Ok(true);
        }
        let room = max_bytes + 1 - line.len().min(max_bytes + 1);
        match buffer.iter().position(|byte| *byte == b'\n') {
            Some(end) if end <= room => {
                line.extend_from_slice(&buffer[..end]);
                reader.consume(end + 1);
                return Ok(true);
            }
            _ if buffer.len() <= room => {
                let length = buffer.len();
                line.extend_from_slice(buffer);
                reader.consume(length);
            }
            _ => {
                line.extend_from_slice(&buffer[..room]);
                reader.consume(room);
                return Ok(false);
            }
        }
    }
}
