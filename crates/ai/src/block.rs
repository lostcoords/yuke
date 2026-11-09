//! The context of a call: its blocks, their attachments, and the provider state that returns with them. A block owns
//! its bytes, so a context is a `Vec<Block>`.

use std::borrow::Cow;
use std::fmt;

use serde::{Deserialize, Serialize};

#[cfg(doc)]
use crate::Request;
use crate::{EncodeError, Protocol, Target, ToolDefinition};

/// The kind of provider state that a reasoning block must return verbatim. Each kind names the protocol that
/// produced the state. Only the encoder of that protocol writes it.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash, Serialize, Deserialize)]
#[cfg_attr(feature = "ts", derive(ts_rs::TS))]
#[serde(rename_all = "snake_case")]
#[non_exhaustive]
pub enum ReplayKind {
    /// The `signature` of an Anthropic thinking block. A compatible host may send an empty one.
    AnthropicSignature,
    /// The opaque `data` of an Anthropic redacted thinking block, which has no text.
    AnthropicRedacted,
    /// The `encrypted_content` of an OpenAI Responses reasoning item.
    ResponsesEncrypted,
    /// The merged `reasoning_details` JSON array of an OpenRouter Chat Completions message.
    OpenrouterDetails,
}

impl ReplayKind {
    /// The one protocol that sends this state in an answer and reads it in a request.
    fn protocol(self) -> Protocol {
        match self {
            Self::AnthropicSignature | Self::AnthropicRedacted => Protocol::AnthropicMessages,
            Self::ResponsesEncrypted => Protocol::OpenaiResponses,
            Self::OpenrouterDetails => Protocol::OpenaiChat,
        }
    }
}

/// The model and host that answered a request. Provider state returns only to the same model at the same host.
#[derive(Debug, Clone, PartialEq, Eq, Hash, Serialize, Deserialize)]
#[cfg_attr(feature = "ts", derive(ts_rs::TS))]
#[serde(rename_all = "camelCase")]
pub struct Origin {
    /// The upstream model ID.
    pub model: String,
    /// The route base URL without its final slashes, so `https://h/v1/` and `https://h/v1` are one origin.
    pub base_url: String,
}

impl Origin {
    /// The same origin, borrowed.
    pub fn as_borrowed(&self) -> OriginRef<'_> {
        OriginRef {
            model: &self.model,
            base_url: &self.base_url,
        }
    }

    /// Report whether `target` names this model at this host.
    pub fn matches(&self, target: &Target) -> bool {
        self.as_borrowed() == OriginRef::of(target)
    }
}

/// A borrowed [`Origin`].
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash)]
pub struct OriginRef<'a> {
    /// The upstream model ID.
    pub model: &'a str,
    /// The route base URL without its final slashes.
    pub base_url: &'a str,
}

impl<'a> OriginRef<'a> {
    /// The origin of an answer to `target`. It borrows the target bytes.
    pub fn of(target: &'a Target) -> Self {
        OriginRef {
            model: &target.model,
            base_url: target.route.base_url.trim_end_matches('/'),
        }
    }
}

impl From<OriginRef<'_>> for Origin {
    fn from(origin: OriginRef<'_>) -> Self {
        Origin {
            model: origin.model.to_owned(),
            base_url: origin.base_url.to_owned(),
        }
    }
}

/// Provider state, and the origin that may receive it again. The state must return to its provider verbatim.
#[derive(Debug, Clone, PartialEq, Eq, Hash, Serialize, Deserialize)]
#[cfg_attr(feature = "ts", derive(ts_rs::TS))]
#[serde(rename_all = "camelCase")]
pub struct ReasoningReplay {
    /// The model and host that produced the state.
    pub origin: Origin,
    /// Which provider state `data` holds.
    pub kind: ReplayKind,
    /// The state bytes.
    pub data: String,
}

/// A borrowed [`ReasoningReplay`] that a stream event returns.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash)]
pub struct ReasoningReplayRef<'a> {
    /// The model and host that produced the state.
    pub origin: OriginRef<'a>,
    /// Which provider state `data` holds.
    pub kind: ReplayKind,
    /// The state bytes.
    pub data: &'a str,
}

