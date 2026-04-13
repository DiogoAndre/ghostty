const std = @import("std");
const builtin = @import("builtin");
const Allocator = std.mem.Allocator;

/// Conditionals in Ghostty configuration are based on a static, typed
/// state of the world instead of a dynamic key-value set. This simplifies
/// the implementation, allows for better type checking, and enables a
/// typed C API.
pub const State = struct {
    /// The theme of the underlying OS desktop environment.
    theme: Theme = .light,

    /// The target OS of the current build.
    os: std.Target.Os.Tag = builtin.target.os.tag,

    /// Index into the theme-pool slots list for this surface. Zero
    /// when no pool is active (default).
    theme_slot: u16 = 0,

    pub const Theme = enum { light, dark };

    /// Tests the conditional against the state and returns true if it matches.
    pub fn match(self: State, cond: Conditional) bool {
        switch (cond.key) {
            inline else => |tag| {
                const raw = @field(self, @tagName(tag));
                const FieldType = @TypeOf(raw);

                const value_matches: bool = switch (@typeInfo(FieldType)) {
                    .@"enum" => std.mem.eql(u8, @tagName(raw), cond.value),
                    .int => parsed: {
                        const parsed = std.fmt.parseInt(FieldType, cond.value, 10) catch
                            break :parsed false;
                        break :parsed parsed == raw;
                    },
                    else => @compileError(
                        "unsupported conditional state field type: " ++
                            @typeName(FieldType),
                    ),
                };

                return switch (cond.op) {
                    .eq => value_matches,
                    .ne => !value_matches,
                };
            },
        }
    }
};

/// An enum of the available conditional configuration keys.
pub const Key = key: {
    const stateInfo = @typeInfo(State).@"struct";
    var fields: [stateInfo.fields.len]std.builtin.Type.EnumField = undefined;
    for (stateInfo.fields, 0..) |field, i| fields[i] = .{
        .name = field.name,
        .value = i,
    };

    break :key @Type(.{ .@"enum" = .{
        .tag_type = std.math.IntFittingRange(0, fields.len - 1),
        .fields = &fields,
        .decls = &.{},
        .is_exhaustive = true,
    } });
};

/// A single conditional that can be true or false.
pub const Conditional = struct {
    key: Key,
    op: Op,
    value: []const u8,

    pub const Op = enum { eq, ne };

    pub fn clone(
        self: Conditional,
        alloc: Allocator,
    ) Allocator.Error!Conditional {
        return .{
            .key = self.key,
            .op = self.op,
            .value = try alloc.dupe(u8, self.value),
        };
    }
};

test "conditional enum match" {
    const testing = std.testing;
    const state: State = .{ .theme = .dark };
    try testing.expect(state.match(.{
        .key = .theme,
        .op = .eq,
        .value = "dark",
    }));
    try testing.expect(!state.match(.{
        .key = .theme,
        .op = .ne,
        .value = "dark",
    }));
    try testing.expect(state.match(.{
        .key = .theme,
        .op = .ne,
        .value = "light",
    }));
}

test "conditional theme_slot match" {
    const testing = std.testing;
    const state: State = .{ .theme_slot = 2 };
    try testing.expect(state.match(.{
        .key = .theme_slot,
        .op = .eq,
        .value = "2",
    }));
    try testing.expect(!state.match(.{
        .key = .theme_slot,
        .op = .eq,
        .value = "3",
    }));
    try testing.expect(state.match(.{
        .key = .theme_slot,
        .op = .ne,
        .value = "3",
    }));

    // Default theme_slot is 0 — the "no pool active" sentinel.
    const default_state: State = .{};
    try testing.expect(default_state.match(.{
        .key = .theme_slot,
        .op = .eq,
        .value = "0",
    }));
}
