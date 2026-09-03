const std = @import("std");
const Base64 = @import("lib.zig").Base64;

const Commands = enum {
    Help,
    Encode,
    Decode,
};

const ParseState = enum {
    CmdName,
    Argument,
    Terminal,
};

const CommandError = error{
    MissingArgument,
    MissingCommand,
    UnexpectedArgument,
    UnexpectedCommand,
};

pub fn main(init: std.process.Init) !void {
    var args = init.minimal.args.iterate();
    _ = args.next();

    var cmd: Commands = undefined;
    var arg: []const u8 = undefined;
    foo: switch (ParseState.CmdName) {
        .CmdName => {
            const cmd_name = args.next() orelse return CommandError.MissingCommand;
            if (std.mem.eql(u8, cmd_name, "help")) {
                cmd = .Help;
                continue :foo .Terminal;
            } else if (std.mem.eql(u8, cmd_name, "encode")) {
                cmd = .Encode;
                continue :foo .Argument;
            } else if (std.mem.eql(u8, cmd_name, "decode")) {
                cmd = .Decode;
                continue :foo .Argument;
            } else {
                return CommandError.UnexpectedCommand;
            }
        },
        .Argument => {
            arg = args.next() orelse return CommandError.MissingArgument;
            continue :foo .Terminal;
        },
        .Terminal => if (args.next() != null) return CommandError.UnexpectedArgument,
    }

    const io = init.io;
    var stdout_buffer: [1024]u8 = undefined;
    var writer = std.Io.File.stdout().writer(io, &stdout_buffer);
    const stdout = &writer.interface;

    var arena = init.arena;
    const allocator = arena.allocator();

    const b64: Base64 = .init();

    switch (cmd) {
        .Decode => try stdout.print("{s}\n", .{try b64.decodeString(allocator, arg)}),
        .Encode => try stdout.print("{s}\n", .{try b64.encodeString(allocator, arg)}),
        .Help => try stdout.print("{s}\n", .{
            \\encode or decode Base64 string
            \\
            \\usage: [ encode | decode ] ARG
        }),
    }
    try stdout.flush();
}
