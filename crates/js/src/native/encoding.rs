//! The UTF-8 functions of the native module for `TextEncoder` and `TextDecoder`. The text that reaches them is well
//! formed: `TextEncoder` replaces each lone surrogate first.

use rquickjs::{Ctx, Function, IntoJs, Object, TypedArray};

use crate::bytes::decode;
use crate::error::{ErrorClass, throw};

/// Add `encodeText`, `encodeTextInto`, and `decodeText` to `object`, the export object of the native module.
pub(super) fn add<'js>(ctx: &Ctx<'js>, object: &Object<'js>) -> rquickjs::Result<()> {
    object.set(
        "encodeText",
        Function::new(ctx.clone(), |ctx: Ctx<'js>, text: String| {
            TypedArray::<u8>::new(ctx, text.into_bytes())
        })?,
    )?;
    object.set(
        "encodeTextInto",
        Function::new(ctx.clone(), |ctx: Ctx<'js>, text: String, capacity: usize| {
            let (bytes, read) = prefix(&text, capacity);
            Ok::<_, rquickjs::Error>(Encoded {
                bytes: TypedArray::new(ctx, bytes.as_bytes())?,
                read,
            })
        })?,
    )?;
    object.set(
        "decodeText",
        Function::new(
            ctx.clone(),
            |ctx: Ctx<'js>, bytes: TypedArray<'js, u8>, fatal: bool, stream: bool| {
                let bytes = crate::bytes::copy(&bytes)?;
                let Some((text, rest)) = decode(&bytes, fatal, stream) else {
                    return Err(throw(&ctx, ErrorClass::TypeError, "the bytes are not valid UTF-8"));
                };
                Ok(Decoded { text, rest })
            },
        )?,
    )?;
    Ok(())
}

/// What `encodeTextInto` gives: the bytes, and the UTF-16 units of the text that they hold.
#[derive(IntoJs)]
struct Encoded<'js> {
    bytes: TypedArray<'js, u8>,
    read: usize,
}

/// What `decodeText` gives: the text, and the bytes of an incomplete character at the end of a stream.
#[derive(IntoJs)]
struct Decoded {
    text: String,
    rest: usize,
}

/// The longest start of `text` that fits in `capacity` bytes without a cut character, and its length in UTF-16 code
/// units, as `TextEncoder.encodeInto` counts it.
fn prefix(text: &str, capacity: usize) -> (&str, usize) {
    let mut end = 0;
    let mut read = 0;
    for character in text.chars() {
        if end + character.len_utf8() > capacity {
            break;
        }
        end += character.len_utf8();
        read += character.len_utf16();
    }
    (&text[..end], read)
}

#[cfg(test)]
mod tests {
    use super::prefix;

    #[test]
    fn a_prefix_ends_before_a_character_that_does_not_fit_and_counts_utf16_units() {
        // `é` is 2 bytes and 1 unit, `😀` is 4 bytes and 2 units.
        assert_eq!(prefix("é😀x", 5), ("é", 1));
        assert_eq!(prefix("é😀x", 6), ("é😀", 3));
    }
}
