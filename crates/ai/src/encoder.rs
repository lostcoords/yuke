//! Encode requests. The encoder keeps each encoding, so the next request writes only the changed elements, the last
//! element, and the head. It hashes every block, and it copies no transcript-sized buffer per request.

use std::fmt;
use std::hash::{Hash, Hasher};
use std::sync::Arc;

use crate::request::{Block, OriginRef, Protocol, Request, Target, Wire};
use crate::transport::Outgoing;
use crate::wire::{self, json::JsonWriter, outgoing::HeadText};
use crate::wyhash::Wyhash;

/// A request that cannot be encoded. The encoder sends nothing then.
#[derive(Debug, Clone)]
#[non_exhaustive]
pub enum EncodeError {
    /// The protocol has no shape for some content or tool.
    // @todo(xyaman): Add a precise reason for unsupported requests.
    Unsupported,
    /// The blob store lacks a blob, or answers bytes of another length.
    UnresolvedBlob {
        /// The digest of the blob.
        digest: crate::Digest,
    },
    /// The blob store failed to read a blob. [`std::error::Error::source`] returns the store error.
    BlobRead {
        /// The digest of the blob.
        digest: crate::Digest,
        /// The store error.
        source: Arc<dyn std::error::Error + Send + Sync>,
    },
    /// The credential does not match the credential header of the route.
    CredentialMismatch,
    /// A route or identity header is not a valid HTTP field, or the transport or the encoder writes it. Or the
    /// credential or the session id is not a valid header value.
    InvalidHeader {
        /// The header name. The error never holds a header value, because a value can be a credential.
        name: String,
    },
    /// The temperature or the nucleus sampling mass is NaN or infinite. JSON has no such number.
    InvalidSampling,
}

impl fmt::Display for EncodeError {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            Self::Unsupported => f.write_str("the protocol cannot carry this content or tool"),
            Self::UnresolvedBlob { digest } => {
                f.write_str("the caller could not resolve the attachment blob ")?;
                digest.iter().try_for_each(|byte| write!(f, "{byte:02x}"))
            }
            // The text names no cause, because `source` returns it.
            Self::BlobRead { digest, .. } => {
                f.write_str("the blob store failed to read the attachment blob ")?;
                digest.iter().try_for_each(|byte| write!(f, "{byte:02x}"))
            }
            Self::CredentialMismatch => f.write_str("the credential does not match the route"),
            // A rejected name can hold a control byte, so it prints escaped.
            Self::InvalidHeader { name } => write!(f, "the request header {name:?} is invalid"),
            Self::InvalidSampling => f.write_str("the sampling values must be finite numbers"),
        }
    }
}

impl std::error::Error for EncodeError {
    fn source(&self) -> Option<&(dyn std::error::Error + 'static)> {
        match self {
            Self::BlobRead { source, .. } => Some(&**source),
            _ => None,
        }
    }
}

/// One encoded request. Its bytes borrow the encoder until the next `encode`.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct Encoded<'a> {
    /// The URL, headers, and body parts to send.
    pub http: Outgoing<'a>,
    /// Selects the response decoder.
    pub protocol: Protocol,
    /// The model and host that answer, which the reasoning state of the response names.
    pub origin: OriginRef<'a>,
}

/// The encoder of one context. See the module documentation. `Debug` writes no request bytes.
#[derive(Default)]
pub struct Encoder {
    /// The encoded elements, joined by commas, then the head of the last request. One buffer holds both.
    items: Vec<u8>,
    /// The hash of each block the elements encode, and whether it holds the cache marker, so a moved marker encodes
    /// both elements again.
    hashes: Vec<u64>,
    /// Each element of `items`, in order.
    elements: Vec<Element>,
    /// The hash of the request fields that shape the elements. Another value encodes every element again.
    key: u64,
    /// The URL, the headers, and the origin of the last request.
    head: HeadText,
}

#[derive(Debug, Clone, Copy)]
struct Element {
    /// The first block of the element.
    block: usize,
    /// The offset of the element in `items`, before its comma.
    offset: usize,
}

impl fmt::Debug for Encoder {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.debug_struct("Encoder")
            .field("elements", &self.elements.len())
            .finish_non_exhaustive()
    }
}

impl Encoder {
    /// An encoder that holds no encoding yet.
    pub fn new() -> Self {
        Encoder::default()
    }

