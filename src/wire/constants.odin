package wire

// Wire protocol version this daemon speaks.
PROTOCOL_VERSION :: 1

// Bounds enforced across the wire protocol.
Limits :: struct {
    // Max WebSocket message size. A larger frame is a protocol error.
    max_frame_bytes:                    int,

    // Decoded inline media above this must use MediaSource.blob.
    max_inline_media_bytes:             int,

    // Max aggregate raw string bytes in one display-only tool view.
    max_view_bytes:                     int,

    // Max accumulated display output streamed for one running tool part.
    max_tool_output_stream_bytes:       int,

    // Max stored bytes in one content-addressed blob.
    max_blob_bytes:                     u64,

    // Max content parts in one accepted input.
    max_input_parts:                    int,

    // Max display views attached to one tool state or input.
    max_views_per_tool:                 int,

    // Max entries in any nested view collection.
    max_view_items:                     int,

    // Max sessions in one subscription set.
    max_subscriptions:                  int,

    // Default window for session.resync / session.history.
    default_page_size:                  int,

    // Max window for session.resync / session.history.
    max_page_size:                      int,

    // Default window for session.list.
    default_session_list_page_size:     int,

    // Max window for session.list.
    max_session_list_page_size:         int,

    // Max bytes in an opaque session.list cursor.
    max_session_list_cursor_bytes:      int,

    // Default number of directories returned by workspace.browse.
    default_workspace_browse_page_size: int,

    // Max directories returned by one workspace.browse page.
    max_workspace_browse_page_size:     int,

    // Max bytes in an opaque workspace.browse cursor.
    max_workspace_browse_cursor_bytes:  int,

    // Default number of jobs returned by cron.list.
    default_cron_list_page_size:        int,

    // Max jobs returned by one cron.list page.
    max_cron_list_page_size:            int,

    // Max bytes in an opaque cron.list cursor.
    max_cron_list_cursor_bytes:         int,

    // Max durable jobs accepted by one local daemon.
    max_cron_jobs:                      int,

    // Max workspaces sent in hello.
    max_workspaces:                     int,

    // Max profiles sent in hello.
    max_profiles:                       int,

    // Max models sent in one catalog snapshot.
    max_catalog_models:                 int,

    // Max reasoning levels carried by one model.
    max_reasoning_levels:               int,

    // Max skipped-provider records in catalog health.
    max_skipped_providers:              int,

    // Max discovered skills returned for one workspace.
    max_skills:                         int,

    // Max remembered permission rules returned for one workspace.
    max_permission_rules:               int,

    // Max options on one permission prompt.
    max_permission_options:             int,

    // Max rule patterns created by one permission option.
    max_permission_creates:             int,

    // Max bytes in ActivityState.retrying.message.
    max_activity_retry_message_bytes:   int,

    // Max accepted inputs waiting behind a run.
    max_queued_inputs:                  int,

    // Max parts in one assistant message, including an active draft.
    max_active_draft_parts:             int,

    // Max run-config records carried by one transcript snapshot.
    max_snapshot_configs:               int,

    // Max aggregate raw string bytes retained by one active draft.
    max_active_draft_string_bytes:      int,

    // Max human-readable request error bytes.
    max_error_message_bytes:            int,

    // Daemon WebSocket ping interval.
    ping_interval_ms:                   u64,

    // Daemon closes a connection that has not answered its pings by this age.
    dead_connection_ms:                 u64,
}

LIMITS :: Limits {
    max_frame_bytes                    = 8 * 1024 * 1024,
    max_inline_media_bytes             = 256 * 1024,
    max_view_bytes                     = 1024 * 1024,
    max_tool_output_stream_bytes       = 1024 * 1024,
    max_blob_bytes                     = 64 * 1024 * 1024,
    max_input_parts                    = 256,
    max_views_per_tool                 = 64,
    max_view_items                     = 1024,
    max_subscriptions                  = 64,
    default_page_size                  = 50,
    max_page_size                      = 500,
    default_session_list_page_size     = 25,
    max_session_list_page_size         = 100,
    max_session_list_cursor_bytes      = 256,
    default_workspace_browse_page_size = 100,
    max_workspace_browse_page_size     = 500,
    max_workspace_browse_cursor_bytes  = 256,
    default_cron_list_page_size        = 25,
    max_cron_list_page_size            = 100,
    max_cron_list_cursor_bytes         = 256,
    max_cron_jobs                      = 1024,
    max_workspaces                     = 1024,
    max_profiles                       = 256,
    max_catalog_models                 = 4096,
    max_reasoning_levels               = 32,
    max_skipped_providers              = 256,
    max_skills                         = 1024,
    max_permission_rules               = 4096,
    max_permission_options             = 32,
    max_permission_creates             = 32,
    max_activity_retry_message_bytes   = 1024,
    max_queued_inputs                  = 128,
    max_active_draft_parts             = 1024,
    max_snapshot_configs               = 501,
    max_active_draft_string_bytes      = 1024 * 1024,
    max_error_message_bytes            = 4096,
    ping_interval_ms                   = 30_000,
    dead_connection_ms                 = 90_000,
}

// Max valid request/response id. JSON numbers must stay within `2^53 - 1`
// (safe integer range) per `specs/protocol.md`.
MAX_REQUEST_ID :: 9007199254740991

// Max value of every integer carried as a JSON number.
MAX_WIRE_INTEGER :: 9007199254740991

// Max daemon-lifetime session-index revision. JSON safe integer range.
MAX_SESSION_REVISION :: 9007199254740991

// Max daemon-lifetime cron-index revision. JSON safe integer range.
MAX_CRON_REVISION :: 9007199254740991

// WebSocket close codes. See protocol.md.
Close_Codes :: struct {
    // Daemon is restarting or going down cleanly.
    shutting_down:        u16,

    // Frame-level protocol violation.
    protocol_error:       u16,

    // Incoming WebSocket message exceeded the protocol cap.
    message_too_big:      u16,

    // Daemon could not complete an operation required by the connection.
    internal_error:       u16,

    // Outbound queue is full; caller should back off.
    send_queue_overflow:  u16,

    // Client offered a `protocol` we do not support.
    unsupported_protocol: u16,
}

CLOSE :: Close_Codes {
    shutting_down        = 1012,
    protocol_error       = 1002,
    message_too_big      = 1009,
    internal_error       = 1011,
    send_queue_overflow  = 1013,
    unsupported_protocol = 1002,
}
