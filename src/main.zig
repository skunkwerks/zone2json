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

fn listen(alloc: *std.mem.Allocator, channel: amqp.Channel) !void {
    channel.maybe_release_buffers();

    var envelope = channel.connection.consume_message(null, 0) catch |err| switch (err) {
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
        else => return err,
    };
    defer envelope.destroy();

    const reply_to = envelope.message.properties.get(.reply_to) orelse {
        try channel.basic_reject(envelope.delivery_tag, false);
        return;
    };

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

    try channel.basic_ack(envelope.delivery_tag, false);
}

fn setupChannel(channel: amqp.Channel, queue: []const u8) !void {
    const queue_bytes = bytes(queue);

    _ = try channel.open();
    errdefer channel.close(.REPLY_SUCCESS) catch |err| logOrPanic(err);

    _ = try channel.queue_declare(queue_bytes, .{ .auto_delete = true });

    _ = try channel.basic_consume(queue_bytes, .{});
}

const ConnectionSettings = struct {
    port: c_int,
    host: [*:0]const u8,
    vhost: [*:0]const u8,
    auth: amqp.Connection.SaslAuth,
    ca_cert: [*:0]const u8,
    heartbeat: c_int,
};

fn setupConnection(conn: amqp.Connection, settings: ConnectionSettings) !void {
    const sock = try amqp.SslSocket.new(conn);
    sock.set_verify_peer(true);
    sock.set_verify_hostname(true);
    try sock.set_cacert(settings.ca_cert);

    try sock.open(settings.host, settings.port, null);
    errdefer conn.close(.REPLY_SUCCESS) catch |err| logOrPanic(err);

    std.log.info("connected to {s}:{d}", .{ settings.host, settings.port });

    try conn.login(settings.vhost, settings.auth, .{ .heartbeat = settings.heartbeat });

    std.log.info("logged in to vhost {s}", .{settings.vhost});
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

fn arg(args: *std.process.ArgIterator, cur: []const u8, comptime name: []const u8) ?[:0]const u8 {
    return if (std.mem.eql(u8, cur, name))
        args.nextPosix() orelse fatal("missing argument after {s}", .{name})
    else
        null;
}

pub fn main() !void {
    const alloc = std.heap.c_allocator;

    var args = std.process.args();

    var port: c_int = 5671;
    var host: [*:0]const u8 = "localhost";
    var vhost: [*:0]const u8 = "/";
    var user: [*:0]const u8 = "guest";
    var password: [*:0]const u8 = "guest";
    var ca_cert: ?[*:0]const u8 = null;
    var heartbeat: c_int = 0;
    var queue: []const u8 = "zone2json";

    while (args.nextPosix()) |opt| {
        if (arg(&args, opt, "--log")) |val| {
            logOut = std.meta.stringToEnum(@TypeOf(logOut), val) orelse fatal("invalid --log argument", .{});
        } else if (arg(&args, opt, "--host")) |val| {
            host = val;
        } else if (arg(&args, opt, "--port")) |val| {
            port = std.fmt.parseInt(c_int, val, 10) catch fatal("invalid --port argument", .{});
        } else if (arg(&args, opt, "--vhost")) |val| {
            vhost = val;
        } else if (arg(&args, opt, "--user")) |val| {
            user = val;
        } else if (arg(&args, opt, "--password")) |val| {
            password = val;
        } else if (arg(&args, opt, "--ca-root")) |val| {
            ca_cert = val;
        } else if (arg(&args, opt, "--heartbeat")) |val| {
            heartbeat = std.fmt.parseInt(c_int, val, 10) catch fatal("invalid --heartbeat argument", .{});
        } else if (arg(&args, opt, "--queue")) |val| {
            queue = val;
        } else if (std.mem.eql(u8, opt, "-h") or std.mem.eql(u8, opt, "--help")) {
            try help();
            std.os.exit(0);
        }
    }

    if (ca_cert == null) fatal("please specify a trusted root certificates file with --ca-root", .{});

    var conn = try amqp.Connection.new();
    defer conn.destroy() catch |err| logOrPanic(err);

    var backoff_ms: i64 = 0;
    var rng = std.rand.DefaultPrng.init(std.crypto.random.int(u64));

    connection: while (true) {
        setupConnection(conn, .{
            .port = port,
            .host = host,
            .vhost = vhost,
            .auth = .{ .plain = .{ .username = user, .password = password } },
            .ca_cert = ca_cert.?,
            .heartbeat = heartbeat,
        }) catch |err| {
            logOrPanic(err);
            exponentialBackoff(&backoff_ms, &rng.random);
            continue :connection;
        };
        defer conn.close(.REPLY_SUCCESS) catch |err| logOrPanic(err);

        channel: while (true) {
            const channel = conn.channel(1);
            setupChannel(channel, queue) catch |err| {
                logOrPanic(err);
                exponentialBackoff(&backoff_ms, &rng.random);
                continue :connection;
            };
            defer channel.close(.REPLY_SUCCESS) catch |err| logOrPanic(err);

            while (true) {
                listen(alloc, channel) catch |err| {
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
        \\Usage: zone2json-server OPTIONS
        \\An AMQP RPC server that converts DNS zones to JSON
        \\Options:
        \\  --host        default: localhost
        \\  --port        default: 5671
        \\  --vhost       default: /
        \\  --user        default: guest
        \\  --password    default: guest
        \\  --queue       default: zone2json
        \\  --log         log to syslog (default) or stderr
        \\  --ca-root     trusted root certificates file
        \\  --heartbeat   seconds, 0 to disable (default)
        \\  --help        display help and exit
        \\
    );
}
