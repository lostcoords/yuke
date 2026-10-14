//! A borrowed JSON tree and lenient field readers. A duplicate key rejects the document. An integer that fits `i64` is
//! an integer. A string without an escape borrows the input.

use std::borrow::Cow;
use std::fmt;
use std::marker::PhantomData;

use serde::de::{self, Deserialize, Deserializer, MapAccess, SeqAccess, Visitor};

/// The input is no JSON document, or a document with a duplicate key.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub(crate) struct Malformed;

/// One JSON value. Strings borrow the parsed input when they hold no escape.
#[derive(Debug, Clone, PartialEq)]
pub(crate) enum Value<'a> {
    Null,
    Bool(bool),
    /// An integer that fits `i64`.
    Integer(i64),
    /// An integer above `i64::MAX` that fits `u64`. It reads as a count, but not as an integer.
    Unsigned(u64),
    /// Any other number.
    Float(f64),
    String(Cow<'a, str>),
    Array(Vec<Value<'a>>),
    /// The members in document order. No two members share a key.
    Object(Vec<(Cow<'a, str>, Value<'a>)>),
}

/// Parse one document. Only a malformed one fails.
pub(crate) fn parse(data: &str) -> Result<Value<'_>, Malformed> {
    serde_json::from_str(data).map_err(|_| Malformed)
}

/// Parse bytes that may hold no UTF-8 text. Text that is not UTF-8 is no JSON document.
pub(crate) fn parse_bytes(data: &[u8]) -> Result<Value<'_>, Malformed> {
    parse(std::str::from_utf8(data).map_err(|_| Malformed)?)
}

impl<'a> Value<'a> {
    /// The member `key` of an object, or `None` for another value or a missing key.
    pub(crate) fn get(&self, key: &str) -> Option<&Value<'a>> {
        match self {
            Value::Object(members) => members.iter().find(|(name, _)| name == key).map(|(_, value)| value),
            _ => None,
        }
    }

    /// The string of `key`, or `None` when the key is absent or holds another type.
    pub(crate) fn get_str(&self, key: &str) -> Option<&str> {
        match self.get(key)? {
            Value::String(text) => Some(text),
            _ => None,
        }
    }

    /// The integer of `key`, or `None` when the key is absent or holds another type.
    pub(crate) fn get_int(&self, key: &str) -> Option<i64> {
        match self.get(key)? {
            Value::Integer(n) => Some(*n),
            _ => None,
        }
    }

    /// Read an index that must be present and fit `usize`. A negative index rejects the frame.
    pub(crate) fn get_index(&self, key: &str) -> Result<usize, Malformed> {
        usize::try_from(self.get_int(key).ok_or(Malformed)?).map_err(|_| Malformed)
    }

    /// The value of `key` when it is an object, else `None`.
    pub(crate) fn get_object(&self, key: &str) -> Option<&Value<'a>> {
        self.get(key).filter(|value| matches!(value, Value::Object(_)))
    }

    /// The string of `key`. A missing key or another type rejects the frame.
    pub(crate) fn require_str(&self, key: &str) -> Result<&str, Malformed> {
        self.get_str(key).ok_or(Malformed)
    }

    /// The string of `key`, or `None` when the key is absent or null. Another type rejects the frame.
    pub(crate) fn optional_str(&self, key: &str) -> Result<Option<&str>, Malformed> {
        match self.get(key) {
            None | Some(Value::Null) => Ok(None),
            Some(Value::String(text)) => Ok(Some(text)),
            Some(_) => Err(Malformed),
        }
    }

    /// Read a token count. Usage is no part of the answer, so an absent, null, negative, or malformed count reads as
    /// `None` rather than failing the response.
    pub(crate) fn count(&self, key: &str) -> Option<u64> {
        match self.get(key) {
            Some(Value::Integer(n)) => u64::try_from(*n).ok(),
            Some(Value::Unsigned(n)) => Some(*n),
            _ => None,
        }
    }
}

