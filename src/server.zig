const std = @import("std");
const amqp = @import("zamqp");
const bytes = amqp.bytes_t.init;
const zone2json = @import("zone2json.zig");

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

pub const ChannelSettings = struct {
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

pub const ConnectionSettings = struct {
    port: c_int,
    host: [*:0]const u8,
    vhost: [*:0]const u8,
    auth: amqp.Connection.SaslAuth,
    /// null disables TLS
    tls: ?struct {
        ca_cert_path: [*:0]const u8,
        keys: ?struct {
            cert_path: [*:0]const u8,
            key_path: [*:0]const u8,
        },
        verify_peer: bool,
        verify_hostname: bool,
    },
    heartbeat: c_int,
};

fn setupConnection(conn: amqp.Connection, settings: ConnectionSettings) !void {
    std.log.info("connecting to {s}:{d}", .{ settings.host, settings.port });

    if (settings.tls) |tls| {
        const sock = try amqp.SslSocket.new(conn);
        sock.set_verify_peer(tls.verify_peer);
        sock.set_verify_hostname(tls.verify_hostname);
        try sock.set_cacert(tls.ca_cert_path);

        if (tls.keys) |keys|
            try sock.set_key(keys.cert_path, keys.key_path);

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

const ExponentialBackoff = struct {
    ns: u64,
    random: *std.rand.Random,
    timer: std.time.Timer,

    const min = 1 * std.time.ns_per_s;
    const max = 32 * std.time.ns_per_s;
    const jitter = 1 * std.time.ns_per_s;

    pub fn init(random: *std.rand.Random) !ExponentialBackoff {
        return ExponentialBackoff{
            .timer = try std.time.Timer.start(),
            .random = random,
            .ns = min,
        };
    }

    pub fn sleep(self: *ExponentialBackoff) void {
        self.timer.reset();
        const to_sleep_ns: u64 = self.ns + self.random.uintLessThanBiased(u64, jitter);

        std.time.sleep(@intCast(u64, to_sleep_ns));

        while (true) {
            const timer_val = self.timer.read();
            if(timer_val >= to_sleep_ns) break;
            // Spurious wakeup
            std.time.sleep(@intCast(u64, to_sleep_ns - timer_val));
        }

        if (self.ns < max) self.ns *= 2;
    }

    pub fn reset(self: *ExponentialBackoff) void {
        self.ns = min;
    }
};

pub fn run(alloc: *std.mem.Allocator, con_settings: ConnectionSettings, chan_settings: ChannelSettings) !void {
    var conn = try amqp.Connection.new();
    defer conn.destroy() catch |err| logOrPanic(err);

    var rng = std.rand.DefaultPrng.init(std.crypto.random.int(u64));
    var backoff = try ExponentialBackoff.init(&rng.random);

    connection: while (true) {
        setupConnection(conn, con_settings) catch |err| {
            logOrPanic(err);
            backoff.sleep();
            continue :connection;
        };
        defer conn.close(.REPLY_SUCCESS) catch |err| logOrPanic(err);

        channel: while (true) {
            const channel = conn.channel(1);
            setupChannel(channel, chan_settings) catch |err| {
                logOrPanic(err);
                backoff.sleep();
                continue :connection;
            };
            defer channel.close(.REPLY_SUCCESS) catch |err| logOrPanic(err);

            var state = ChannelState{};

            while (true) {
                listen(alloc, channel, &state, chan_settings) catch |err| {
                    logOrPanic(err);
                    backoff.sleep();
                    if (err == error.ChannelClosed) continue :channel;
                    continue :connection;
                };
                backoff.reset();
            }
        }
    }
}
