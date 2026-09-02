const std = @import("std");

const Base64EncodeError = error{
    InvalidEncodeByte,
};
const Base64DecodeError = error{
    InvalidDecodeByte,
    InvalidCyphertext,
};

const Base64 = struct {
    _mapping: *const [64]u8,

    fn init() Base64 {
        const upper = "ABCDEFGHIJKLMNOPQRSTUVWXYZ";
        const lower = "abcdefghijklmnopqrstubwxyz";
        const sym = "0123456789+/";
        const mapping = upper ++ lower ++ sym;

        return Base64{ ._mapping = mapping };
    }

    fn encodeByte(self: Base64, c: u8) Base64EncodeError!u8 {
        return if (c < 64) self._mapping[c] else Base64EncodeError.InvalidEncodeByte;
    }

    fn decodeByte(_: Base64, c: u8) Base64DecodeError!?u8 {
        return switch (c) {
            'A'...'Z' => (c - 'A'),
            'a'...'z' => (c - 'a') + 26,
            '0'...'9' => (c - '0') + 52,
            '+' => 62,
            '/' => 63,
            '=' => null,
            else => Base64DecodeError.InvalidDecodeByte,
        };
    }

    fn encodeString(self: Base64, allocator: std.mem.Allocator, plaintext: []const u8) ![]u8 {
        const u6_mask = 0b111111;
        const ciphertext_len = try std.math.divCeil(usize, plaintext.len, 3) * 4;
        var ciphertext = try allocator.alloc(u8, ciphertext_len);
        errdefer allocator.free(ciphertext);
        @memset(ciphertext, 0);

        var j: usize = undefined;
        for (plaintext, 0..) |c, i| {
            switch (i % 3) {
                0 => {
                    j = i / 3 * 4;
                    ciphertext[j] = c >> 2;
                    ciphertext[j + 1] = c << 4;
                },
                1 => {
                    ciphertext[j + 1] |= c >> 4;
                    ciphertext[j + 2] = c << 2;
                },
                2 => {
                    ciphertext[j + 2] |= c >> 6;
                    ciphertext[j + 3] = c;
                },
                else => unreachable,
            }
        }
        for (0..ciphertext_len) |i| {
            ciphertext[i] = try self.encodeByte(u6_mask & ciphertext[i]);
        }
        // encode the padding character (=)
        switch (plaintext.len % 3) {
            1 => {
                ciphertext[ciphertext_len - 2] = '=';
                ciphertext[ciphertext_len - 1] = '=';
            },
            2 => {
                ciphertext[ciphertext_len - 1] = '=';
            },
            else => {},
        }
        return ciphertext;
    }

    fn decodeString(self: Base64, allocator: std.mem.Allocator, ciphertext: []const u8) ![]u8 {
        const plaintext_len = p_len: {
            var pl = ciphertext.len / 4 * 3;
            if (ciphertext.len % 4 > 0) return Base64DecodeError.InvalidCyphertext;
            if (ciphertext[ciphertext.len - 2] == '=') pl -= 1;
            if (ciphertext[ciphertext.len - 1] == '=') pl -= 1;
            break :p_len pl;
        };
        var plaintext = try allocator.alloc(u8, plaintext_len);
        errdefer allocator.free(plaintext);
        @memset(plaintext, 0);

        var j: usize = undefined;
        var holdover: u8 = undefined;
        for (ciphertext, 0..) |c, i| {
            const b = try self.decodeByte(c) orelse continue;
            switch (i % 4) {
                0 => {
                    j = i / 4 * 3;
                    holdover = b << 2;
                },
                1 => {
                    plaintext[j] = holdover | (b >> 4);
                    holdover = b << 4;
                },
                2 => {
                    plaintext[j + 1] = holdover | (b >> 2);
                    holdover = b << 6;
                },
                3 => plaintext[j + 2] = holdover | b,
                else => unreachable,
            }
        }
        return plaintext;
    }
};

test "base_64_byte_decode" {
    const b64 = Base64.init();

    // upper case letters
    try std.testing.expectEqual(0, try b64.decodeByte('A'));
    try std.testing.expectEqual(20, try b64.decodeByte('U'));

    // lower case lettEqualers
    try std.testing.expectEqual(26, try b64.decodeByte('a'));
    try std.testing.expectEqual(46, try b64.decodeByte('u'));

    // number and symbEqualols
    try std.testing.expectEqual(52, try b64.decodeByte('0'));
    try std.testing.expectEqual(61, try b64.decodeByte('9'));
    try std.testing.expectEqual(62, try b64.decodeByte('+'));
    try std.testing.expectEqual(63, try b64.decodeByte('/'));

    // errors
    try std.testing.expectError(Base64DecodeError.InvalidDecodeByte, b64.decodeByte(0));
    try std.testing.expectError(Base64DecodeError.InvalidDecodeByte, b64.decodeByte('-'));
}

test "base_64_byte_encode" {
    const b64 = Base64.init();

    // valid bytes
    try std.testing.expectEqual('B', try b64.encodeByte(1));
    try std.testing.expectEqual('b', try b64.encodeByte(27));
    try std.testing.expectEqual('5', try b64.encodeByte(57));
    try std.testing.expectEqual('+', try b64.encodeByte(62));
    try std.testing.expectEqual('/', try b64.encodeByte(63));

    // errors
    try std.testing.expectError(Base64EncodeError.InvalidEncodeByte, b64.encodeByte(65));
}

test "base_64_encode" {
    const b64 = Base64.init();

    const allocator = std.testing.allocator;

    // expect = for string with len%3 == 2
    // and == for string with len%3 == 1
    const hi = try b64.encodeString(allocator, "Hi");
    defer allocator.free(hi);
    const h = try b64.encodeString(allocator, "H");
    defer allocator.free(h);
    try std.testing.expectStringEndsWith(hi, "=");
    try std.testing.expectStringEndsWith(h, "==");

    const zero = try b64.encodeString(allocator, "0");
    defer allocator.free(zero);
    const hello_world = try b64.encodeString(allocator, "hello world");
    defer allocator.free(hello_world);
    try std.testing.expectEqualStrings("MA==", zero);
    try std.testing.expectEqualStrings("aGVsbG8gd29ybGQ=", hello_world);
}

test "base_64_decode" {
    const b64 = Base64.init();

    const allocator = std.testing.allocator;

    const zero = try b64.decodeString(allocator, "MA==");
    defer allocator.free(zero);
    const hello_world = try b64.decodeString(allocator, "aGVsbG8gd29ybGQ=");
    defer allocator.free(hello_world);
    try std.testing.expectEqualStrings("0", zero);
    try std.testing.expectEqualStrings("hello world", hello_world);

    try std.testing.expectError(Base64DecodeError.InvalidCyphertext, b64.decodeString(allocator, "invalid"));
}

pub fn main() !void {}