    /// Encode `request` for `target`, and borrow both only until this returns. The result borrows this encoder until
    /// the next `encode`. A failed call leaves the encoder ready.
    ///
    /// # Errors
    ///
    /// Returns [`EncodeError`] if the protocol cannot carry the content, a blob does not resolve, the route is invalid,
    /// or a sampling value is not finite.
    pub fn encode(&mut self, target: &Target, request: Request<'_>) -> Result<Encoded<'_>, EncodeError> {
        if ![request.settings.temperature, request.settings.top_p]
            .into_iter()
            .flatten()
            .all(f64::is_finite)
        {
            return Err(EncodeError::InvalidSampling);
        }
        if !target.tool_search && request.tools.iter().any(|tool| tool.defer_loading) {
            return Err(EncodeError::Unsupported);
        }

        self.head.build(target, request.session_id)?;
        let elements_end = self.serialize(target, &request)?;
        let items = &self.items;
        let body = [&items[elements_end..], &items[..elements_end], b"]}".as_slice()];

        Ok(Encoded {
            http: Outgoing::from_parts(&self.head.url, &self.head.headers, body),
            protocol: target.wire.protocol(),
            origin: self.head.origin(),
        })
    }

    /// Drop the elements that can change, and return the block to encode from. `marker` is the block of the new
    /// cache marker. The hashes of the equal blocks stay, so the caller hashes only the blocks after them.
    fn keep(&mut self, key: u64, blocks: &[Block], marker: Option<usize>) -> usize {
        // The buffer holds elements of this key from here on, also after a failure.
        if std::mem::replace(&mut self.key, key) != key {
            self.items.clear();
            self.hashes.clear();
            self.elements.clear();
            return 0;
        }

        let same = self
            .hashes
            .iter()
            .zip(blocks)
            .enumerate()
            .take_while(|&(i, (hash, block))| *hash == hash_block(block, marker == Some(i)))
            .count();

        self.hashes.truncate(same);

        // The next block decides where an element ends, so the element that holds the last equal block encodes
        // again. That element is also the last one when every block is equal, and a new block can extend it.
        while let Some(last) = self.elements.pop() {
            if last.block < same {
                self.items.truncate(last.offset);
                return last.block;
            }
        }

        self.items.clear();
        0
    }

    /// Write the body as the context elements, then the head. Return where the elements end. Only an element that
    /// this call encodes reads its blobs.
    fn serialize(&mut self, target: &Target, request: &Request<'_>) -> Result<usize, EncodeError> {
        let blocks = request.blocks;
        let key = element_key(target, request);
        let marker = wire::cache_index(target.wire, blocks);
        let from = self.keep(key, blocks, marker);
        let hashed = self.hashes.len();
        self.hashes.extend(
            blocks
                .iter()
                .enumerate()
                .skip(hashed)
                .map(|(i, block)| hash_block(block, marker == Some(i))),
        );

        // A failed write leaves a partial last element, and the next request drops the last element first.
        // The buffer holds only kept elements here, so any byte means an element comes first.
        let mut jw = JsonWriter {
            comma: !self.items.is_empty(),
            out: &mut self.items,
        };

        self.elements.reserve(blocks.len().saturating_sub(from));
        let mut start = from;
        while start < blocks.len() {
            let offset = jw.out.len();
            // A failed write keeps its start, so the next request drops the partial element.
            self.elements.push(Element { block: start, offset });
            let end = wire::write_group(&mut jw, target, request, start, marker)?;
            // A group of blocks the protocol drops writes no element, so it records none.
            if jw.out.len() == offset {
                self.elements.pop();
            }
            start = end;
        }

        // The next request truncates to a kept element, which drops this head too.
        let elements_end = self.items.len();
        let head_element = wire::write_head(&mut self.items, target, request)?;
        if head_element && elements_end != 0 {
            self.items.push(b',');
        }

        Ok(elements_end)
    }
}

/// Hash the settings that the elements read: the protocol, the origin, the Chat replay mode, and the deferral of a
/// tool. Every other setting writes only the head, so a change to it keeps the elements.
fn element_key(target: &Target, request: &Request<'_>) -> u64 {
    let mut hasher = Wyhash::default();
    target.wire.protocol().hash(&mut hasher);
    OriginRef::of(target).hash(&mut hasher);
    wire::defers_tools(request.tools).hash(&mut hasher);
    if let Wire::OpenaiChat(chat) = &target.wire {
        chat.reasoning_replay.hash(&mut hasher);
    }
    hasher.finish()
}

fn hash_block(block: &Block, marked: bool) -> u64 {
    let mut hasher = Wyhash::default();
    (block, marked).hash(&mut hasher);
    hasher.finish()
}

#[cfg(test)]
mod tests {
    use std::borrow::Cow;

