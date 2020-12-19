const std = @import("std");
const zdns = @import("zdns");
const amqp = @import("zamqp");
const bytes = amqp.bytes_t.init;

pub fn main() !void {
    const hostname = "localhost";
    const port = 5672;
    const exchange = "";
    const queue = bytes("rpc_queue");

    const conn = try amqp.connection_state_t.new();
    defer conn.destroy() catch {};

    const sock = try amqp.socket_t.new_tcp(conn);
    try sock.open(hostname, port);

    try conn.login("/", 0, 131072, 0, .{ .plain = .{ .username = "guest", .password = "guest" } });
    defer conn.close(amqp.REPLY_SUCCESS) catch {};

    const channel = amqp.Channel{ .conn = conn, .number = 1 };
    _ = try channel.open();
    defer channel.close(amqp.REPLY_SUCCESS) catch {};

    _ = try channel.queue_declare(queue, 0, 0, 0, 1, amqp.table_t.empty());

    _ = try channel.basic_consume(queue, bytes(""), 0, 1, 0, amqp.table_t.empty());

    while (true) {
        conn.maybe_release_buffers();

        var envelope = conn.consume_message(null, 0) catch |err| switch (err) {
            // error.UnexpectedState => {}, TODO amqp_simple_wait_frame
            else => return err,
        };
        defer envelope.destroy();

        std.debug.print("Delivery {}, exchange {s} routingkey {s}\n", .{ envelope.delivery_tag, envelope.exchange.slice().?, envelope.routing_key.slice().? });

        if (envelope.message.properties._flags & amqp.basic_properties_t.CONTENT_TYPE_FLAG == 0 or !std.mem.eql(u8, envelope.message.properties.content_type.slice().?, "text/dns")) {
            std.debug.print("invalid content type\n", .{});
            std.os.exit(1);
        }

        if (envelope.message.properties._flags & amqp.basic_properties_t.CORRELATION_ID_FLAG == 0) {
            std.debug.print("no correlation id\n", .{});
            std.os.exit(1);
        }
        const correlation_id = envelope.message.properties.correlation_id;

        var json = std.ArrayList(u8).init(std.heap.c_allocator);
        defer json.deinit();
        try zdns.zone2json.convertMem(envelope.message.body.slice().?, json.writer());

        var props: amqp.basic_properties_t = undefined;
        props._flags = amqp.basic_properties_t.CORRELATION_ID_FLAG | amqp.basic_properties_t.CONTENT_TYPE_FLAG;
        props.content_type = bytes("application/json");
        props.correlation_id = correlation_id;

        try channel.basic_publish(
            bytes(""),
            envelope.message.properties.reply_to,
            0,
            0,
            &props,
            bytes(json.items),
        );

        // amqp.basic_ack(); TODO
    }
}
