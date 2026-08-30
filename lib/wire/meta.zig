//! Wire protocol metadata and limits.

const initialize = @import("initialize.zig");

pub const protocol_version = initialize.protocol_version;

pub const limits = struct {
    pub const dead_connection_ms: u64 = 90000;
    pub const default_page_size: u64 = 50;
    pub const default_session_list_page_size: u64 = 25;
    pub const default_fs_browse_page_size: u64 = 100;
    pub const max_activity_retry_message_bytes: u64 = 1024;
    pub const max_agents: u64 = 256;
    pub const max_api_key_bytes: u64 = 65536;
    pub const max_auth_flows: u64 = 8;
    pub const max_auth_providers: u64 = 64;
    pub const max_auth_url_bytes: u64 = 4096;
    pub const max_auth_user_code_bytes: u64 = 128;
    pub const max_blob_bytes: u64 = 67108864;
    pub const max_catalog_models: u64 = 4096;
    pub const max_error_message_bytes: u64 = 4096;
    pub const max_frame_bytes: u64 = 8388608;
    pub const max_input_parts: u64 = 256;
    pub const max_message_parts: u64 = 1024;
    pub const max_message_string_bytes: u64 = 1048576;
    pub const max_page_size: u64 = 500;
    pub const max_permission_creates: u64 = 32;
    pub const max_permission_options: u64 = 32;
    pub const max_permission_reject_message_bytes: u64 = 4096;
    pub const max_permission_rules: u64 = 4096;
    pub const max_profiles: u64 = 256;
    pub const max_queued_inputs: u64 = 128;
    pub const max_reasoning_levels: u64 = 32;
    pub const max_session_list_cursor_bytes: u64 = 256;
    pub const max_session_list_page_size: u64 = 100;
    pub const max_skills: u64 = 1024;
    pub const max_snapshot_configs: u64 = 501;
    pub const max_subscriptions: u64 = 64;
    pub const max_tool_output_stream_bytes: u64 = 1048576;
    pub const max_view_bytes: u64 = 1048576;
    pub const max_view_items: u64 = 1024;
    pub const max_views_per_tool: u64 = 64;
    pub const max_fs_browse_cursor_bytes: u64 = 256;
    pub const max_fs_browse_page_size: u64 = 500;
    pub const max_workspaces: u64 = 1024;
    pub const ping_interval_ms: u64 = 30000;
};

pub const constants = struct {
    pub const MAX_REQUEST_ID: u64 = 9007199254740991;
    pub const MAX_REQUEST_ID_BYTES: u64 = 64;
    pub const MAX_SESSION_REVISION: u64 = 9007199254740991;
    pub const MAX_WIRE_INTEGER: u64 = 9007199254740991;
    pub const PROTOCOL_VERSION: u64 = initialize.protocol_version;
};

pub const string_constants = struct {
    pub const JSONRPC_VERSION = "2.0";
};

pub const close_codes = struct {
    pub const internal_error: u16 = 1011;
    pub const message_too_big: u16 = 1009;
    pub const protocol_error: u16 = 1002;
    pub const send_queue_overflow: u16 = 1013;
    pub const shutting_down: u16 = 1012;
    pub const unsupported_protocol: u16 = 4000;
};
