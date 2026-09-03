//! Wire types for the `initialize` request.

/// This build speaks this protocol version. The `initialize` result reports it.
pub const protocol_version: u32 = 1;

/// This type identifies the client connection.
pub const Client = struct {
    /// The client connection name.
    name: []const u8,
    /// The client build version.
    version: []const u8,
};