impl From<ReasoningReplayRef<'_>> for ReasoningReplay {
    fn from(replay: ReasoningReplayRef<'_>) -> Self {
        ReasoningReplay {
            origin: replay.origin.into(),
            kind: replay.kind,
            data: replay.data.to_owned(),
        }
    }
}

/// A kind of content: what an attachment holds, and what a model reads or writes. `Other` is a media type that no
/// protocol names, and no model lists.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash)]
#[non_exhaustive]
pub enum Modality {
    /// Text.
    Text,
    /// An image.
    Image,
    /// Sound.
    Audio,
    /// A moving picture.
    Video,
    /// A PDF document.
    Pdf,
    /// A media type no protocol names.
    Other,
}

/// The digest of the content of a blob, such as its SHA-256. Its text is 64 lowercase hex characters, in `Display` and
/// in JSON, and it also names a stored file. JSON reads either case.
#[derive(Clone, Copy, PartialEq, Eq, Hash)]
pub struct Digest(pub [u8; 32]);

impl fmt::Display for Digest {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        self.0.iter().try_for_each(|byte| write!(f, "{byte:02x}"))
    }
}

impl fmt::Debug for Digest {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        write!(f, "Digest({self})")
    }
}

impl Serialize for Digest {
    fn serialize<S: serde::Serializer>(&self, serializer: S) -> Result<S::Ok, S::Error> {
        serializer.collect_str(self)
    }
}

impl<'de> Deserialize<'de> for Digest {
    fn deserialize<D: serde::Deserializer<'de>>(deserializer: D) -> Result<Self, D::Error> {
        use serde::de::{Error, Unexpected};

        let text = String::deserialize(deserializer)?;
        let invalid = || D::Error::invalid_value(Unexpected::Str(&text), &"64 hex characters");
        if text.len() != 64 {
            return Err(invalid());
        }
        let digit = |byte: u8| match byte {
            b'0'..=b'9' => Ok(byte - b'0'),
            b'a'..=b'f' => Ok(byte - b'a' + 10),
            b'A'..=b'F' => Ok(byte - b'A' + 10),
            _ => Err(invalid()),
        };
        let mut digest = [0; 32];
        for (byte, &[high, low]) in digest.iter_mut().zip(text.as_bytes().as_chunks::<2>().0) {
            *byte = digit(high)? << 4 | digit(low)?;
        }
        Ok(Digest(digest))
    }
}

/// Bytes in the caller's store, named by the digest of their content. Equal digests name equal bytes. Thus the request
/// of a resumed context reads no blob that the encoder kept.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash, Serialize, Deserialize)]
#[cfg_attr(feature = "ts", derive(ts_rs::TS))]
#[serde(rename_all = "camelCase")]
pub struct Blob {
    /// The digest of the content, such as its SHA-256. JSON holds it as 64 lowercase hex characters.
    #[cfg_attr(feature = "ts", ts(type = "string"))]
    pub digest: Digest,
    /// The byte count of the content. [`BlobStore`] answers are checked against it.
    pub len: usize,
}

/// The caller's store of blob bytes. The encoder reads a blob only when it writes that element.
pub trait BlobStore: Sync {
    /// Answer the bytes of `digest`, or `None` when the store lacks them. The store can return borrowed bytes or an
    /// owned copy.
    ///
    /// # Errors
    ///
    /// Returns the store error when the read fails. The encode then fails with [`EncodeError::BlobRead`].
    fn read(&self, digest: &Digest) -> Result<Option<Cow<'_, [u8]>>, Box<dyn std::error::Error + Send + Sync>>;
}

/// Answer the bytes of `blob` from `store`. Bytes of another length fail: the store holds other content.
pub(crate) fn read_blob<'s>(store: Option<&'s dyn BlobStore>, blob: &Blob) -> Result<Cow<'s, [u8]>, EncodeError> {
    let digest = blob.digest;
    let bytes = match store {
        Some(store) => store
            .read(&digest)
            .map_err(|source| EncodeError::BlobRead { digest, source })?,
        None => None,
    };
    bytes
        .filter(|bytes| bytes.len() == blob.len)
        .ok_or(EncodeError::UnresolvedBlob { digest })
}

/// Which side a block belongs to: the user or the assistant.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash)]
pub enum Role {
    /// The user's side.
    User,
    /// The assistant's side.
    Assistant,
}

impl Role {
    /// The wire name of the role.
    pub fn as_str(self) -> &'static str {
        match self {
            Self::User => "user",
            Self::Assistant => "assistant",
        }
    }
}