    use super::*;
    use crate::Settings;
    use crate::request::OriginRef;
    use crate::request::{
        AnthropicWire, BlobStore, ChatWire, MaxTokensField, Media, Reasoning, ReasoningReplayMode, ReplayKind,
        ResponsesDialect, ResponsesWire, SEARCH_TOOL_NAME, ThinkingFormat, ToolCall, ToolDefinition, ToolResult,
    };
    use crate::route::Credential;
    use crate::route::{CredentialHeader, Route};
    use crate::transport::Header;
    use crate::wire::testing::{TestBlobs, blob, replay, target_of};

    const ALL_WIRES: [Wire; 3] = [
        Wire::AnthropicMessages(AnthropicWire {
            max_tokens: 8,
            cache: true,
        }),
        Wire::OpenaiChat(ChatWire {
            dialect: crate::ChatDialect::Standard,
            thinking_format: ThinkingFormat::None,
            reasoning_replay: ReasoningReplayMode::None,
            max_tokens_field: MaxTokensField::MaxTokens,
        }),
        Wire::OpenaiResponses(ResponsesWire {
            dialect: ResponsesDialect::Standard,
            cache: true,
        }),
    ];

    fn plain_wires() -> [Wire; 3] {
        [
            Wire::AnthropicMessages(AnthropicWire {
                max_tokens: 8,
                cache: false,
            }),
            Wire::OpenaiChat(ChatWire::default()),
            Wire::OpenaiResponses(ResponsesWire::default()),
        ]
    }

    fn body(encoded: &Encoded<'_>) -> Vec<u8> {
        encoded.http.body().flatten().copied().collect::<Vec<u8>>()
    }

    /// Check that `encoded` holds the body a fresh encoder writes for the same request: a kept element must equal
    /// a new one.
    fn expect_fresh(encoded: &[u8], target: &Target, request: Request<'_>) {
        let mut fresh = Encoder::new();
        let expected = body(&fresh.encode(target, request).unwrap());
        assert_eq!(String::from_utf8_lossy(encoded), String::from_utf8_lossy(&expected));
    }

    /// Encode with `encoder`, and check the body against a fresh encoder.
    fn encode_checked(encoder: &mut Encoder, model: &str, wire: Wire, request: Request<'_>) -> Result<(), EncodeError> {
        let target = target_of(model, wire);
        let encoded = body(&encoder.encode(&target, request)?);
        expect_fresh(&encoded, &target, request);
        Ok(())
    }

    fn text(user: bool, value: &str) -> Block {
        if user {
            Block::user_text(value)
        } else {
            Block::assistant_text(value)
        }
    }

    fn image(data: &'static str) -> Block {
        Block::Media(Media::new(blob(data), "image/png"))
    }

    const U: bool = true;
    const A: bool = false;

    /// A store that counts its reads and answers from the test store.
    #[derive(Default)]
    struct Counter {
        reads: std::sync::atomic::AtomicUsize,
    }

    impl BlobStore for Counter {
        fn read(
            &self,
            digest: &crate::Digest,
        ) -> Result<Option<Cow<'_, [u8]>>, Box<dyn std::error::Error + Send + Sync>> {
            self.reads.fetch_add(1, std::sync::atomic::Ordering::Relaxed);
            TestBlobs.read(digest)
        }
    }

    impl Counter {
        fn reads(&self) -> usize {
            self.reads.load(std::sync::atomic::Ordering::Relaxed)
        }
    }

