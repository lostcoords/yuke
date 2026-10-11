//! JSON writers for the request serializers. Only control bytes, `"`, and `\` are escaped, so other text stays as
//! UTF-8. A float prints in its shortest decimal form.

use std::fmt::Write as _;

use crate::json::Value;

/// A writer of one JSON value tree into a byte buffer. It places the commas between members and elements.
pub(crate) struct JsonWriter<'b> {
    out: &'b mut Vec<u8>,
    /// A value came before at this level, so the next one needs a comma.
    comma: bool,
}

impl<'b> JsonWriter<'b> {
    pub(crate) fn new(out: &'b mut Vec<u8>) -> Self {
        JsonWriter { out, comma: false }
    }

    fn value_start(&mut self) {
        if self.comma {
            self.out.push(b',');
        }
    }

    fn value_done(&mut self) {
        self.comma = true;
    }

    pub(crate) fn begin_object(&mut self) {
        self.value_start();
        self.out.push(b'{');
        self.comma = false;
    }

    pub(crate) fn end_object(&mut self) {
        self.out.push(b'}');
        self.value_done();
    }

    pub(crate) fn begin_array(&mut self) {
        self.value_start();
        self.out.push(b'[');
        self.comma = false;
    }

    pub(crate) fn end_array(&mut self) {
        self.out.push(b']');
        self.value_done();
    }

    /// Write a member name. The next write is its value.
    pub(crate) fn key(&mut self, name: &str) {
        self.value_start();
        self.out.push(b'"');
        escape_into(self.out, name.as_bytes());
        self.out.extend_from_slice(b"\":");
        self.comma = false;
    }

    pub(crate) fn string(&mut self, text: &str) {
        self.value_start();
        self.out.push(b'"');
        escape_into(self.out, text.as_bytes());
        self.out.push(b'"');
        self.value_done();
    }

    pub(crate) fn uint(&mut self, value: u64) {
        self.value_start();
        push_digits(self.out, value);
        self.value_done();
    }

    pub(crate) fn int(&mut self, value: i64) {
        self.value_start();
        if value < 0 {
            self.out.push(b'-');
        }
        push_digits(self.out, value.unsigned_abs());
        self.value_done();
    }

    pub(crate) fn null(&mut self) {
        self.value_start();
        self.out.extend_from_slice(b"null");
        self.value_done();
    }

    /// Write a finite float in its shortest decimal form. The encoder rejects a NaN or an infinity first.
    pub(crate) fn float(&mut self, value: f64) {
        self.value_start();
        _ = write!(ByteWriter(self.out), "{value}"); // A byte buffer never fails a write.
        self.value_done();
    }

    pub(crate) fn boolean(&mut self, value: bool) {
        self.value_start();
        self.out.extend_from_slice(if value { b"true" } else { b"false" });
        self.value_done();
    }

    /// Write a parsed value: members in document order, and numbers in their shortest decimal form.
    pub(crate) fn value(&mut self, value: &Value<'_>) {
        match value {
            Value::Null => self.null(),
            Value::Bool(flag) => self.boolean(*flag),
            Value::Integer(n) => self.int(*n),
            Value::Unsigned(n) => self.uint(*n),
            Value::Float(n) => self.float(*n),
            Value::String(text) => self.string(text),
            Value::Array(items) => {
                self.begin_array();
                for item in items {
                    self.value(item);
                }
                self.end_array();
            }
            Value::Object(members) => {
                self.begin_object();
                for (name, member) in members {
                    self.key(name);
                    self.value(member);
                }
                self.end_object();
            }
        }
    }

    /// Write caller JSON text without a check. An empty text writes `{}`.
    pub(crate) fn raw(&mut self, json: &str) {
        self.value_start();
        self.out.extend_from_slice(object_text(json).as_bytes());
        self.value_done();
    }

    /// Write the strings that `parts` yields as one JSON string, with no joined copy.
    pub(crate) fn string_parts<'s>(&mut self, parts: impl IntoIterator<Item = &'s str>) {
        self.value_start();
        self.out.push(b'"');
        for part in parts {
            escape_into(self.out, part.as_bytes());
        }
        self.out.push(b'"');
        self.value_done();
    }

    /// Write a tool result text. The OpenAI APIs have no error flag, so an error result starts with `Error: `.
    pub(crate) fn tool_text(&mut self, text: &str, is_error: bool) {
        self.string_parts([if is_error { "Error: " } else { "" }, text]);
    }

    /// Write bytes as a base64 string. A `mime` makes the string a data URL.
    pub(crate) fn base64(&mut self, mime: Option<&str>, data: &[u8]) {
        self.value_start();
        self.out.push(b'"');
        if let Some(mime) = mime {
            self.out.extend_from_slice(b"data:");
            escape_into(self.out, mime.as_bytes());
            self.out.extend_from_slice(b";base64,");
        }
        base64_into(self.out, data);
        self.out.push(b'"');
        self.value_done();
    }

    pub(crate) fn field_str(&mut self, name: &str, text: &str) {
        self.key(name);
        self.string(text);
    }

    pub(crate) fn field_uint(&mut self, name: &str, value: u64) {
        self.key(name);
        self.uint(value);
    }

    pub(crate) fn field_bool(&mut self, name: &str, value: bool) {
        self.key(name);
        self.boolean(value);
    }

    pub(crate) fn field_raw(&mut self, name: &str, json: &str) {
        self.key(name);
        self.raw(json);
    }

    /// Write the member when `value` is present. A missing value writes nothing.
    pub(crate) fn field_float_opt(&mut self, name: &str, value: Option<f64>) {
        if let Some(value) = value {
            self.key(name);
            self.float(value);
        }
    }
}

