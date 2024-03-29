const std = @import("std");
const mem = std.mem;
const testing = std.testing;
const build_options = @import("build_options");
const amqp = @import("zamqp");
const server = @import("server.zig");

var logOut: enum { syslog, stderr } = .syslog;

// override the std implementation
pub fn log(
    comptime level: std.log.Level,
    comptime scope: @TypeOf(.EnumLiteral),
    comptime format: []const u8,
    args: anytype,
) void {
    const scope_prefix = if (scope == .default) "" else "(" ++ @tagName(scope) ++ "): ";

    switch (logOut) {
        .syslog => {
            var buf: [4096]u8 = undefined;
            const printed = std.fmt.bufPrintZ(&buf, scope_prefix ++ format, args) catch blk: {
                buf[buf.len - 1] = 0;
                break :blk buf[0 .. buf.len - 1 :0];
            };

            std.c.syslog(@enumToInt(level), "%s", printed.ptr);
        },
        .stderr => {
            const level_prefix = "[" ++ @tagName(level) ++ "] ";
            std.debug.print(level_prefix ++ scope_prefix ++ format ++ "\n", args);
        },
    }
}

fn fatal(comptime fmt: []const u8, args: anytype) noreturn {
    std.debug.print("ERROR: " ++ fmt ++ "\n", args);
    std.os.exit(1);
}

// percent decodes the query in-place
const UriQueryIterator = struct {
    query: [:0]u8,
    pos: usize = 0,

    pub const Param = struct {
        name: [:0]const u8,
        value: ?[:0]const u8,
    };

    pub fn next(self: *UriQueryIterator) !?Param {
        if (self.pos >= self.query.len) return null;

        const start_pos = self.pos;
        var write_pos = self.pos;

        var param = Param{
            .name = undefined,
            .value = null,
        };

        if (self.query[self.pos] == '=' or self.query[self.pos] == '&') return error.BadUri;
        self.query[write_pos] = try self.eatChar();
        write_pos += 1;

        while (true) {
            if (self.pos >= self.query.len or self.query[self.pos] == '&') {
                param.name = finishWord(self, start_pos, write_pos);
                return param;
            } else if (self.query[self.pos] == '=') {
                param.name = finishWord(self, start_pos, write_pos);
                write_pos += 1;
                break;
            } else {
                self.query[write_pos] = try self.eatChar();
                write_pos += 1;
            }
        }

        while (true) {
            if (self.pos >= self.query.len or self.query[self.pos] == '&') {
                param.value = finishWord(self, start_pos + param.name.len + 1, write_pos);
                return param;
            } else {
                self.query[write_pos] = try self.eatChar();
                write_pos += 1;
            }
        }
    }

    fn eatChar(self: *UriQueryIterator) !u8 {
        switch (self.query[self.pos]) {
            '%' => {
                if (self.pos + 3 > self.query.len) return error.BadUri;
                const char = std.fmt.parseUnsigned(u8, self.query[self.pos + 1 .. self.pos + 3], 16) catch return error.BadUri;
                self.pos += 3;
                return if (char != 0) char else error.BadUri;
            },
            0 => {
                return error.BadUri;
            },
            else => |char| {
                self.pos += 1;
                return char;
            },
        }
    }

    fn finishWord(self: *UriQueryIterator, start: usize, end: usize) [:0]const u8 {
        self.pos += 1;
        self.query[end] = 0;
        return self.query[start..end :0];
    }
};

test "UriQueryIterator" {
    {
        var query = "asd&qwe=zxc&%3D=%26&a=".*;
        var it = UriQueryIterator{ .query = &query };

        {
            const p = (try it.next()).?;
            try testing.expectEqualStrings("asd", p.name);
            try testing.expectEqual(@as(?[:0]const u8, null), p.value);
        }
        {
            const p = (try it.next()).?;
            try testing.expectEqualStrings("qwe", p.name);
            try testing.expectEqualStrings("zxc", p.value.?);
        }
        {
            const p = (try it.next()).?;
            try testing.expectEqualStrings("=", p.name);
            try testing.expectEqualStrings("&", p.value.?);
        }
        {
            const p = (try it.next()).?;
            try testing.expectEqualStrings("a", p.name);
            try testing.expectEqualStrings("", p.value.?);
        }

        try testing.expectEqual(@as(?UriQueryIterator.Param, null), try it.next());
    }
    {
        var query = "".*;
        var it = UriQueryIterator{ .query = &query };
        try testing.expectEqual(@as(?UriQueryIterator.Param, null), try it.next());
    }
    {
        var query = "asd\x00asd".*;
        var it = UriQueryIterator{ .query = &query };
        try testing.expectError(error.BadUri, it.next());
    }
    {
        var query = "asd%00asd".*;
        var it = UriQueryIterator{ .query = &query };
        try testing.expectError(error.BadUri, it.next());
    }
    {
        var query = "asd%n0asd".*;
        var it = UriQueryIterator{ .query = &query };
        try testing.expectError(error.BadUri, it.next());
    }
    {
        var query = "asd%0".*;
        var it = UriQueryIterator{ .query = &query };
        try testing.expectError(error.BadUri, it.next());
    }
    {
        var query = "=asd".*;
        var it = UriQueryIterator{ .query = &query };
        try testing.expectError(error.BadUri, it.next());
    }
    {
        var query = "&asd".*;
        var it = UriQueryIterator{ .query = &query };
        try testing.expectError(error.BadUri, it.next());
    }
}