    // `encode_checked` compares each successful call with a fresh encoding, so it checks the encoder state that a
    // failed call left. The blob fails in the middle of a write, so the encoder holds a partial element to drop.
    #[test]
    fn missing_blob_fails_and_fixed_request_resumes() {
        let missing = image("zz");
        let short = [text(U, "a"), text(A, "b"), text(U, "c")];
        let long_missing = [text(U, "a"), text(A, "b"), text(U, "c"), text(A, "d"), missing.clone()];
        let long = [text(U, "a"), text(A, "b"), text(U, "c"), text(A, "d"), text(U, "e")];
        let calls: [(&[Block], bool); 6] = [
            (std::slice::from_ref(&missing), false),
            (std::slice::from_ref(&missing), false),
            (&short, true),
            (&long_missing, false),
            (&long_missing, false),
            (&long, true),
        ];
        for wire in ALL_WIRES {
            let mut encoder = Encoder::new();
            for (blocks, valid) in calls {
                let checked = encode_checked(&mut encoder, "m", wire, Request::new(blocks).blobs(&TestBlobs));
                if valid {
                    checked.unwrap();
                } else {
                    let digest = blob("zz").digest;
                    assert!(matches!(checked, Err(EncodeError::UnresolvedBlob { digest: d }) if d == digest));
                }
            }
        }
    }

    // The image sits in the first element. A head setting changes no element, so the next request keeps the image and
    // reads no blob. `encode_checked` proves the kept body equals a fresh one.
    #[test]
    fn head_setting_change_keeps_elements() {
        let blocks = [image("ab"), text(A, "b"), text(U, "c")];
        let before = [ToolDefinition::new("read", "Read.", "{}")];
        let after = [ToolDefinition::new("read", "Read a file.", "{}")];
        let pairs = [
            (
                Wire::AnthropicMessages(AnthropicWire {
                    max_tokens: 8,
                    cache: false,
                }),
                Wire::AnthropicMessages(AnthropicWire {
                    max_tokens: 16,
                    cache: false,
                }),
            ),
            (
                Wire::OpenaiChat(ChatWire::default()),
                Wire::OpenaiChat(ChatWire {
                    thinking_format: ThinkingFormat::Openai,
                    max_tokens_field: MaxTokensField::MaxCompletionTokens,
                    ..ChatWire::default()
                }),
            ),
            (
                Wire::OpenaiResponses(ResponsesWire::default()),
                Wire::OpenaiResponses(ResponsesWire {
                    dialect: ResponsesDialect::Codex,
                    cache: false,
                }),
            ),
        ];
        for (first, second) in pairs {
            let counter = Counter::default();
            let mut encoder = Encoder::new();
            encode_checked(
                &mut encoder,
                "m",
                first,
                Request::new(&blocks)
                    .tools(&before)
                    .blobs(&counter)
                    .settings(&Settings::new().system("s")),
            )
            .unwrap();
            encode_checked(
                &mut encoder,
                "m",
                second,
                Request::new(&blocks)
                    .tools(&after)
                    .blobs(&counter)
                    .settings(&Settings::new().system("t")),
            )
            .unwrap();
            // `encode_checked` reads the image once more for its fresh encoding of each request.
            assert_eq!(counter.reads(), 3);
        }
    }

    // Elements read the Chat replay mode and whether a tool defers, so a change to either encodes them again. A switch
    // between a native and a bridge target changes the deferral. `encode_checked` compares each body with a fresh one.
    #[test]
    fn element_setting_change_reencodes_elements() {
        let replayed = [
            text(U, "a"),
            Block::Reasoning(Reasoning {
                text: "r".to_string(),
                replay: None,
            }),
            text(A, "b"),
            text(U, "c"),
        ];
        let mut chat = Encoder::new();
        for mode in [ReasoningReplayMode::None, ReasoningReplayMode::ReasoningContent] {
            let wire = Wire::OpenaiChat(ChatWire {
                reasoning_replay: mode,
                ..ChatWire::default()
            });
            encode_checked(&mut chat, "m", wire, Request::new(&replayed)).unwrap();
        }

        let plain = [ToolDefinition::new(SEARCH_TOOL_NAME, "Find.", "{}")];
        let deferred = [plain[0].clone(), ToolDefinition::new("read", "Read.", "{}").deferred()];
        let searched = [
            text(U, "go"),
            Block::ToolCall(ToolCall::new("call_1", SEARCH_TOOL_NAME, "{}")),
            Block::ToolResult(ToolResult::success("call_1", "found").with_loaded(deferred[1..].to_vec())),
            // Later blocks keep the cache marker off the result, so only the key can encode it again.
            text(A, "done"),
            text(U, "next"),
        ];
        for wire in [ALL_WIRES[0], Wire::OpenaiResponses(ResponsesWire::default())] {
            let mut encoder = Encoder::new();
            for tools in [&deferred[..], &plain[..], &deferred[..]] {
                encode_checked(&mut encoder, "m", wire, Request::new(&searched).tools(tools)).unwrap();
            }
        }
    }

