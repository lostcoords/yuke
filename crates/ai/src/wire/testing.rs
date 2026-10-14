//! Shared helpers for the serializer tests.

use std::borrow::Cow;

use crate::encoder::{EncodeError, Encoder};
use crate::request::{Blob, BlobStore, Block, Origin, ReasoningReplay, ReplayKind, Request, Target, ToolCall, Wire};
use crate::route::{Credential, Route};

/// A target with `model` and `wire`, and no route or credential: an encoder reads neither.
pub(crate) fn target_of(model: &str, wire: Wire) -> Target {
    Target {
        model: model.to_owned().into(),
        route: Route::default(),
        credential: Credential::None,
        // The helper enables the native tool search for each protocol that has one, so a request can defer a tool.
        tool_search: !matches!(wire, Wire::OpenaiChat(_)),
        wire,
    }
}

/// Provider state that `model` produced at the empty test host of [`target_of`].
pub(crate) fn replay(model: &str, kind: ReplayKind, data: &str) -> ReasoningReplay {
    ReasoningReplay {
        origin: Origin {
            model: model.to_owned(),
            base_url: String::new(),
        },
        kind,
        data: data.to_owned(),
    }
}

/// Encode the whole request with a fresh encoder, and join its body.
pub(crate) fn write(model: &str, wire: Wire, request: Request<'_>) -> Result<String, EncodeError> {
    let mut encoder = Encoder::new();
    let encoded = encoder.encode(&target_of(model, wire), request)?;
    Ok(String::from_utf8(encoded.http.body().flatten().copied().collect::<Vec<u8>>()).unwrap())
}

/// Write the whole request, with the test blob store when the request names none.
pub(crate) fn expect_json(expected: &str, model: &str, wire: Wire, request: Request<'_>) {
    let request = request.blobs(request.blobs.unwrap_or(&TestBlobs));
    assert_eq!(write(model, wire, request).unwrap(), expected);
}

pub(crate) fn expect_error(expected: EncodeError, model: &str, wire: Wire, request: Request<'_>) {
    let request = request.blobs(request.blobs.unwrap_or(&TestBlobs));
    crate::testing::assert_same(write(model, wire, request), Err(expected));
}

/// The test store holds these contents. A test blob names one by its bytes.
const STORED: [&str; 3] = ["ab", "cd", "note"];

/// A blob whose digest is its content, so the test store answers it with no table of digests.
pub(crate) fn blob(data: &str) -> Blob {
    Blob {
        digest: digest_of(data.as_bytes()),
        len: data.len(),
    }
}

/// A tool call block.
pub(crate) fn call(call_id: &str, name: &str, arguments: &str) -> Block {
    Block::ToolCall(ToolCall {
        call_id: call_id.into(),
        name: name.into(),
        arguments: arguments.into(),
    })
}

/// The test store. It answers each blob from `STORED`, so it holds no state.
pub(crate) struct TestBlobs;

impl BlobStore for TestBlobs {
    fn read(&self, digest: &crate::Digest) -> Result<Option<Cow<'_, [u8]>>, Box<dyn std::error::Error + Send + Sync>> {
        Ok(STORED
            .iter()
            .find(|data| digest_of(data.as_bytes()) == *digest)
            .map(|data| Cow::Borrowed(data.as_bytes())))
    }
}

fn digest_of(data: &[u8]) -> crate::Digest {
    assert!(data.len() <= 32);
    let mut digest = [0; 32];
    digest[..data.len()].copy_from_slice(data);
    digest
}
