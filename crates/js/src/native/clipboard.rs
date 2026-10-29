//! The clipboard function of the native module: `clipboardReadImage`, the image of the system clipboard as PNG.

use std::error::Error;
use std::sync::{Mutex, PoisonError};

use clipboard_rs::common::RustImage;
use clipboard_rs::{Clipboard, ClipboardContext, ContentFormat};
use rquickjs::{Ctx, Function, Object, Promise};
use yuke_ai::MAX_MEDIA_BYTES;
use yuke_engine::chain_text;

use crate::error::{ErrorClass, throw};
use crate::native::fs::Bytes;

/// The clipboard of the process, made at the first read. A context of X11 keeps a thread, so the reads share one.
static CLIPBOARD: Mutex<Option<ClipboardContext>> = Mutex::new(None);

/// Add `clipboardReadImage()`: a promise of the PNG bytes of the clipboard image, or of `undefined` without an image.
pub(crate) fn add<'js>(ctx: &Ctx<'js>, object: &Object<'js>) -> rquickjs::Result<()> {
    object.set(
        "clipboardReadImage",
        Function::new(ctx.clone(), |ctx: Ctx<'js>| -> rquickjs::Result<Promise<'js>> {
            let error_ctx = ctx.clone();
            Promise::wrap_future(&ctx, async move {
                // The read and the PNG encoding block, so they run off the thread of JavaScript.
                match tokio::task::spawn_blocking(read_image).await {
                    Ok(Ok(png)) => Ok(png.map(Bytes)),
                    Ok(Err(error)) => Err(throw(&error_ctx, ErrorClass::Error, &chain_text(&*error))),
                    Err(error) => Err(throw(
                        &error_ctx,
                        ErrorClass::Error,
                        &format!("the clipboard read failed: {error}"),
                    )),
                }
            })
        })?,
    )
}

/// The image of the clipboard as PNG bytes, or `None` without an image. A PNG over the limit of an attachment fails.
fn read_image() -> Result<Option<Vec<u8>>, Box<dyn Error + Send + Sync>> {
    let mut clipboard = CLIPBOARD.lock().unwrap_or_else(PoisonError::into_inner);
    let context = match &mut *clipboard {
        Some(context) => context,
        None => clipboard.insert(ClipboardContext::new()?),
    };
    if !context.has(ContentFormat::Image) {
        return Ok(None);
    }
    let png = context.get_image()?.to_png()?;
    within_limit(png.get_bytes()).map(Some)
}

/// A copy of `png`, or a failure when it is over the limit of an attachment.
fn within_limit(png: &[u8]) -> Result<Vec<u8>, Box<dyn Error + Send + Sync>> {
    if png.len() as u64 > MAX_MEDIA_BYTES {
        return Err(format!("the clipboard image is larger than the limit of {MAX_MEDIA_BYTES} bytes").into());
    }
    Ok(png.to_vec())
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn a_clipboard_image_at_the_limit_passes_and_one_byte_more_fails() {
        let limit = usize::try_from(MAX_MEDIA_BYTES).unwrap();
        assert_eq!(within_limit(&vec![7; limit]).unwrap().len(), 3_932_160);
        let over = within_limit(&vec![7; limit + 1]).unwrap_err();
        assert_eq!(
            over.to_string(),
            "the clipboard image is larger than the limit of 3932160 bytes"
        );
    }
}
