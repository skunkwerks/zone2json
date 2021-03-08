const std = @import("std");
const amqp = @import("zamqp");
const zone2json = @import("zone2json.zig");
const bytes = amqp.bytes_t.init;

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

fn logOrPanic(err: anyerror) void {
    std.log.err("{}", .{err});
    switch (err) {
        error.OutOfMemory => {
            // librabbitmq docs say it is not designed to handle OOM
            std.debug.panic("out of memory", .{});
        },
        error.Unexpected => std.debug.panic("unexpected error", .{}),
        else => {},
    }
}

const ChannelState = struct {
    unacked_count: u16 = 0,
    last_delivery_tag: u64 = 0,
};

fn listen(alloc: *std.mem.Allocator, channel: amqp.Channel, state: *ChannelState, settings: ChannelSettings) !void {
    channel.maybe_release_buffers();

    var zero_timeval = std.c.timeval{ .tv_sec = 0, .tv_usec = 0 };

    const block = state.unacked_count == 0;
    var timeout = if (block) null else &zero_timeval;

    var envelope = channel.connection.consume_message(timeout, 0) catch |err| switch (err) {
        // a different frame needs to be read
        error.UnexpectedState => {
            const frame = try channel.connection.simple_wait_frame(null);
            if (frame.frame_type == .METHOD) {
                switch (frame.payload.method.id) {
                    .CHANNEL_CLOSE => return error.ChannelClosed,
                    .CONNECTION_CLOSE => return error.ConnectionClosed,
                    else => return error.UnexpectedMethod,
                }
            } else return error.UnexpectedFrame;
        },
        error.Timeout => {
            try channel.basic_ack(state.last_delivery_tag, true);
            state.unacked_count = 0;
            std.log.debug("no messages, acked partial batch (delivery tag: {d})", .{state.last_delivery_tag});
            return;
        },
        else => return err,
    };
    defer envelope.destroy();

    const reply_to = envelope.message.properties.get(.reply_to) orelse {
        try channel.basic_reject(envelope.delivery_tag, false);
        return;
    };

    state.unacked_count += 1;
    state.last_delivery_tag = envelope.delivery_tag;

    var json = try std.ArrayList(u8).initCapacity(alloc, 4096);
    defer json.deinit();

    const valid_content_type = if (envelope.message.properties.get(.content_type)) |content_type|
        std.mem.eql(u8, content_type.slice().?, "text/dns")
    else
        false;

    if (valid_content_type) {
        try zone2json.convertApi(envelope.message.body.slice().?, &json);
    } else {
        json.appendSliceAssumeCapacity(
            \\{"error":"invalid content type"}
        );
    }

    var properties = amqp.BasicProperties.init(.{
        .content_type = bytes("application/json"),
    });
    if (envelope.message.properties.get(.correlation_id)) |id| {
        properties.set(.correlation_id, id);
    }

    try channel.basic_publish(
        bytes(""),
        reply_to,
        bytes(json.items),
        properties,
        .{},
    );

    if (state.unacked_count == settings.max_batch) {
        try channel.basic_ack(state.last_delivery_tag, true);
        state.unacked_count = 0;
        std.log.debug("acked full batch (delivery tag: {d})", .{state.last_delivery_tag});
    }
}

const ChannelSettings = struct {
    queue: []const u8,
    prefetch_count: u16,
    max_batch: u16,
};

fn setupChannel(channel: amqp.Channel, settings: ChannelSettings) !void {
    std.log.info("opening channel {d}", .{channel.number});

    _ = try channel.open();
    errdefer channel.close(.REPLY_SUCCESS) catch |err| logOrPanic(err);

    std.log.info("consuming from queue {s}", .{settings.queue});

    try channel.basic_qos(0, settings.prefetch_count, false);
    _ = try channel.basic_consume(bytes(settings.queue), .{});

    std.log.info("channel set up", .{});
}

const ConnectionSettings = struct {
    port: c_int,
    host: [*:0]const u8,
    vhost: [*:0]const u8,
    auth: amqp.Connection.SaslAuth,
    /// null disables TLS
    ca_cert: ?[*:0]const u8,
    heartbeat: c_int,
};