const ArgIterator = struct {
    uriIterator: ?UriQueryIterator = null,
    cmdLineIterator: std.process.ArgIterator,
    name: [:0]const u8 = undefined,
    val: ?[:0]const u8 = undefined,

    pub fn next(self: *ArgIterator) ?enum { opt, uri } {
        if (self.uriIterator) |*uriIterator| {
            if (uriIterator.next() catch fatal("ill-formed URI", .{})) |param| {
                self.name = param.name;
                self.val = param.value;
                return .opt;
            } else {
                self.uriIterator = null;
            }
        }
        if (self.cmdLineIterator.nextPosix()) |arg| {
            if (mem.eql(u8, arg, "--uri-env")) {
                const env_name = self.value([:0]const u8);
                self.name = mem.span(std.c.getenv(env_name) orelse fatal("no URI environment variable '{s}'", .{env_name}));
                self.val = null;
                return .uri;
            }
            if (mem.startsWith(u8, arg, "--")) {
                self.name = arg;
                self.val = null;
                return .opt;
            } else {
                self.name = arg;
                self.val = null;
                return .uri;
            }
        }
        return null;
    }

    fn value(self: *ArgIterator, comptime T: type) T {
        const val = (self.val orelse blk: {
            if (self.uriIterator != null) fatal("missing argument for URI option {s}", .{self.name});
            self.val = self.cmdLineIterator.nextPosix() orelse fatal("missing argument for option {s}", .{self.name});
            break :blk self.val;
        }).?;

        if (T == [:0]const u8) {
            return val;
        }
        if (@typeInfo(T) == .Int) {
            return std.fmt.parseInt(T, val, 10) catch |err| switch (err) {
                error.InvalidCharacter => fatal("argument for option {s} must be an integer", .{self.name}),
                error.Overflow => fatal("argument for option {s} must be between {d} and {d}", .{ self.name, std.math.minInt(T), std.math.maxInt(T) }),
            };
        }
        if (@typeInfo(T) == .Enum) {
            return std.meta.stringToEnum(T, val) orelse fatal("invalid argument for option {s}", .{self.name});
        }

        if (@typeInfo(T) == .Bool) {
            return (std.meta.stringToEnum(enum { @"true", @"false" }, val) orelse fatal("invalid argument for option {s}", .{self.name})) == .@"true";
        }

        @compileError("unimplemented type");
    }

    pub fn get(self: *ArgIterator, name: []const u8, comptime T: type) if (T == void) bool else ?T {
        const matches = if (self.uriIterator != null)
            mem.eql(u8, name, self.name)
        else
            mem.startsWith(u8, self.name, "--") and mem.eql(u8, self.name[2..], name);

        if (T == void)
            return matches
        else
            return if (matches) self.value(T) else null;
    }
};

