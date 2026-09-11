//! Wire protocol metadata and limits.

const initialize = @import("initialize.zig");

pub const protocol_version = initialize.protocol_version;

pub const limits = struct {
    pub const default_page_size: u64 = 50;
    pub const default_session_list_page_size: u64 = 25;
    pub const max_activity_retry_message_bytes: u64 = 1024;
    pub const max_api_key_bytes: u64 = 65536;
    pub const max_auth_providers: u64 = 64;
    pub const max_auth_user_code_bytes: u64 = 128;
    pub const max_blob_bytes: u64 = 7 << 20;
    pub const max_catalog_models: u64 = 4096;
    pub const max_error_message_bytes: u64 = 4096;
    pub const max_input_images: u64 = 8;
    pub const max_input_parts: u64 = 256;
    pub const max_message_parts: u64 = 1024;
    pub const max_message_string_bytes: u64 = 1048576;
    pub const max_page_size: u64 = 500;
    pub const max_queued_inputs: u64 = 128;
    pub const max_reasoning_levels: u64 = 32;
    pub const max_session_list_cursor_bytes: u64 = 256;
    pub const max_session_list_page_size: u64 = 100;
    pub const max_snapshot_configs: u64 = 501;
    pub const max_tool_output_stream_bytes: u64 = 1048576;
    pub const max_view_bytes: u64 = 1048576;
    pub const max_view_items: u64 = 1024;
    pub const max_views_per_tool: u64 = 64;
};

pub const constants = struct {
    pub const MAX_REQUEST_ID_BYTES: u64 = 64;
    pub const MAX_SESSION_REVISION: u64 = 9007199254740991;
    pub const MAX_WIRE_INTEGER: u64 = 9007199254740991;
    pub const PROTOCOL_VERSION: u64 = initialize.protocol_version;
};
