const std = @import("std");
const zone2json = @import("zone2json.zig");

pub fn fatal(comptime fmt: []const u8, args: anytype) noreturn {
    std.debug.print(fmt, args);
    std.os.exit(1);
}

pub fn main() !void {
    const alloc = std.heap.c_allocator;

    const args = try std.process.argsAlloc(alloc);
    defer std.process.argsFree(alloc, args);

    if (args.len > 2) fatal("Usage: zone2json [file]\n", .{});

    const filename = if (args.len == 2) args[1] else "/dev/stdin";

    const c_file = std.c.fopen(filename, "r") orelse fatal("could not open {s}\n", .{filename});
    defer _ = std.c.fclose(c_file);

    // buffer output so that it doesn't get printed on error
    var output = try std.ArrayList(u8).initCapacity(alloc, 4096);
    defer output.deinit();
    var err = std.ArrayList(u8).init(alloc);
    defer err.deinit();

    var json_writer = std.json.writeStream(output.writer(), 10);

    zone2json.convertCFile(c_file, &json_writer, err.writer()) catch |e| {
        if (err.items.len == 0) {
            fatal("error: {s}\n", .{@errorName(e)});
        } else {
            fatal("{s}\n", .{err.items});
        }
    };

    try std.io.getStdOut().writeAll(output.items);
}
