//! Validated input with native provenance and the exact text for the transcript.

const proto = @import("proto");

content: []const proto.content.ContentPart,
source: ?proto.input.InputSource = null,
skill_name: ?[]const u8 = null,
