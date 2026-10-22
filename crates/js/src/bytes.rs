//! The bytes of a `Uint8Array`, copied out of the engine, and their UTF-8 decode.

use rquickjs::TypedArray;

/// A copy of the bytes of `array`. A detached buffer fails.
pub(crate) fn copy(array: &TypedArray<'_, u8>) -> rquickjs::Result<Vec<u8>> {
    #[expect(
        unsafe_code,
        reason = "rquickjs reads the bytes of a typed array only through an unsafe borrow"
    )]
    // SAFETY: the borrow ends inside this statement, and no JavaScript runs while it lives, so the engine cannot
    // detach or resize the buffer under it.
    let bytes = unsafe { array.as_bytes() }.map(<[u8]>::to_vec);
    bytes.ok_or_else(|| rquickjs::Error::new_from_js("detached Uint8Array", "bytes"))
}

/// Decode `bytes` as UTF-8. Each invalid sequence becomes U+FFFD, or fails with `None` when `fatal`. With `stream`, an
/// incomplete sequence at the end stays undecoded, and the second value is the byte count of that sequence.
pub(crate) fn decode(bytes: &[u8], fatal: bool, stream: bool) -> Option<(String, usize)> {
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
    use super::decode;

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
        // Live command output reads this way: an invalid byte decodes now, and only the cut character waits.
        assert_eq!(decode(b"\xff\xe2", false, true), Some(("\u{fffd}".to_owned(), 1)));
    }

    #[test]
    fn a_fatal_decode_fails_at_an_invalid_sequence_and_at_an_incomplete_end() {
        assert_eq!(decode(b"a\x80", true, false), None);
        assert_eq!(decode(b"a\xe2\x82", true, false), None);
        assert_eq!(decode(b"a\xe2\x82", true, true), Some(("a".to_owned(), 2)));
    }
}