/// A byte buffer that takes formatted text with no temporary string.
pub(crate) struct ByteWriter<'b>(pub(crate) &'b mut Vec<u8>);

impl std::fmt::Write for ByteWriter<'_> {
    fn write_str(&mut self, text: &str) -> std::fmt::Result {
        self.0.extend_from_slice(text.as_bytes());
        Ok(())
    }
}

/// The elements of the context array. Each one after the first starts with a comma.
pub(crate) struct Elements<'b> {
    pub(crate) out: &'b mut Vec<u8>,
    /// An element comes before the next one.
    pub(crate) comma: bool,
}

impl Elements<'_> {
    /// Begin the next element, and return a writer for it.
    pub(crate) fn next(&mut self) -> JsonWriter<'_> {
        if self.comma {
            self.out.push(b',');
        }
        self.comma = true;
        JsonWriter::new(self.out)
    }
}

/// Append the decimal digits of `value`.
fn push_digits(out: &mut Vec<u8>, value: u64) {
    let mut digits = [0u8; 20];
    let mut at = digits.len();
    let mut rest = value;
    loop {
        at -= 1;
        digits[at] = b'0' + u8::try_from(rest % 10).unwrap_or_default();
        rest /= 10;
        if rest == 0 {
            break;
        }
    }
    out.extend_from_slice(&digits[at..]);
}

/// A caller JSON object text, which the caller may leave empty for `{}`.
pub(crate) fn object_text(text: &str) -> &str {
    if text.is_empty() { "{}" } else { text }
}

/// The escape of each byte: 0 for none, `u` for `\u00XX`, else the letter after the backslash.
const ESCAPE: [u8; 256] = {
    let mut table = [0u8; 256];
    let mut byte = 0;
    while byte < 0x20 {
        table[byte] = b'u';
        byte += 1;
    }
    table[0x08] = b'b';
    table[0x0C] = b'f';
    table[b'\n' as usize] = b'n';
    table[b'\r' as usize] = b'r';
    table[b'\t' as usize] = b't';
    table[b'"' as usize] = b'"';
    table[b'\\' as usize] = b'\\';
    table
};

/// Append the JSON string characters of `bytes`, without quotes.
pub(crate) fn escape_into(out: &mut Vec<u8>, bytes: &[u8]) {
    const HEX: &[u8; 16] = b"0123456789abcdef";
    let mut start = 0;
    for (i, &byte) in bytes.iter().enumerate() {
        let escape = ESCAPE[usize::from(byte)];
        if escape == 0 {
            continue;
        }
        out.extend_from_slice(&bytes[start..i]);
        if escape == b'u' {
            out.extend_from_slice(&[
                b'\\',
                b'u',
                b'0',
                b'0',
                HEX[usize::from(byte >> 4)],
                HEX[usize::from(byte & 0xF)],
            ]);
        } else {
            out.extend_from_slice(&[b'\\', escape]);
        }
        start = i + 1;
    }
    out.extend_from_slice(&bytes[start..]);
}

