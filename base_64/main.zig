const std = @import("std");
const Base64 = @import("lib.zig").Base64;

const Commands = enum {
    Help,
    Encode,
    Decode,
};

const cmd_name_to_enum = [_]struct { []const u8, Commands, bool }{
    .{ "help", .Help, false },
    .{ "encode", .Encode, true },
    .{ "decode", .Decode, true },
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
    var inpt: []const u8 = undefined;

    var state = ParseState.CmdName;
    while (args.next()) |arg| {
        switch (state) {
            .CmdName => {
                cmd = cmd_resolver: {
                    for (cmd_name_to_enum) |c| {
                        if (std.mem.eql(u8, arg, c.@"0")) {
                            state = if (c.@"2") .Argument else .Terminal;
                            break :cmd_resolver c.@"1";
                        }
                    }
                    return CommandError.UnexpectedCommand;
                };
            },
            .Argument => {
                inpt = arg;
                state = .Terminal;
            },
            .Terminal => return CommandError.UnexpectedArgument,
        }
    }
    switch (state) {
        .CmdName => return CommandError.MissingCommand,
        .Argument => return CommandError.MissingArgument,
        .Terminal => {},
    }

    const io = init.io;
    var stdout_buffer: [1024]u8 = undefined;
    var writer = std.Io.File.stdout().writer(io, &stdout_buffer);
    const stdout = &writer.interface;

    var arena = init.arena;
    const allocator = arena.allocator();

    const b64: Base64 = .init();

    switch (cmd) {
        .Decode => try stdout.print("{s}\n", .{try b64.decodeString(allocator, inpt)}),
        .Encode => try stdout.print("{s}\n", .{try b64.encodeString(allocator, inpt)}),
        .Help => try stdout.print("{s}\n", .{
            \\encode or decode Base64 string
            \\
            \\usage: [ encode | decode ] ARG
        }),
    }
    try stdout.flush();
}