/// One block of the context. Its kind fixes its role ([`Block::role`]), so it holds only content of that role.
/// The serializer groups the blocks into the messages of each protocol.
#[derive(Debug, Clone, PartialEq, Eq, Hash, Serialize, Deserialize)]
#[cfg_attr(feature = "ts", derive(ts_rs::TS))]
#[serde(rename_all = "snake_case")]
#[non_exhaustive]
pub enum Block {
    /// User text.
    UserText(String),
    /// A user attachment.
    Media(Media),
    /// The result of a tool call.
    ToolResult(ToolResult),
    /// Assistant text.
    AssistantText(String),
    /// Assistant reasoning.
    Reasoning(Reasoning),
    /// A tool call of the assistant.
    ToolCall(ToolCall),
}

impl Block {
    /// A block of user text.
    pub fn user_text(text: impl Into<String>) -> Self {
        Block::UserText(text.into())
    }

    /// A block of assistant text.
    pub fn assistant_text(text: impl Into<String>) -> Self {
        Block::AssistantText(text.into())
    }

    /// The role the kind fixes.
    pub fn role(&self) -> Role {
        match self {
            Self::UserText(_) | Self::Media(_) | Self::ToolResult(_) => Role::User,
            Self::AssistantText(_) | Self::Reasoning(_) | Self::ToolCall(_) => Role::Assistant,
        }
    }
}

impl From<ToolResult> for Block {
    fn from(result: ToolResult) -> Self {
        Block::ToolResult(result)
    }
}

/// One attachment. Its media type selects the block each protocol writes.
#[derive(Debug, Clone, PartialEq, Eq, Hash, Serialize, Deserialize)]
#[cfg_attr(feature = "ts", derive(ts_rs::TS))]
#[serde(rename_all = "camelCase")]
pub struct Media {
    /// The bytes in the caller's store. The encoder reads them through [`Request::blobs`] only when it writes the
    /// element.
    pub blob: Blob,
    /// The IANA media type, such as `image/png` or `application/pdf`.
    pub mime: String,
    /// The name a provider requires beside file bytes. An image needs none.
    #[serde(default, skip_serializing_if = "String::is_empty")]
    pub filename: String,
}

impl Media {
    /// An attachment of `blob` with the media type `mime` and no file name.
    pub fn new(blob: Blob, mime: impl Into<String>) -> Self {
        Media {
            blob,
            mime: mime.into(),
            filename: String::new(),
        }
    }

    /// The kind its media type names, in any letter case. A protocol writes a different part for each kind.
    pub fn kind(&self) -> Modality {
        // A media type ignores the letter case (RFC 6838).
        let mime = self.mime.to_ascii_lowercase();
        let mime = mime.as_str();
        if mime.starts_with("image/") {
            Modality::Image
        } else if mime.starts_with("audio/") {
            Modality::Audio
        } else if mime.starts_with("video/") {
            Modality::Video
        } else if mime.starts_with("text/") {
            Modality::Text
        } else if mime == "application/pdf" {
            Modality::Pdf
        } else {
            Modality::Other
        }
    }
}

/// Reasoning text, and the provider state that returns with it. A request carries the state only to the origin that
/// produced it, in that protocol. Elsewhere the block drops, except where a dialect replays the text.
#[derive(Debug, Clone, PartialEq, Eq, Hash, Serialize, Deserialize)]
#[cfg_attr(feature = "ts", derive(ts_rs::TS))]
#[serde(rename_all = "camelCase")]
pub struct Reasoning {
    /// The reasoning text.
    pub text: String,
    /// `None` for text alone: a block that never finished, or one whose provider sent no state.
    // ts-rs marks the field optional only with `default` beside `skip_serializing_if`.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub replay: Option<ReasoningReplay>,
}

impl Reasoning {
    /// The state a request to `target` may carry: the state of the same model at the same host in the protocol of
    /// `target`, or `None`. One host can serve one model over two protocols.
    pub fn replay_to(&self, target: &Target) -> Option<(ReplayKind, &str)> {
        let replay = self.replay.as_ref()?;
        // An empty encrypted content carries nothing. An empty Anthropic signature still replays.
        let empty = replay.kind == ReplayKind::ResponsesEncrypted && replay.data.is_empty();
        (replay.origin.matches(target) && replay.kind.protocol() == target.wire.protocol() && !empty)
            .then_some((replay.kind, replay.data.as_str()))
    }
}