fn setupConnection(conn: amqp.Connection, settings: ConnectionSettings) !void {
    std.log.info("connecting to {s}:{d}", .{ settings.host, settings.port });

    if (settings.ca_cert) |ca_cert| {
        const sock = try amqp.SslSocket.new(conn);
        sock.set_verify_peer(true);
        sock.set_verify_hostname(true);
        try sock.set_cacert(ca_cert);
        try sock.open(settings.host, settings.port, null);
    } else {
        const sock = try amqp.TcpSocket.new(conn);
        try sock.open(settings.host, settings.port, null);
    }

    errdefer conn.close(.REPLY_SUCCESS) catch |err| logOrPanic(err);

    std.log.info("logging into vhost {s} as {s}", .{ settings.vhost, settings.auth.plain.username });

    try conn.login(settings.vhost, settings.auth, .{ .heartbeat = settings.heartbeat });

    std.log.info("connection set up", .{});
}

fn exponentialBackoff(backoff: *i64, random: *std.rand.Random) void {
    if (backoff.* == 0) {
        // first time try again without waiting
        backoff.* = 1000;
        return;
    }

    const start = std.time.milliTimestamp();
    var to_sleep: i64 = backoff.* + random.uintLessThanBiased(u32, 1000);
    while (to_sleep > 1) {
        std.time.sleep(@intCast(u64, to_sleep * std.time.ns_per_ms));
        to_sleep -= std.time.milliTimestamp() - start;
    }
    if (backoff.* < 32_000) backoff.* *= 2;
}

fn fatal(comptime fmt: []const u8, args: anytype) noreturn {
    std.debug.print(fmt ++ "\n", args);
    std.os.exit(1);
}

fn arg(args: *std.process.ArgIterator, cur: []const u8, comptime name: []const u8, T: type) ?T {
    if (!std.mem.eql(u8, cur, name)) return null;

    const val = args.nextPosix() orelse fatal("missing argument after {s}", .{name});

    if (T == [:0]const u8) {
        return val;
    }
    if (@typeInfo(T) == .Int) {
        return std.fmt.parseInt(T, val, 10) catch |err| fatal("invalid {s} argument: {}", .{ name, err });
    }

    @compileError("unimplemented type");
}