impl<'de> Deserialize<'de> for Value<'de> {
    fn deserialize<D: Deserializer<'de>>(deserializer: D) -> Result<Self, D::Error> {
        deserializer.deserialize_any(ValueVisitor)
    }
}

struct ValueVisitor;

/// The member count up to which an object checks each new key against the earlier ones.
const SHORT_OBJECT: usize = 16;

impl<'de> Visitor<'de> for ValueVisitor {
    type Value = Value<'de>;

    fn expecting(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.write_str("a JSON value")
    }

    fn visit_unit<E>(self) -> Result<Self::Value, E> {
        Ok(Value::Null)
    }

    fn visit_bool<E>(self, value: bool) -> Result<Self::Value, E> {
        Ok(Value::Bool(value))
    }

    fn visit_i64<E>(self, value: i64) -> Result<Self::Value, E> {
        Ok(Value::Integer(value))
    }

    fn visit_u64<E>(self, value: u64) -> Result<Self::Value, E> {
        Ok(i64::try_from(value).map_or(Value::Unsigned(value), Value::Integer))
    }

    fn visit_f64<E>(self, value: f64) -> Result<Self::Value, E> {
        Ok(Value::Float(value))
    }

    fn visit_borrowed_str<E>(self, value: &'de str) -> Result<Self::Value, E> {
        Ok(Value::String(Cow::Borrowed(value)))
    }

    fn visit_str<E>(self, value: &str) -> Result<Self::Value, E> {
        Ok(Value::String(Cow::Owned(value.to_owned())))
    }

    fn visit_string<E>(self, value: String) -> Result<Self::Value, E> {
        Ok(Value::String(Cow::Owned(value)))
    }

    fn visit_seq<A: SeqAccess<'de>>(self, mut seq: A) -> Result<Self::Value, A::Error> {
        let mut items = Vec::new();
        while let Some(item) = seq.next_element()? {
            items.push(item);
        }
        Ok(Value::Array(items))
    }

    fn visit_map<A: MapAccess<'de>>(self, mut map: A) -> Result<Self::Value, A::Error> {
        let mut members: Vec<(Cow<'de, str>, Value<'de>)> = Vec::new();
        while let Some(Text(key)) = map.next_key()? {
            // A short object checks each key at once. A long one sorts its keys at the end, so a hostile object
            // costs `n log n` and not `n * n`.
            if members.len() < SHORT_OBJECT && members.iter().any(|(name, _)| *name == key) {
                return Err(de::Error::custom("duplicate field"));
            }
            members.push((key, map.next_value()?));
        }
        if members.len() > SHORT_OBJECT {
            let mut keys: Vec<&str> = members.iter().map(|(name, _)| &**name).collect();
            keys.sort_unstable();
            if keys.windows(2).any(|pair| pair[0] == pair[1]) {
                return Err(de::Error::custom("duplicate field"));
            }
        }
        Ok(Value::Object(members))
    }
}

/// A JSON string that borrows the input when it holds no escape sequence. The `Deserialize` of `Cow<str>` makes an
/// owned copy, and `#[serde(borrow)]` borrows only a direct `Cow` field, not one inside an `Option`.
pub(crate) struct Text<'a>(pub(crate) Cow<'a, str>);

impl std::ops::Deref for Text<'_> {
    type Target = str;

    fn deref(&self) -> &str {
        &self.0
    }
}

impl<'de: 'a, 'a> Deserialize<'de> for Text<'a> {
    fn deserialize<D: Deserializer<'de>>(deserializer: D) -> Result<Self, D::Error> {
        deserializer.deserialize_str(TextVisitor(PhantomData))
    }
}

struct TextVisitor<'a>(PhantomData<&'a str>);

