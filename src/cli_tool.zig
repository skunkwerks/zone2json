const std = @import("std");
const zone2json = @import("zone2json.zig");

pub fn fatal(comptime fmt: []const u8, args: anytype) noreturn {
    std.debug.print(fmt, args);
    std.os.exit(1);
}

pub fn main() !void {
    const args = try std.process.argsAlloc(std.heap.c_allocator);
    defer std.process.argsFree(std.heap.c_allocator, args);

    if (args.len > 2) fatal("Usage: zone2json [file]\n", .{});

    const filename = if (args.len == 2) args[1] else "/dev/stdin";

    const cFile = std.c.fopen(filename, "r") orelse fatal("Could not open {s}\n", .{filename});
    defer _ = std.c.fclose(cFile);

    try zone2json.convertCFile(cFile, std.io.getStdOut().writer());
}
