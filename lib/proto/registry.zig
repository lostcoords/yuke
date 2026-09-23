//! The protocol types the generator and the clone checks read, derived from the declarations of the wire modules.

const std = @import("std");
const instructions = @import("instructions.zig");
const activity = @import("activity.zig");
const auth = @import("auth.zig");
const blob = @import("blob.zig");
const catalog = @import("catalog.zig");
const content = @import("content.zig");
const enums = @import("enums.zig");
const initialize = @import("initialize.zig");
const input = @import("input.zig");
const interaction = @import("interaction.zig");
const job = @import("job.zig");
const skill = @import("skill.zig");
const message = @import("message.zig");
const misc = @import("misc.zig");
const rpc = @import("rpc.zig");
const run = @import("run.zig");
const session = @import("session.zig");
const tool = @import("tool.zig");
const view = @import("view.zig");
const ids = @import("ids.zig");

pub const TypeEntry = struct { name: []const u8, ty: type };
pub const AliasEntry = struct { name: []const u8, base: []const u8 };

/// The wire modules in the order the schema lists their types.
const modules = .{ initialize, content, blob, auth, catalog, rpc, activity, input, instructions, interaction, job, skill, message, misc, run, session, tool, view, enums };

pub const structs = collect(.structure);
pub const tagged_unions = collect(.tagged_union);
/// The unions of `rpc.zig` wrap a whole payload, so their arms carry no `type` tag.
pub const envelope_unions = collect(.envelope_union);
pub const string_enums = collect(.string_enum);
/// An enum with a signed tag carries a number on the wire, like `ErrorCode`.
pub const numeric_enums = collect(.numeric_enum);

/// Every identifier type of `ids.zig`, then the broadcast payloads that share one type under two names.
pub const aliases = idAliases() ++ [_]AliasEntry{
    .{ .name = "MessagePartDeltaData", .base = "PartDelta" },
    .{ .name = "ToolOutputDeltaData", .base = "PartDelta" },
};

const Kind = enum { structure, tagged_union, envelope_union, string_enum, numeric_enum };

fn kindOf(comptime module: type, comptime T: type) ?Kind {
    return switch (@typeInfo(T)) {
        // A field of type `type` marks a comptime table, such as `MethodSpec`, which never crosses the wire.
        .@"struct" => |info| for (info.fields) |field| {
            if (field.type == type) break null;
        } else .structure,
        .@"union" => if (module == rpc) .envelope_union else .tagged_union,
        .@"enum" => |info| if (@typeInfo(info.tag_type).int.signedness == .signed) .numeric_enum else .string_enum,
        else => null,
    };
}

fn collect(comptime kind: Kind) []const TypeEntry {
    comptime {
        @setEvalBranchQuota(200_000);
        var out: []const TypeEntry = &.{};
        for (modules) |module| {
            for (@typeInfo(module).@"struct".decls) |decl| {
                const value = @field(module, decl.name);
                if (@TypeOf(value) != type) continue;
                // A re-export names a type another module declares, so only the declaring name counts.
                if (!std.mem.endsWith(u8, @typeName(value), "." ++ decl.name)) continue;
                if (kindOf(module, value) == kind) out = out ++ [_]TypeEntry{.{ .name = decl.name, .ty = value }};
            }
        }
        return out;
    }
}

fn idAliases() []const AliasEntry {
    comptime {
        var out: []const AliasEntry = &.{};
        for (@typeInfo(ids).@"struct".decls) |decl| {
            const value = @field(ids, decl.name);
            if (@TypeOf(value) != type) continue;
            const base = switch (@typeInfo(value)) {
                .int => @typeName(value),
                .pointer => "string",
                .@"struct" => std.fmt.comptimePrint("[{d}]u8", .{@typeInfo(@FieldType(value, "raw")).array.len}),
                else => @compileError("unsupported identifier type " ++ @typeName(value)),
            };
            out = out ++ [_]AliasEntry{.{ .name = decl.name, .base = base }};
        }
        return out;
    }
}