/// A tool call of the assistant.
#[derive(Debug, Clone, PartialEq, Eq, Hash, Serialize, Deserialize)]
#[cfg_attr(feature = "ts", derive(ts_rs::TS))]
#[serde(rename_all = "camelCase")]
pub struct ToolCall {
    /// The provider's call id.
    pub call_id: String,
    /// The tool name.
    pub name: String,
    /// A JSON object text, written verbatim. An empty text writes `{}`. The caller checks it.
    pub arguments: String,
}

/// A borrowed [`ToolCall`] that a stream event returns.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash)]
pub struct ToolCallRef<'a> {
    /// The provider's call id.
    pub call_id: &'a str,
    /// The tool name.
    pub name: &'a str,
    /// A JSON object text. The caller checks it.
    pub arguments: &'a str,
}

impl From<ToolCallRef<'_>> for ToolCall {
    fn from(call: ToolCallRef<'_>) -> Self {
        ToolCall {
            call_id: call.call_id.to_owned(),
            name: call.name.to_owned(),
            arguments: call.arguments.to_owned(),
        }
    }
}

/// The result of one tool call.
// Most results have no media and no loaded tools, so the JSON leaves out both empty lists.
#[derive(Debug, Clone, PartialEq, Eq, Hash, Serialize, Deserialize)]
#[cfg_attr(feature = "ts", derive(ts_rs::TS))]
#[serde(rename_all = "camelCase")]
pub struct ToolResult {
    /// The call this result answers.
    pub call_id: String,

    /// The result text.
    pub content: String,

    /// The call failed.
    pub is_error: bool,

    /// Attachments beside the text. Each protocol places them where its result shape allows.
    #[serde(default, skip_serializing_if = "Vec::is_empty")]
    pub media: Vec<Media>,

    /// The deferred tools this result loads. Anthropic references each one by name. Responses answers its search
    /// with the declarations. A request that defers no tool writes only the text of the result.
    #[serde(default, skip_serializing_if = "Vec::is_empty")]
    pub loaded: Vec<ToolDefinition>,
}

impl ToolResult {
    /// The result of a call that succeeded.
    pub fn success(call_id: impl Into<String>, content: impl Into<String>) -> Self {
        ToolResult {
            call_id: call_id.into(),
            content: content.into(),
            is_error: false,
            media: Vec::new(),
            loaded: Vec::new(),
        }
    }

    /// The result of a call that failed. `content` tells the model what went wrong.
    pub fn error(call_id: impl Into<String>, content: impl Into<String>) -> Self {
        ToolResult {
            is_error: true,
            ..ToolResult::success(call_id, content)
        }
    }

    /// The same result with attachments beside its text.
    #[must_use]
    pub fn with_media(self, media: Vec<Media>) -> Self {
        ToolResult { media, ..self }
    }

    /// The same result with the deferred tools that it loads.
    #[must_use]
    pub fn with_loaded(self, loaded: Vec<ToolDefinition>) -> Self {
        ToolResult { loaded, ..self }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    use crate::testing::assert_same;

    #[test]
    fn a_media_type_names_its_kind_in_any_letter_case() {
        let blob = Blob {
            digest: Digest([0; 32]),
            len: 0,
        };
        let kinds: Vec<Modality> = ["IMAGE/PNG", "Application/PDF", "text/Plain"]
            .into_iter()
            .map(|mime| Media::new(blob, mime).kind())
            .collect();

        assert_eq!(kinds, [Modality::Image, Modality::Pdf, Modality::Text]);
    }

    struct Store;

    impl BlobStore for Store {
        fn read(&self, _: &Digest) -> Result<Option<Cow<'_, [u8]>>, Box<dyn std::error::Error + Send + Sync>> {
            Ok(Some(Cow::Borrowed(b"ab")))
        }
    }

    #[test]
    fn blob_read_checks_length() {
        let blob = Blob {
            digest: Digest([0; 32]),
            len: 2,
        };
        let missing = || {
            Err(EncodeError::UnresolvedBlob {
                digest: Digest([0; 32]),
            })
        };
        assert_same(read_blob(None, &blob), missing());
        assert_same(read_blob(Some(&Store), &blob), Ok(Cow::Borrowed(&b"ab"[..])));
        // The store holds other content under this digest, so the request must not send it.
        assert_same(read_blob(Some(&Store), &Blob { len: 3, ..blob }), missing());
    }