    // The model can write arguments that are not a JSON object. The next request repeats the call, so it must stay
    // valid.
    #[test]
    fn call_with_invalid_arguments_keeps_the_request_valid() {
        let blocks = [
            text(U, "go"),
            Block::ToolCall(ToolCall::new("call_1", "read", r#"{"path":"#)),
            Block::ToolResult(ToolResult::error("call_1", "not valid JSON")),
        ];
        for wire in ALL_WIRES {
            let target = target_of("m", wire);
            let mut encoder = Encoder::new();

            let sent = String::from_utf8(body(&encoder.encode(&target, Request::new(&blocks)).unwrap())).unwrap();

            assert!(serde_json::from_str::<serde_json::Value>(&sent).is_ok(), "{sent}");
            assert!(!sent.contains("path"), "{sent}");
            // The call stays, with empty arguments.
            assert!(sent.contains("call_1"), "{sent}");
            assert!(
                sent.contains(r#""input":{}"#) || sent.contains(r#""arguments":"{}""#),
                "{sent}"
            );
        }
    }

    // A deferred tool asks for the native tool search, so a target without one cannot take the request.
    #[test]
    fn deferred_tool_needs_native_tool_search() {
        let tools = [ToolDefinition::new("read", "Read.", "{}").deferred()];
        let blocks = [text(U, "go")];
        for wire in [ALL_WIRES[0], Wire::OpenaiResponses(ResponsesWire::default())] {
            let searching = target_of("m", wire);
            let plain = Target {
                tool_search: false,
                ..searching.clone()
            };
            let request = Request::new(&blocks).tools(&tools);

            let refused = Encoder::new().encode(&plain, request).map(|_| ());
            let accepted = Encoder::new().encode(&searching, request).map(|_| ());

            crate::testing::assert_same(refused, Err(EncodeError::Unsupported));
            crate::testing::assert_same(accepted, Ok(()));
        }
    }

    // `encode_checked` compares each resumed body with a fresh encoding, so each call below is the assertion.
    #[test]
    fn incremental_encode_matches_fresh_after_append_edit_and_marker_move() {
        let rounds: [&[Block]; 9] = [
            &[text(U, "a")],
            &[text(U, "a"), text(A, "b"), text(U, "c")],
            &[text(U, "a"), text(A, "b"), text(U, "c"), text(A, "d"), text(U, "e")],
            &[text(U, "x"), text(A, "b"), text(U, "c"), text(A, "d"), text(U, "e")],
            // The last user text goes, so the marker moves back to an element that a resume would keep.
            &[text(U, "x"), text(A, "b"), text(U, "c"), text(A, "d")],
            &[image("ab"), text(A, "b"), text(U, "c"), text(A, "d"), text(U, "e")],
            // Only the digest changes, so the element must encode again.
            &[image("cd"), text(A, "b"), text(U, "c"), text(A, "d"), text(U, "e")],
            // A changed role merges the elements around it, so the element before the change encodes again.
            &[image("cd"), text(U, "b"), text(U, "c"), text(A, "d"), text(U, "e")],
            // Equal text under the other role is another block, so the element encodes again.
            &[image("cd"), text(U, "b"), text(U, "c"), text(U, "d"), text(U, "e")],
        ];
        for wire in ALL_WIRES {
            let mut encoder = Encoder::new();
            for blocks in rounds {
                let settings = Settings::new().system("s").max_output_tokens(8);
                let request = Request::new(blocks).blobs(&TestBlobs).settings(&settings);
                encode_checked(&mut encoder, "m", wire, request).unwrap();
            }
        }
    }

    // A kept element written for one model would carry its signature to the next, so `encode_checked` checks the
    // switch.
    #[test]
    fn model_change_reencodes_without_reasoning_state() {
        let blocks = [
            text(U, "a"),
            Block::Reasoning(Reasoning {
                text: "t".to_string(),
                replay: Some(replay("m", ReplayKind::AnthropicSignature, "sig")),
            }),
            text(A, "b"),
            text(U, "c"),
        ];
        let mut encoder = Encoder::new();
        for model in ["m", "n", "m"] {
            let wire = Wire::AnthropicMessages(AnthropicWire {
                max_tokens: 8,
                cache: false,
            });
            encode_checked(&mut encoder, model, wire, Request::new(&blocks)).unwrap();
        }
    }

    #[test]
    fn incremental_encode_matches_fresh_after_tools_and_reasoning_changes() {
        let read_tool = [ToolDefinition::new("read", "Read.", "{}")];
        let call = Block::ToolCall(ToolCall::new("c", "read", "{}"));
        let shot =
            Block::ToolResult(ToolResult::success("c", "img").with_media(vec![Media::new(blob("ab"), "image/png")]));
        let unsigned = Block::Reasoning(Reasoning {
            text: "think".to_string(),
            replay: None,
        });
        let rounds: [(&[Block], &[ToolDefinition]); 5] = [
            (&[text(U, "a"), text(A, "b"), text(U, "c")], &[]),
            // An edit in the middle encodes again from the element that holds it.
            (&[text(U, "a"), text(A, "B"), text(U, "c")], &[]),
            // Ordinary tools change the request head, not the retained elements.
            (&[text(U, "a"), text(A, "B"), text(U, "c")], &read_tool),
            // Responses writes no item for reasoning without a signature, and Chat moves tool images into the next
            // user message.
            (
                &[
                    text(U, "a"),
                    unsigned.clone(),
                    call.clone(),
                    shot.clone(),
                    text(U, "what"),
                ],
                &read_tool,
            ),
            (
                &[
                    text(U, "a"),
                    unsigned.clone(),
                    call,
                    shot,
                    text(U, "what"),
                    unsigned,
                    text(A, "it"),
                ],
                &read_tool,
            ),
        ];
        for wire in ALL_WIRES {
            let mut encoder = Encoder::new();
            for (blocks, tools) in rounds {
                encode_checked(
                    &mut encoder,
                    "m",
                    wire,
                    Request::new(blocks).tools(tools).blobs(&TestBlobs),
                )
                .unwrap();
            }
        }
    }

    // A store that copies each blob, as a store on disk does, encodes as one that lends the bytes it keeps.
    #[test]
    fn copying_blob_store_encodes_like_borrowing_store() {
        struct Copied;

        impl BlobStore for Copied {
            fn read(
                &self,
                digest: &crate::Digest,
            ) -> Result<Option<Cow<'_, [u8]>>, Box<dyn std::error::Error + Send + Sync>> {
                Ok(TestBlobs.read(digest)?.map(|bytes| Cow::Owned(bytes.into_owned())))
            }
        }

        let blocks = [image("ab"), image("cd"), text(U, "both")];
        for wire in plain_wires() {
            let target = target_of("m", wire);
            let expected = body(
                &Encoder::new()
                    .encode(&target, Request::new(&blocks).blobs(&TestBlobs))
                    .unwrap(),
            );
            let copied = body(
                &Encoder::new()
                    .encode(&target, Request::new(&blocks).blobs(&Copied))
                    .unwrap(),
            );
            assert_eq!(expected, copied);
        }
    }

    #[test]
    fn retry_after_mid_write_failure_matches_fresh_encode() {
        struct Flaky {
            fail: std::sync::atomic::AtomicBool,
        }

        /// A store error with a field, so the test can prove that the caller gets this exact value back.
        #[derive(Debug)]
        struct Locked {
            code: u32,
        }

        impl fmt::Display for Locked {
            fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
                write!(f, "the store is locked ({})", self.code)
            }
        }

        impl std::error::Error for Locked {}

        impl BlobStore for Flaky {
            fn read(
                &self,
                digest: &crate::Digest,
            ) -> Result<Option<Cow<'_, [u8]>>, Box<dyn std::error::Error + Send + Sync>> {
                if self.fail.swap(false, std::sync::atomic::Ordering::Relaxed) {
                    return Err(Box::new(Locked { code: 5 }));
                }
                TestBlobs.read(digest)
            }
        }

        let blocks = [text(U, "a"), text(A, "b"), image("ab"), text(U, "c")];
        for wire in plain_wires() {
            let flaky = Flaky { fail: true.into() };
            let mut encoder = Encoder::new();
            let request = Request::new(&blocks).blobs(&flaky);
            let digest = blob("ab").digest;
            // A store failure keeps its cause, so the caller can tell it from a missing blob.
            let Err(error) = encoder.encode(&target_of("m", wire), request) else {
                panic!("a failed store read fails the encode");
            };
            assert!(matches!(error, EncodeError::BlobRead { digest: d, .. } if d == digest));
            let source = std::error::Error::source(&error).and_then(|source| source.downcast_ref::<Locked>());
            assert_eq!(source.map(|locked| locked.code), Some(5));
            encode_checked(&mut encoder, "m", wire, request).unwrap();
        }
    }