pub fn main() !void {
    const alloc = std.heap.c_allocator;

    var args = ArgIterator{ .cmdLineIterator = std.process.args() };
    var uri: ?[:0]u8 = null;

    var port: ?c_int = null;
    var host: [*:0]const u8 = "localhost";
    var vhost: [*:0]const u8 = "/";
    var user: [*:0]const u8 = "guest";
    var password: [*:0]const u8 = "guest";
    var heartbeat: c_int = 60;

    var tls = true;
    var ca_cert_file: ?[*:0]const u8 = null;
    var cert_file: ?[*:0]const u8 = null;
    var key_file: ?[*:0]const u8 = null;
    var verify_peer: ?bool = null;
    var fail_if_no_peer_cert: ?bool = null;
    var verify_hostname: ?bool = null;

    var chan_settings = server.ChannelSettings{
        .queue = "zone2json",
        .prefetch_count = 10,
        .max_batch = 10,
    };

    const str = [:0]const u8;

    _ = args.next(); // skip exe path

    while (args.next()) |arg_type| {
        if (arg_type == .uri) {
            if (uri != null) fatal("multiple URIs specified", .{});

            uri = try alloc.dupeZ(u8, args.name);
            if (mem.indexOfScalar(u8, uri.?, '?')) |index| {
                uri.?[index] = 0;
                args.uriIterator = UriQueryIterator{ .query = uri.?[index + 1 ..] };
            }
            const uri_params = amqp.parse_url(uri.?) catch fatal("ill-formed URI", .{});
            host = uri_params.host;
            port = uri_params.port;
            vhost = uri_params.vhost;
            user = uri_params.user;
            password = uri_params.password;
            tls = uri_params.ssl != 0;
        } else if (args.get("log", @TypeOf(logOut))) |val| {
            logOut = val;
        } else if (args.get("host", str)) |val| {
            host = val;
        } else if (args.get("port", c_int)) |val| {
            port = val;
        } else if (args.get("vhost", str)) |val| {
            vhost = val;
        } else if (args.get("user", str)) |val| {
            user = val;
        } else if (args.get("password", str)) |val| {
            password = val;
        } else if (args.get("cacertfile", str)) |val| {
            ca_cert_file = val;
        } else if (args.get("certfile", str)) |val| {
            cert_file = val;
        } else if (args.get("keyfile", str)) |val| {
            key_file = val;
        } else if (args.get("verify", enum { verify_peer, verify_none })) |val| {
            verify_peer = val == .verify_peer;
        } else if (args.get("fail_if_no_peer_cert", bool)) |val| {
            fail_if_no_peer_cert = val;
        } else if (args.get("verify_hostname", bool)) |val| {
            verify_hostname = val;
        } else if (args.get("heartbeat", c_int)) |val| {
            heartbeat = val;
        } else if (args.get("queue", str)) |val| {
            chan_settings.queue = val;
        } else if (args.get("prefetch-count", u16)) |val| {
            chan_settings.prefetch_count = val;
        } else if (args.get("batch", u16)) |val| {
            chan_settings.max_batch = if (val == 0) 1 else val;
        } else if (args.get("no-tls", void)) {
            tls = false;
        } else if (args.get("help", void)) {
            try help();
            std.os.exit(0);
        } else if (args.get("version", void)) {
            try std.io.getStdOut().writeAll(build_options.version ++ "\n");
            std.os.exit(0);
        } else {
            fatal("unknown option: {s}", .{args.name});
        }
    }

    if (tls and ca_cert_file == null)
        fatal("specify a trusted root certificates file with cacertfile or disable TLS", .{});

    if (!tls and (ca_cert_file != null or cert_file != null or key_file != null or verify_peer != null or fail_if_no_peer_cert != null or verify_hostname != null))
        fatal("TLS disabled, but TLS options specified", .{});

    if ((cert_file != null) != (key_file != null))
        fatal("both certfile and keyfile need to be specified or none at all", .{});

    if ((verify_peer orelse true) != (fail_if_no_peer_cert orelse true))
        fatal("if fail_if_no_peer_cert is specified, it must be true when verify=verify_peer and false when verify=verify_none", .{});

    try server.run(alloc, .{
        .port = port orelse if (tls) @as(c_int, 5671) else 5672,
        .host = host,
        .vhost = vhost,
        .auth = .{ .plain = .{ .username = user, .password = password } },
        .heartbeat = heartbeat,
        .tls = if (tls) .{
            .ca_cert_path = ca_cert_file.?,
            .keys = if (cert_file != null) .{
                .cert_path = cert_file.?,
                .key_path = key_file.?,
            } else null,
            .verify_peer = verify_peer orelse true,
            .verify_hostname = verify_hostname orelse true,
        } else null,
    }, chan_settings);
}

fn help() !void {
    try std.io.getStdOut().writeAll(
        \\Usage: zone2json-server [OPTIONS] [URI]
        \\An AMQP RPC server that converts DNS zones to JSON
        \\
        \\Options can also be passed in as URI query parameters (without "--").
        \\
        \\URI options:
        \\  --uri-env VAR_NAME      Read URI from an environment variable.
        \\Connection options:
        \\  --host name             default: localhost
        \\  --port number           default: 5671 (with TLS) / 5672 (without TLS)
        \\  --vhost name            default: /
        \\  --user name             default: guest
        \\  --password password     default: guest
        \\  --heartbeat seconds     default: 60 (0 to disable)
        \\TLS options:
        \\  --cacertfile path       trusted root certificates file
        \\  --certfile path         certificate file
        \\  --keyfile path          private key file
        \\  --verify (verify_peer|verify_none)
        \\      peer verification (default: verify_peer)
        \\  --fail_if_no_peer_cert (true|false)
        \\      Exists for compatibility. If set, must be true when verify=verify_peer and false when verify=verify_none.
        \\  --verify_hostname (true|false)
        \\      hostname verification (default: true)
        \\  --no-tls                  disable TLS
        \\Channel options:
        \\  --queue name            default: zone2json
        \\  --prefetch-count count  default: 10 (0 means unlimited)
        \\  --batch count           Acknowledge in batches of size count (default: 10)
        \\                          (sooner if there are no messages to process)
        \\Other options:
        \\  --log (syslog|stderr)   log output (default: syslog)
        \\  --help                  display help and exit
        \\
    );
}
