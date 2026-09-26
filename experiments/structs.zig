const std = @import("std");

const specify_at_init_time = struct {
    a: u8,
    b: u8 = 1,
};

const specify_anytime = struct {
    a: ?u8 = null,
    b: u8 = 1,
};

// by setting a default `undefined` value on fields
// we can initialize fields after-the-fact without a proper default
// however, tuple types do not support default values
test "struct1" {
    const a: specify_at_init_time = specify_at_init_time{ .a = 0 };
    try std.testing.expectEqual(1, a.b);

    var b: specify_anytime = specify_anytime{};
    try std.testing.expectEqual(1, b.b);
    b.a = 0;
    try std.testing.expectEqual(0, b.a.?);

    // however, when declaring the struct as `undefined`
    // you cannot rely on default field values
    const c: specify_anytime = undefined;
    try std.testing.expectError(error.TestExpectedEqual, std.testing.expectEqual(1, c.b));
}

fn parseToken(comptime t: type, token: []const u8) !t {
    switch (@typeInfo(t)) {
        .optional => |o| return try parseToken(o.child, token),
        .int => return try std.fmt.parseInt(t, token, 10),
        .float => return try std.fmt.parseFloat(t, token),
        .bool => {
            if (std.mem.eql(u8, token, "true")) return true;
            if (std.mem.eql(u8, token, "false")) return false;
            @panic("unrecognized boolean value");
        },
        .pointer => |p| {
            // currently only support strings through slice of const u8
            if (p.size == .slice and p.attrs.@"const" and p.child == u8) return token;
        },
        else => {},
    }
    @panic("unsupported type: " ++ @typeName(t));
}

fn isSupportedType(comptime t: type) void {
    switch (@typeInfo(t)) {
        .optional => |o| return isSupportedType(o.child),
        .int, .float, .bool => return,
        .pointer => |p| {
            if (p.size == .slice and p.attrs.@"const" and p.child == u8) return;
        },
        else => {},
    }
    @compileError("unsupported type " ++ @typeName(t));
}

const EmptyTuple: Tuple(struct {}) = .{ .defaults = .{} };

/// A custom 'tuple' implementation which supports default values
/// hydrates the tuple from a string input
/// support only basic data types e.g. bool, int, float, string
fn Tuple(comptime t: type) type {
    return struct {
        defaults: T,

        const T = t;
        const N = std.meta.fieldTypes(T).len;
        const Self = @This();

        inline fn nextType(comptime next_field_t: type, comptime next_field_d: ?next_field_t) type {
            return @Tuple(&(std.meta.fieldTypes(T).* ++ [1]type{if (next_field_d != null) next_field_t else ?next_field_t}));
        }

        inline fn addField(comptime self: Self, comptime field_t: type) Tuple(nextType(field_t, null)) {
            return self.addFieldWithDefault(field_t, null);
        }

        inline fn addFieldWithDefault(comptime self: Self, comptime field_t: type, comptime default: ?field_t) Tuple(nextType(field_t, default)) {
            comptime {
                isSupportedType(field_t);
                const next_t = nextType(field_t, default);
                const next_field_ts = @typeInfo(next_t).@"struct".field_types;
                const next_field_ns = @typeInfo(next_t).@"struct".field_names;
                var ret: Tuple(next_t) = undefined;
                for (@typeInfo(T).@"struct".field_names, next_field_ns[0..N], next_field_ts[0..N]) |old_field_n, new_field_n, new_field_t| {
                    @field(ret.defaults, new_field_n) = @as(new_field_t, @field(self.defaults, old_field_n));
                }
                @field(ret.defaults, next_field_ns[N]) = @as(next_field_ts[N], default orelse null);
                return ret;
            }
        }

        fn fromString(comptime self: Self, input: []const u8) !T {
            var ret: T = undefined;

            var itr = std.mem.tokenizeScalar(u8, input, ' ');
            inline for (@typeInfo(T).@"struct".field_names, @typeInfo(T).@"struct".field_types) |field_n, field_t| {
                @field(ret, field_n) = field_v: {
                    if (itr.next()) |token| {
                        break :field_v try parseToken(field_t, token);
                    } else {
                        break :field_v @field(self.defaults, field_n);
                    }
                };
            }
            return ret;
        }
    };
}

const tup = EmptyTuple.addField(bool).addField(i32).addFieldWithDefault([]const u8, "hello world").addFieldWithDefault(bool, false);

test "tuple_with_defaults" {
    // fields without defaults appear as null
    // fields with defaults are not null
    const a = try tup.fromString("");
    if (a.@"0") |_| unreachable;
    if (a.@"1") |_| unreachable;
    try std.testing.expectEqualStrings(a.@"2", "hello world");
    try std.testing.expectEqual(a.@"3", false);

    // partially filled tuple
    const b = try tup.fromString("true 25");
    try std.testing.expectEqual(b.@"0".?, true);
    try std.testing.expectEqual(b.@"1".?, 25);
    try std.testing.expectEqualStrings(b.@"2", "hello world");
    try std.testing.expectEqual(b.@"3", false);

    // fully filled tuple
    const c = try tup.fromString("false -5 bye_world true");
    try std.testing.expectEqual(c.@"0".?, false);
    try std.testing.expectEqual(c.@"1".?, -5);
    try std.testing.expectEqualStrings(c.@"2", "bye_world");
    try std.testing.expectEqual(c.@"3", true);
}