    // JSON has no NaN or infinity, so the request fails before any byte is written.
    #[test]
    fn non_finite_sampling_value_is_rejected() {
        let blocks = [text(U, "hi")];
        for wire in ALL_WIRES {
            for value in [f64::NAN, f64::INFINITY, f64::NEG_INFINITY] {
                let target = target_of("m", wire);
                let mut encoder = Encoder::new();
                for request in [
                    Request::new(&blocks).settings(&Settings::new().temperature(value)),
                    Request::new(&blocks).settings(&Settings::new().top_p(value)),
                ] {
                    assert!(matches!(
                        encoder.encode(&target, request),
                        Err(EncodeError::InvalidSampling)
                    ));
                }
                encoder
                    .encode(
                        &target,
                        Request::new(&blocks).settings(&Settings::new().temperature(0.5)),
                    )
                    .unwrap();
            }
        }
    }

    // A log line of an encoder or its request must not carry a credential.
    #[test]
    fn debug_output_redacts_credentials() {
        let blocks = [text(U, "hi")];
        let target = Target {
            route: Route {
                credential_header: Some(CredentialHeader::XApiKey),
                ..Route::default()
            },
            credential: Credential::ApiKey("sk-secret".into()),
            ..target_of("m", Wire::OpenaiChat(ChatWire::default()))
        };
        let mut encoder = Encoder::new();
        let encoded = encoder.encode(&target, Request::new(&blocks)).unwrap();
        let text = format!("{encoded:?}");
        assert!(text.contains("x-api-key"), "{text}");
        assert!(!text.contains("sk-secret"), "{text}");
        let text = format!("{encoder:?}");
        assert!(!text.contains("sk-secret"), "{text}");
    }

