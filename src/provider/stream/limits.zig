//! Provider stream limits that follow the protocol message bounds.

const proto = @import("proto");

pub const max_blocks: usize = @intCast(proto.meta.limits.max_message_parts);
pub const max_message_bytes: usize = @intCast(proto.meta.limits.max_message_string_bytes);
