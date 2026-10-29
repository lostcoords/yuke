//! JSON writers for the request serializers. Only control bytes, `"`, and `\` are escaped, so other text stays as
//! UTF-8. A float prints in its shortest decimal form.

use std::io::Write as _;

use crate::json::Value;

/// A writer of one JSON value tree into a byte buffer. It places the commas between members and elements.
pub(crate) struct JsonWriter<'b> {
    pub(crate) out: &'b mut Vec<u8>,
    /// A value came before at this level, so the next one needs a comma.
    pub(crate) comma: bool,
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
        self.number(value);
    }

    pub(crate) fn int(&mut self, value: i64) {
        self.number(value);
    }

    pub(crate) fn null(&mut self) {
        self.value_start();
        self.out.extend_from_slice(b"null");
        self.value_done();
    }

    /// Write a finite float in its shortest decimal form. The encoder rejects a NaN or an infinity first.
    pub(crate) fn float(&mut self, value: f64) {
        self.number(value);
    }

    /// Write the decimal text of a number.
    fn number(&mut self, value: impl std::fmt::Display) {
        self.value_start();
        _ = write!(self.out, "{value}"); // A byte buffer never fails a write.
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
        self.out
            .extend_from_slice(if json.is_empty() { b"{}" } else { json.as_bytes() });
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
        crate::base64::encode_base64_into(self.out, data);
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

/// The arguments of a call when they are a JSON object, else `{}`. A model can write arguments that are not a JSON
/// object, and a provider refuses a later request that repeats them.
pub(crate) fn call_arguments(text: &str) -> &str {
    let object = text.trim_start().starts_with('{') && serde_json::from_str::<serde::de::IgnoredAny>(text).is_ok();
    if object { text } else { "{}" }
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

#[cfg(test)]
mod tests {
    use super::*;

    fn written(write: impl FnOnce(&mut JsonWriter<'_>)) -> String {
        let mut out = Vec::new();
        write(&mut JsonWriter::new(&mut out));
        String::from_utf8(out).unwrap()
    }

    #[test]
    fn base64_writes_a_data_url_with_an_escaped_media_type() {
        let text = written(|jw| {
            jw.begin_object();
            jw.key("d");
            jw.base64(Some("x/\"y\""), b"foob");
            jw.end_object();
        });

        assert_eq!(text, r#"{"d":"data:x/\"y\";base64,Zm9vYg=="}"#);
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
}
