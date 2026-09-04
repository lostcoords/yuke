//! The closed vocabularies the serializers and the routes share, without the generated table.
//! The catalog generator imports this rather than `ai.zig`, so a missing table cannot block a rebuild.

pub const types = @import("types.zig");
pub const ir = @import("request/ir.zig");
pub const model = @import("model.zig");
pub const instance = @import("instance/instance.zig");