pub fn main() !void {
    const alloc = std.heap.c_allocator;

    var args = std.process.args();
    var uri: ?[:0]u8 = null;

    var port: ?c_int = null;
    var host: [*:0]const u8 = "localhost";
    var vhost: [*:0]const u8 = "/";
    var user: [*:0]const u8 = "guest";
    var password: [*:0]const u8 = "guest";
    var tls = true;
    var ca_cert: ?[*:0]const u8 = null;
    var heartbeat: c_int = 0;

    var chanSettings = ChannelSettings{
        .queue = "zone2json",
        .prefetch_count = 0,
        .max_batch = 1,
    };

    const str = [:0]const u8;

    _ = args.nextPosix(); // skip exe path

    while (args.nextPosix()) |opt| {
        if (opt[0] != '-') {
            if(uri != null) fatal("multiple URIs specified", .{});

            uri = try alloc.dupeZ(u8, opt);
            if(std.mem.indexOfScalar(u8, uri.?, '?')) |index| {
                uri.?[index] = 0;
                //TODO parse query
            }
            const uri_params = amqp.parse_url(uri.?) catch fatal("invalid URI", .{});
            host = uri_params.host;
            port = uri_params.port;
            vhost = uri_params.vhost;
            user = uri_params.user;
            password = uri_params.password;
            tls = uri_params.ssl != 0;
        } else if (arg(&args, opt, "--log", str)) |val| {
            logOut = std.meta.stringToEnum(@TypeOf(logOut), val) orelse fatal("invalid --log argument", .{});
        } else if (arg(&args, opt, "--host", str)) |val| {
            host = val;
        } else if (arg(&args, opt, "--port", c_int)) |val| {
            port = val;
        } else if (arg(&args, opt, "--vhost", str)) |val| {
            vhost = val;
        } else if (arg(&args, opt, "--user", str)) |val| {
            user = val;
        } else if (arg(&args, opt, "--password", str)) |val| {
            password = val;
        } else if (arg(&args, opt, "--ca-root", str)) |val| {
            ca_cert = val;
        } else if (arg(&args, opt, "--heartbeat", c_int)) |val| {
            heartbeat = val;
        } else if (arg(&args, opt, "--queue", str)) |val| {
            chanSettings.queue = val;
        } else if (arg(&args, opt, "--prefetch-count", u16)) |val| {
            chanSettings.prefetch_count = val;
        } else if (arg(&args, opt, "--batch", u16)) |val| {
            if (val == 0) fatal("invalid --batch argument: 0 is not allowed", .{});
            chanSettings.max_batch = val;
        } else if (std.mem.eql(u8, opt, "--no-tls")) {
            tls = false;
        } else if (std.mem.eql(u8, opt, "-h") or std.mem.eql(u8, opt, "--help")) {
            try help();
            std.os.exit(0);
        } else {
            fatal("unknown option: {s}", .{opt});
        }
    }

    if (tls and ca_cert == null) fatal("specify a trusted root certificates file with --ca-root or disable TLS with --no-tls or an amqp:// URI", .{});
    if (!tls and ca_cert != null) fatal("contradictory options: --ca-root specified, but TLS disabled", .{});

    if (port == null) port = if (tls) 5671 else 5672;

    var conn = try amqp.Connection.new();
    defer conn.destroy() catch |err| logOrPanic(err);

    var backoff_ms: i64 = 0;
    var rng = std.rand.DefaultPrng.init(std.crypto.random.int(u64));

    connection: while (true) {
        setupConnection(conn, .{
            .port = port.?,
            .host = host,
            .vhost = vhost,
            .auth = .{ .plain = .{ .username = user, .password = password } },
            .ca_cert = ca_cert,
            .heartbeat = heartbeat,
        }) catch |err| {
            logOrPanic(err);
            exponentialBackoff(&backoff_ms, &rng.random);
            continue :connection;
        };
        defer conn.close(.REPLY_SUCCESS) catch |err| logOrPanic(err);

        channel: while (true) {
            const channel = conn.channel(1);
            setupChannel(channel, chanSettings) catch |err| {
                logOrPanic(err);
                exponentialBackoff(&backoff_ms, &rng.random);
                continue :connection;
            };
            defer channel.close(.REPLY_SUCCESS) catch |err| logOrPanic(err);

            var state = ChannelState{};

            while (true) {
                listen(alloc, channel, &state, chanSettings) catch |err| {
                    logOrPanic(err);
                    exponentialBackoff(&backoff_ms, &rng.random);
                    if (err == error.ChannelClosed) continue :channel;
                    continue :connection;
                };
                backoff_ms = 0;
            }
        }
    }
}

fn help() !void {
    try std.io.getStdOut().writeAll(
        \\Usage: zone2json-server OPTIONS [URI]
        \\An AMQP RPC server that converts DNS zones to JSON
        \\Connection options:
        \\  --host [name]             default: localhost
        \\  --port [port]             default: 5671 (with TLS) / 5672 (without TLS)
        \\  --vhost [name]            default: /
        \\  --user [name]             default: guest
        \\  --password [password]     default: guest
        \\  --heartbeat [seconds]     default: 0 (disabled)
        \\  --ca-root [path]          trusted root certificates file
        \\  --no-tls                  disable TLS
        \\Channel options:
        \\  --queue [name]            default: zone2json
        \\  --prefetch-count [count]  default: 0 (unlimited)
        \\  --batch [count]           Acknowledge in batches of size count (default: 1)
        \\                            (sooner if there are no messages to process)
        \\Other options:
        \\  --log [syslog|stderr]     log target (default: syslog)
        \\  --help                    display help and exit
        \\
    );
}