/// The two base64 characters of each 12-bit value. Two lookups encode a group of 3 bytes.
static BASE64_PAIRS: [[u8; 2]; 4096] = {
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
fn base64_into(out: &mut Vec<u8>, data: &[u8]) {
    let start = out.len();
    // The output grows once, so the loop writes each group of 4 characters in place.
    out.resize(start + data.len().div_ceil(3) * 4, 0);
    let (groups, rest) = data.as_chunks::<3>();
    let (cells, _) = out[start..].as_chunks_mut::<4>();
    let (cells, last) = cells.split_at_mut(groups.len());
    for (group, cell) in groups.iter().zip(cells) {
        let n = usize::from(group[0]) << 16 | usize::from(group[1]) << 8 | usize::from(group[2]);
        let [c0, c1] = BASE64_PAIRS[n >> 12];
        let [c2, c3] = BASE64_PAIRS[n & 0xfff];
        *cell = [c0, c1, c2, c3];
    }
    let n = match *rest {
        [a] => usize::from(a) << 16,
        [a, b] => usize::from(a) << 16 | usize::from(b) << 8,
        _ => return,
    };
    let [c0, c1] = BASE64_PAIRS[n >> 12];
    let [c2, _] = BASE64_PAIRS[n & 0xfff];
    last[0] = [c0, c1, if rest.len() == 2 { c2 } else { b'=' }, b'='];
}

#[cfg(test)]
mod tests {
    use super::*;

    fn written(write: impl FnOnce(&mut JsonWriter<'_>)) -> String {
        let mut out = Vec::new();
        write(&mut JsonWriter::new(&mut out));
        String::from_utf8(out).unwrap()
    }

    #[test]
    fn base64_data_url_across_chunks() {
        let data: Vec<u8> = (0..3 * 1024 + 7).map(|i: u32| u8::try_from(i % 256).unwrap()).collect();
        let mime = format!("x/{}", "y".repeat(300));
        let text = written(|jw| {
            jw.begin_object();
            jw.key("d");
            jw.base64(Some(&mime), &data);
            jw.end_object();
        });
        let prefix = format!("{{\"d\":\"data:{mime};base64,");
        let encoded = text.strip_prefix(&prefix).unwrap().strip_suffix("\"}").unwrap();
        assert_eq!(encoded.len(), data.len().div_ceil(3) * 4);
        let alphabet = encoded.strip_suffix("==").unwrap();
        assert!(
            alphabet
                .bytes()
                .all(|c| c.is_ascii_alphanumeric() || matches!(c, b'+' | b'/'))
        );
        assert_eq!(decode_base64(alphabet), data);
    }

    #[test]
    fn base64_padding() {
        // RFC 4648 section 10 gives these vectors.
        for (data, want) in [
            (&b""[..], ""),
            (b"f", "Zg=="),
            (b"fo", "Zm8="),
            (b"foo", "Zm9v"),
            (b"foob", "Zm9vYg=="),
            (b"fooba", "Zm9vYmE="),
            (b"foobar", "Zm9vYmFy"),
        ] {
            assert_eq!(written(|jw| jw.base64(None, data)), format!("\"{want}\""));
        }
    }

    #[test]
    fn string_escapes() {
        let text = "q\"b\\n\n\r\t\u{8}\u{c}\u{1}\u{1f}\u{7f}é";
        assert_eq!(
            written(|jw| jw.string(text)),
            "\"q\\\"b\\\\n\\n\\r\\t\\b\\f\\u0001\\u001f\u{7f}é\""
        );
    }

    #[test]
    fn parsed_value_writes_in_order() {
        let value = crate::json::parse(
            r#"{ "b" : [1, -2, 18446744073709551615, 1.5, 1e2, true, null, "q\"\u0001é"], "a" : {} }"#,
        )
        .unwrap();
        assert_eq!(
            written(|jw| jw.value(&value)),
            r#"{"b":[1,-2,18446744073709551615,1.5,100,true,null,"q\"\u0001é"],"a":{}}"#
        );
    }

    #[test]
    fn floats_use_shortest_form() {
        for (value, want) in [
            (0.7, "0.7"),
            (0.0, "0"),
            (1.0, "1"),
            (1e21, "1000000000000000000000"),
            (1e-7, "0.0000001"),
        ] {
            assert_eq!(written(|jw| jw.float(value)), want);
        }
    }

    #[test]
    fn commas_at_every_level() {
        let text = written(|jw| {
            jw.begin_object();
            jw.field_str("a", "x");
            jw.key("b");
            jw.begin_array();
            jw.uint(1);
            jw.begin_object();
            jw.end_object();
            jw.raw("");
            jw.end_array();
            jw.field_bool("c", true);
            jw.end_object();
        });
        assert_eq!(text, r#"{"a":"x","b":[1,{},{}],"c":true}"#);
    }

    fn decode_base64(alphabet: &str) -> Vec<u8> {
        let value = |c: u8| match c {
            b'A'..=b'Z' => c - b'A',
            b'a'..=b'z' => c - b'a' + 26,
            b'0'..=b'9' => c - b'0' + 52,
            b'+' => 62,
            b'/' => 63,
            _ => panic!("invalid base64 byte: {c}"),
        };
        // The fixture has two pads, so the final sextet has four unused bits.
        assert_eq!(value(alphabet.as_bytes()[alphabet.len() - 1]) & 15, 0);
        let mut out = Vec::new();
        for digits in alphabet.as_bytes().chunks(4) {
            let n = digits
                .iter()
                .enumerate()
                .fold(0u32, |n, (i, &c)| n | u32::from(value(c)) << (18 - 6 * i));
            out.extend_from_slice(&n.to_be_bytes()[1..digits.len()]);
        }
        out
    }
}
