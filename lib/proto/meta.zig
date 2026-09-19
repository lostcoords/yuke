//! The wire limits the engine enforces. The schema generator publishes them for a client.

const initialize = @import("initialize.zig");

pub const protocol_version = initialize.protocol_version;

pub const limits = struct {
    pub const default_page_size: u64 = 50;
    pub const default_session_list_page_size: u64 = 25;
    pub const max_blob_bytes: u64 = 7 << 20;
    pub const max_input_images: u64 = 8;
    pub const max_message_string_bytes: u64 = 1048576;
    pub const max_page_size: u64 = 500;
    pub const max_queued_inputs: u64 = 128;
    pub const max_reasoning_levels: u64 = 32;
    pub const max_session_list_page_size: u64 = 100;
    pub const max_tool_output_stream_bytes: u64 = 1048576;
};

pub const constants = struct {
    pub const MAX_WIRE_INTEGER: u64 = 9007199254740991;
};
