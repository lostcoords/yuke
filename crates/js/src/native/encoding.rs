//! The UTF-8 functions of the native module for `TextEncoder` and `TextDecoder`. The text that reaches them is well
//! formed: `TextEncoder` replaces each lone surrogate first.

use rquickjs::{Ctx, Function, Object, TypedArray};

use crate::error::throw;

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
            let result = Object::new(ctx.clone())?;
            result.set("bytes", TypedArray::<u8>::new(ctx, bytes.as_bytes())?)?;
            result.set("read", read)?;
            Ok::<_, rquickjs::Error>(result)
        })?,
    )?;
    object.set(
        "decodeText",
        Function::new(
            ctx.clone(),
            |ctx: Ctx<'js>, bytes: TypedArray<'js, u8>, fatal: bool, stream: bool| {
                let bytes = crate::bytes::copy(&bytes)?;
                let Some((text, rest)) = decode(&bytes, fatal, stream) else {
                    return Err(throw(&ctx, "TypeError", "the bytes are not valid UTF-8"));
                };
                let result = Object::new(ctx.clone())?;
                result.set("text", text)?;
                result.set("rest", rest)?;
                Ok(result)
            },
        )?,
    )?;
    Ok(())
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

/// Decode `bytes` as UTF-8. Each invalid sequence becomes U+FFFD, or fails with `None` when `fatal`. With `stream`, an
/// incomplete sequence at the end stays undecoded, and the second value counts its bytes.
fn decode(bytes: &[u8], fatal: bool, stream: bool) -> Option<(String, usize)> {
    let mut text = String::with_capacity(bytes.len());
    let mut rest = bytes;
    loop {
        let error = match std::str::from_utf8(rest) {
            Ok(valid) => {
                text.push_str(valid);
                return Some((text, 0));
            }
            Err(error) => error,
        };
        let (valid, after) = rest.split_at(error.valid_up_to());
        text.push_str(std::str::from_utf8(valid).ok()?);
        match error.error_len() {
            None if stream => return Some((text, after.len())),
            _ if fatal => return None,
            None => {
                text.push(char::REPLACEMENT_CHARACTER);
                return Some((text, 0));
            }
            Some(length) => {
                text.push(char::REPLACEMENT_CHARACTER);
                rest = &after[length..];
            }
        }
    }
}

#[cfg(test)]
mod tests {
    use super::{decode, prefix};

    #[test]
    fn an_invalid_sequence_becomes_one_replacement_character_per_maximal_subpart() {
        // The bytes are `a`, a lone continuation byte, and the start of a 3-byte sequence that `b` cuts.
        assert_eq!(
            decode(b"a\x80\xe2\x82b", false, false),
            Some(("a\u{fffd}\u{fffd}b".to_owned(), 0))
        );
    }

    #[test]
    fn a_stream_keeps_an_incomplete_sequence_at_the_end() {
        assert_eq!(decode(b"a\xe2\x82", false, true), Some(("a".to_owned(), 2)));
        assert_eq!(decode(b"a\xe2\x82", false, false), Some(("a\u{fffd}".to_owned(), 0)));
    }

    #[test]
    fn a_fatal_decode_fails_at_an_invalid_sequence_and_at_an_incomplete_end() {
        assert_eq!(decode(b"a\x80", true, false), None);
        assert_eq!(decode(b"a\xe2\x82", true, false), None);
        assert_eq!(decode(b"a\xe2\x82", true, true), Some(("a".to_owned(), 2)));
    }

    #[test]
    fn a_prefix_ends_before_a_character_that_does_not_fit_and_counts_utf16_units() {
        // `é` is 2 bytes and 1 unit, `😀` is 4 bytes and 2 units.
        assert_eq!(prefix("é😀x", 5), ("é", 1));
        assert_eq!(prefix("é😀x", 6), ("é😀", 3));
    }
}
