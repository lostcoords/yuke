package wire

// 16 lowercase hex chars. Doubles as an on-disk directory name. @fixed 16
Session_Id :: distinct [16]u8

// 16 lowercase hex chars. Doubles as an on-disk directory name. @fixed 16
Workspace_Id :: distinct [16]u8

// 16 lowercase hex chars. Doubles as an on-disk record name. @fixed 16
Job_Id :: distinct [16]u8

// 16 lowercase hex chars. Identifies one remembered permission rule. @fixed 16
Rule_Id :: distinct [16]u8

// Client-generated request/response correlation id. JSON number, never a string.
Request_Id :: distinct u64

// Session-scoped, daemon-minted, strictly increasing, never reused.
Message_Id :: distinct u64

// Session-scoped, daemon-minted, strictly increasing, never reused.
Run_Id :: distinct u64

// Session-scoped, daemon-minted, strictly increasing, never reused.
Input_Id :: distinct u64

// Part ordinal in message.content[], from 0. JSON number on the wire, like the
// other session-scoped ids.
Part_Id :: distinct u64

// Per-session monotonic sequence number on durable broadcasts.
Seq :: distinct u64

// Monotonic compact-session-index revision within one daemon lifetime.
Session_Revision :: distinct u64

// Monotonic cron-index revision within one daemon lifetime.
Cron_Revision :: distinct u64

// Monotonic run-config revision within a session.
Config_Rev :: distinct u64
