//! This module exports the yuke wire protocol types.

pub const ids = @import("ids.zig");
pub const tagged = @import("tagged.zig");
pub const initialize = @import("initialize.zig");
pub const meta = @import("meta.zig");
pub const enums = @import("enums.zig");
pub const content = @import("content.zig");
pub const auth = @import("auth.zig");
pub const catalog = @import("catalog.zig");
pub const activity = @import("activity.zig");
pub const input = @import("input.zig");
pub const interaction = @import("interaction.zig");
pub const message = @import("message.zig");
pub const skill = @import("skill.zig");
pub const misc = @import("misc.zig");
pub const run = @import("run.zig");
pub const session = @import("session.zig");
pub const tool = @import("tool.zig");
pub const view = @import("view.zig");
pub const rpc = @import("rpc.zig");
pub const registry = @import("registry.zig");
pub const clone = @import("clone.zig");
pub const dupe = clone.dupe;

test {
    @import("std").testing.refAllDecls(@This());
}
