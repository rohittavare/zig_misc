const std = @import("std");

const HttpMethod = enum {
    GET,
    POST,

    pub fn from_string(text: []const u8) !HttpMethod {
        return name_to_method.get(text) orelse HttpParseError.UnknownMethod;
    }
};
const name_to_method = std.StaticStringMap(HttpMethod).initComptime(.{
    .{ "GET", .GET },
    .{ "POST", .POST },
});

const HttpParseError = error{
    MissingMethod,
    MissingUri,
    MissingVersion,
    UnknownMethod,
};
const HttpRequest = struct {
    method: HttpMethod,
    uri: []const u8,
    version: []const u8,

    pub fn from_buffer(req: []const u8) !HttpRequest {
        var itr = std.mem.tokenizeAny(u8, req, " \n");
        const meth = try HttpMethod.from_string(itr.next() orelse return HttpParseError.MissingVersion);
        const uri = itr.next() orelse return HttpParseError.MissingUri;
        const version = itr.next() orelse return HttpParseError.MissingVersion;
        return HttpRequest{
            .method = meth,
            .uri = uri,
            .version = version,
        };
    }
};

fn serve_hello_world() []const u8 {
    return
    \\HTTP/1.1 200 OK
    \\Content-Length: 50
    \\Content-Type: text/html
    \\Connection: Closed
    \\
    \\<html><body>
    \\<h1>Hello, World!</h1>
    \\</body></html>
    ;
}
fn serve_404() []const u8 {
    return
    \\HTTP/1.1 404 Not Found
    \\Content-Length: 52
    \\Content-Type: text/html
    \\Connection: Closed
    \\
    \\<html><body>
    \\<h1>File not found!</h1>
    \\</body></html>
    ;
}

const handlers = std.StaticStringMap(*const (fn () []const u8)).initComptime(.{.{ "/", &serve_hello_world }});

const Server = struct {
    pub fn start(_: Server, io: std.Io, port: u16) !void {
        const localhost_addr = "127.0.0.1";
        const addr = try std.Io.net.IpAddress.parse(localhost_addr, port);

        var server = try addr.listen(io, .{ .mode = std.Io.net.Socket.Mode.stream, .protocol = std.Io.net.Protocol.tcp });
        defer server.deinit(io);

        const connection = try server.accept(io);
        defer connection.close(io);

        var buf: [1024]u8 = undefined;
        @memset(&buf, 0);
        var reader = connection.reader(io, &buf);
        const interface = &reader.interface;

        var writer = connection.writer(io, &.{});
        const w_interface = &writer.interface;

        const request = try HttpRequest.from_buffer(try interface.takeDelimiterInclusive('\n'));
        std.debug.print("Received request method: {s} uri: {s} protocol version: {s}\n", .{ @tagName(request.method), request.uri, request.version });
        if (handlers.get(request.uri)) |handler| {
            _ = try w_interface.write(handler());
        } else {
            _ = try w_interface.write(serve_404());
        }
    }
};

pub fn main(init: std.process.Init) !void {
    const server: Server = .{};
    try server.start(init.io, 8000);
}