    // The store keeps this JSON, so this test must catch a renamed field or variant.
    #[test]
    fn block_json_keeps_its_stored_shape() {
        let digest = "00ff".repeat(16);
        let blob = Blob {
            digest: Digest([0x00, 0xff].repeat(16).try_into().unwrap()),
            len: 3,
        };
        let replay = ReasoningReplay {
            origin: Origin {
                model: "m".to_owned(),
                base_url: "https://h/v1".to_owned(),
            },
            kind: ReplayKind::AnthropicSignature,
            data: "sig".to_owned(),
        };
        let cases = [
            (Block::user_text("hi"), r#"{"user_text":"hi"}"#.to_owned()),
            (Block::assistant_text("ok"), r#"{"assistant_text":"ok"}"#.to_owned()),
            (
                Block::Media(Media::new(blob, "image/png")),
                format!(r#"{{"media":{{"blob":{{"digest":"{digest}","len":3}},"mime":"image/png"}}}}"#),
            ),
            (
                Block::Media(Media {
                    filename: "a.pdf".to_owned(),
                    ..Media::new(blob, "application/pdf")
                }),
                format!(
                    r#"{{"media":{{"blob":{{"digest":"{digest}","len":3}},"mime":"application/pdf","filename":"a.pdf"}}}}"#
                ),
            ),
            (
                Block::Reasoning(Reasoning {
                    text: "think".to_owned(),
                    replay: None,
                }),
                r#"{"reasoning":{"text":"think"}}"#.to_owned(),
            ),
            (
                Block::Reasoning(Reasoning {
                    text: "think".to_owned(),
                    replay: Some(replay),
                }),
                r#"{"reasoning":{"text":"think","replay":{"origin":{"model":"m","baseUrl":"https://h/v1"},"kind":"anthropic_signature","data":"sig"}}}"#.to_owned(),
            ),
            (
                Block::ToolCall(ToolCall { call_id: "c1".to_owned(), name: "read".to_owned(), arguments: r#"{"path":"a"}"#.to_owned() }),
                r#"{"tool_call":{"callId":"c1","name":"read","arguments":"{\"path\":\"a\"}"}}"#.to_owned(),
            ),
            (
                Block::ToolResult(ToolResult::success("c1", "text")),
                r#"{"tool_result":{"callId":"c1","content":"text","isError":false}}"#.to_owned(),
            ),
            (
                Block::ToolResult(
                    ToolResult::error("c1", "failed")
                        .with_media(vec![Media::new(blob, "image/png")])
                        .with_loaded(vec![ToolDefinition { name: "grep".to_owned(), description: "Search.".to_owned(), input_schema: "{}".to_owned(), defer_loading: false }.deferred()]),
                ),
                format!(
                    r#"{{"tool_result":{{"callId":"c1","content":"failed","isError":true,"media":[{{"blob":{{"digest":"{digest}","len":3}},"mime":"image/png"}}],"loaded":[{{"name":"grep","description":"Search.","inputSchema":"{{}}","deferLoading":true}}]}}}}"#
                ),
            ),
        ];
        for (block, json) in cases {
            assert_eq!(serde_json::to_string(&block).unwrap(), json);
            assert_eq!(serde_json::from_str::<Block>(&json).unwrap(), block);
        }
    }

    #[test]
    fn digest_json_needs_64_hex_characters() {
        let parse = |digest: &str| serde_json::from_str::<Blob>(&format!(r#"{{"digest":"{digest}","len":1}}"#));
        let mut expected = Digest([0; 32]);
        expected.0[0] = 0xab;
        expected.0[31] = 0x09;
        let text = format!("ab{}09", "0".repeat(60));
        assert_eq!(parse(&text).unwrap().digest, expected);
        assert_eq!(parse(&text.to_uppercase()).unwrap().digest, expected);
        assert!(parse(&text[..62]).is_err());
        assert!(parse(&format!("{text}00")).is_err());
        assert!(parse(&format!("zz{}", &text[2..])).is_err());
        assert!(parse(&format!("{}zz", &text[..62])).is_err());
    }
}