    // The inputs drop before the encoded request is read, so the borrow checker proves that it borrows none of them.
    #[test]
    fn encoded_request_borrows_no_input() {
        let mut encoder = Encoder::new();
        let encoded = {
            let input = String::from("original input");
            let system = String::from("be brief");
            let model = String::from("m");
            let base_url = String::from("https://a.test/v1");
            let secret = String::from("secret");
            let (name, value) = (String::from("x-test"), String::from("pinned"));
            let blocks = [Block::user_text(&input)];
            let target = Target {
                model: model.into(),
                route: Route {
                    base_url: base_url.into(),
                    credential_header: Some(CredentialHeader::AuthorizationBearer),
                    headers: vec![Header::new(name, value)].into(),
                    ..Route::default()
                },
                credential: Credential::ApiKey(secret.into()),
                wire: Wire::OpenaiChat(ChatWire::default()),
                tool_search: false,
            };
            encoder
                .encode(
                    &target,
                    Request::new(&blocks).settings(&Settings::new().system(&system)),
                )
                .unwrap()
        };
        assert_eq!(encoded.http.url(), "https://a.test/v1/chat/completions");
        assert_eq!(encoded.http.headers()[0].value, "Bearer secret");
        assert_eq!(encoded.http.headers()[1].value, "pinned");
        assert_eq!(
            encoded.origin,
            OriginRef {
                model: "m",
                base_url: "https://a.test/v1"
            }
        );
        let text = String::from_utf8(body(&encoded)).unwrap();
        assert!(text.contains("original input"));
        assert!(text.contains("be brief"));
    }

    #[test]
    fn empty_context_writes_valid_body() {
        for wire in ALL_WIRES {
            let mut encoder = Encoder::new();
            let encoded = encoder
                .encode(
                    &target_of("m", wire),
                    Request::new(&[]).settings(&Settings::new().system("be brief")),
                )
                .unwrap();
            assert!(serde_json::from_slice::<serde_json::Value>(&body(&encoded)).is_ok());
        }
    }
}
