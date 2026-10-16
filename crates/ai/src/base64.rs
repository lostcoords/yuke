//! Base64 (RFC 4648): the standard padded encoder of request media, and the URL-safe decoder of a JSON Web Token.

/// The two base64 characters of each 12-bit value. Two lookups encode a group of 3 bytes.
static PAIRS: [[u8; 2]; 4096] = {
    const ALPHABET: &[u8; 64] = b"ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/";
    let mut pairs = [[0; 2]; 4096];
    let mut index = 0;
    while index < 4096 {
        pairs[index] = [ALPHABET[index >> 6], ALPHABET[index & 63]];
        index += 1;
    }
    pairs
};

/// Append the standard padded base64 of `data`.
pub(crate) fn encode_into(out: &mut Vec<u8>, data: &[u8]) {
    let start = out.len();
    // The output grows once, so the loop writes each group of 4 characters in place.
    out.resize(start + data.len().div_ceil(3) * 4, 0);
    let (groups, rest) = data.as_chunks::<3>();
    let (cells, _) = out[start..].as_chunks_mut::<4>();
    let (cells, last) = cells.split_at_mut(groups.len());
    for (group, cell) in groups.iter().zip(cells) {
        let n = usize::from(group[0]) << 16 | usize::from(group[1]) << 8 | usize::from(group[2]);
        let [c0, c1] = PAIRS[n >> 12];
        let [c2, c3] = PAIRS[n & 0xfff];
        *cell = [c0, c1, c2, c3];
    }
    let n = match *rest {
        [a] => usize::from(a) << 16,
        [a, b] => usize::from(a) << 16 | usize::from(b) << 8,
        _ => return,
    };
    let [c0, c1] = PAIRS[n >> 12];
    let [c2, _] = PAIRS[n & 0xfff];
    last[0] = [c0, c1, if rest.len() == 2 { c2 } else { b'=' }, b'='];
}

/// The bytes of the URL-safe base64 `text` (RFC 4648, section 5), as a JSON Web Token holds it. The padding is
/// optional. `None` for a text that no canonical encoder writes: a byte outside the alphabet, a wrong length or
/// padding, or unused bits that are not zero.
pub(crate) fn decode_url_safe(text: &[u8]) -> Option<Vec<u8>> {
    let bare = text
        .strip_suffix(b"==")
        .or_else(|| text.strip_suffix(b"="))
        .unwrap_or(text);
    // The padding fills the last group to 4 characters.
    if bare.len() % 4 == 1 || (bare.len() != text.len() && !text.len().is_multiple_of(4)) {
        return None;
    }
    let value = |c: u8| match c {
        b'A'..=b'Z' => Some(c - b'A'),
        b'a'..=b'z' => Some(c - b'a' + 26),
        b'0'..=b'9' => Some(c - b'0' + 52),
        b'-' => Some(62),
        b'_' => Some(63),
        _ => None,
    };
    let mut out = Vec::with_capacity(bare.len() / 4 * 3 + 2);
    for digits in bare.chunks(4) {
        let mut n = 0_u32;
        for (index, &digit) in digits.iter().enumerate() {
            n |= u32::from(value(digit)?) << (18 - 6 * index);
        }
        // A group of k digits holds k - 1 bytes. The encoder sets the rest to zero (RFC 4648, section 3.5).
        let bytes = n.to_be_bytes();
        if bytes[digits.len()..].iter().any(|&byte| byte != 0) {
            return None;
        }
        out.extend_from_slice(&bytes[1..digits.len()]);
    }
    Some(out)
}

#[cfg(test)]
mod tests {
    use super::*;

    fn encoded(data: &[u8]) -> String {
        let mut out = Vec::new();
        encode_into(&mut out, data);
        String::from_utf8(out).unwrap()
    }

    // RFC 4648 section 10 gives these vectors.
    const VECTORS: [(&[u8], &str); 7] = [
        (b"", ""),
        (b"f", "Zg=="),
        (b"fo", "Zm8="),
        (b"foo", "Zm9v"),
        (b"foob", "Zm9vYg=="),
        (b"fooba", "Zm9vYmE="),
        (b"foobar", "Zm9vYmFy"),
    ];

    #[test]
    fn the_encoder_writes_the_vectors_of_the_rfc() {
        for (data, text) in VECTORS {
            assert_eq!(encoded(data), text);
        }
    }

    #[test]
    fn the_decoder_reads_the_vectors_with_or_without_padding() {
        for (data, text) in VECTORS {
            let bare = text.trim_end_matches('=');
            assert_eq!(decode_url_safe(text.as_bytes()).as_deref(), Some(data), "{text}");
            assert_eq!(decode_url_safe(bare.as_bytes()).as_deref(), Some(data), "{bare}");
        }
    }

    #[test]
    fn the_decoder_takes_the_url_safe_symbols_only() {
        assert_eq!(decode_url_safe(b"-_8"), Some(vec![0xfb, 0xff]));
        assert_eq!(decode_url_safe(b"+/8"), None);
    }

    #[test]
    fn a_text_that_no_canonical_encoder_writes_is_no_base64() {
        assert_eq!(decode_url_safe(b"Zm9vY"), None);
        assert_eq!(decode_url_safe(b"Zm 9"), None);
        assert_eq!(decode_url_safe(b"Zm=v"), None);
        assert_eq!(decode_url_safe(b"Zm8=="), None);
        // `Zh` sets unused bits, so no encoder writes it. `Zg` is the text of `f`.
        assert_eq!(decode_url_safe(b"Zh"), None);
    }
}