impl<'de: 'a, 'a> Visitor<'de> for TextVisitor<'a> {
    type Value = Text<'a>;

    fn expecting(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.write_str("a string")
    }

    fn visit_borrowed_str<E>(self, value: &'de str) -> Result<Self::Value, E> {
        Ok(Text(Cow::Borrowed(value)))
    }

    fn visit_str<E>(self, value: &str) -> Result<Self::Value, E> {
        Ok(Text(Cow::Owned(value.to_owned())))
    }

    fn visit_string<E>(self, value: String) -> Result<Self::Value, E> {
        Ok(Text(Cow::Owned(value)))
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn rejects_duplicate_keys() {
        assert_eq!(parse_bytes(br#"{"a":1,"a":2}"#), Err(Malformed));
        assert_eq!(parse_bytes(br#"{"x":{"a":1,"a":2}}"#), Err(Malformed));
        assert!(parse_bytes(br#"{"a":{"a":1}}"#).is_ok());
        // A long object finds its duplicate key at the end, wherever the two members stand.
        for (first, second) in [(0, 39), (20, 21), (3, 9)] {
            let mut members: Vec<String> = (0..40).map(|i| format!("\"k{i}\":{i}")).collect();
            members[second] = members[first].clone();
            assert_eq!(
                parse(&format!("{{{}}}", members.join(","))),
                Err(Malformed),
                "{first} {second}"
            );
        }
        let distinct: Vec<String> = (0..40).map(|i| format!("\"k{i}\":{i}")).collect();
        assert!(parse(&format!("{{{}}}", distinct.join(","))).is_ok());
    }

    #[test]
    fn unescaped_strings_borrow_input() {
        let value = parse_bytes(br#"{"plain":"abc","escaped":"a\nb"}"#).unwrap();
        assert!(matches!(value.get("plain"), Some(Value::String(Cow::Borrowed("abc")))));
        assert_eq!(value.get_str("escaped"), Some("a\nb"));
    }

    #[test]
    fn numbers_classify_as_integer_unsigned_or_float() {
        let value =
            parse_bytes(br#"{"i":-3,"p":5,"big":18446744073709551615,"huge":18446744073709551616,"low":-9223372036854775809,"f":1.5}"#)
                .unwrap();
        assert_eq!(value.get_int("i"), Some(-3));
        assert_eq!(value.get_index("p"), Ok(5));
        assert_eq!(value.count("i"), None);
        // A number above `i64::MAX` is a count, but not an integer.
        assert_eq!(value.get_int("big"), None);
        assert_eq!(value.count("big"), Some(u64::MAX));
        // A number past `u64::MAX` or below `i64::MIN` reads as a float. It is not an integer, and it has no count.
        for (key, expected) in [
            ("huge", 18_446_744_073_709_551_616.0),
            ("low", -9_223_372_036_854_775_808.0),
            ("f", 1.5),
        ] {
            assert_eq!(value.get(key), Some(&Value::Float(expected)), "{key}");
            assert_eq!(value.get_int(key), None, "{key}");
            assert_eq!(value.count(key), None, "{key}");
        }
        assert_eq!(value.get_index("i"), Err(Malformed));
    }

    // The depth bound keeps a hostile document off the stack. No provider sends a float past `f64`.
    #[test]
    fn rejects_float_overflow_and_deep_nesting() {
        assert_eq!(parse(r#"{"usage":1e400}"#), Err(Malformed));
        let nested = |depth: usize| format!("{}{}", "[".repeat(depth), "]".repeat(depth));
        assert!(parse(&nested(127)).is_ok());
        assert_eq!(parse(&nested(128)), Err(Malformed));
    }

    #[test]
    fn rejects_malformed_text_and_trailing_bytes() {
        assert_eq!(parse_bytes(b"{not json"), Err(Malformed));
        assert_eq!(parse_bytes(b"{} x"), Err(Malformed));
        assert_eq!(parse_bytes(b"\"\xff\""), Err(Malformed));
        assert!(parse_bytes(b" {} \n").is_ok());
    }
}
