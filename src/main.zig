const std = @import("std");
const log = std.log;
const amqp = @import("zamqp");
const zone2json = @import("zone2json.zig");
const bytes = amqp.bytes_t.init;

fn logOrPanic(err: anyerror) void {
    switch (err) {
        error.OutOfMemory => {
            // librabbitmq docs say it is not designed to handle OOM
            std.debug.panic("out of memory", .{});
        },
        error.Unexpected => std.debug.panic("unexpected error", .{}),
        else => std.log.err("error: {}", .{err}),
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

fn setupChannel(channel: amqp.Channel) !void {
    const queue = bytes("rpc_queue");

    _ = try channel.open();
    errdefer channel.close(.REPLY_SUCCESS) catch |err| logOrPanic(err);

    _ = try channel.queue_declare(queue, .{ .auto_delete = true });

    _ = try channel.basic_consume(queue, .{});
}

fn setupConnection(conn: amqp.Connection) !void {
    const hostname = "localhost";
    const port = 5672;

    const sock = try amqp.TcpSocket.new(conn);
    try sock.open(hostname, port, null);

    try conn.login("/", .{ .plain = .{ .username = "guest", .password = "guest" } }, .{ .heartbeat = 0 });
}

pub fn main() !void {
    const alloc = std.heap.c_allocator;

    // TODO add backoff after repeated failure

    connection: while (true) {
        var conn = try amqp.Connection.new();
        defer conn.destroy() catch |err| logOrPanic(err);
        setupConnection(conn) catch |err| {
            logOrPanic(err);
            continue :connection;
        };
        defer conn.close(.REPLY_SUCCESS) catch |err| logOrPanic(err);

        channel: while (true) {
            const channel = conn.channel(1);
            setupChannel(channel) catch |err| {
                logOrPanic(err);
                if (err == error.ChannelClosed) continue :channel;
                continue :connection;
            };
            defer channel.close(.REPLY_SUCCESS) catch |err| logOrPanic(err);

            while (true) {
                listen(alloc, channel) catch |err| {
                    logOrPanic(err);
                    if (err == error.ChannelClosed) continue :channel;
                    continue :connection;
                };
            }
        }
    }
}
