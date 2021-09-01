const std = @import("std");
const c = std.c;
const json = std.json;
const ldns = @import("zdns");
const testing = std.testing;

pub fn rrFieldNames(type_: ldns.rr_type, ctx: anytype) ![]const []const u8 {
    const str = []const u8;
    return switch (type_) {
        .A, .AAAA => &[_]str{"ip"},
        .AFSDB => &[_]str{ "subtype", "hostname" },
        .CAA => &[_]str{ "flags", "tag", "value" },
        .CERT => &[_]str{ "type", "key_tag", "alg", "cert" },
        .CNAME, .DNAME, .NS, .PTR => &[_]str{"dname"},
        .DHCID => &[_]str{"data"},
        .DLV, .DS, .CDS => &[_]str{ "keytag", "alg", "digest_type", "digest" },
        .DNSKEY, .CDNSKEY => &[_]str{ "flags", "protocol", "alg", "public_key", "key_tag" },
        .HINFO => &[_]str{ "cpu", "os" },
        .IPSECKEY => &[_]str{ "precedence", "alg", "gateway", "public_key" },
        .KEY => &[_]str{ "type", "xt", "name_type", "sig", "protocol", "alg", "public_key" },
        .KX, .MX => &[_]str{ "preference", "exchange" },
        .LOC => &[_]str{ "size", "horiz", "vert", "lat", "lon", "alt" },
        .MB, .MG => &[_]str{"madname"},
        .MINFO => &[_]str{ "rmailbx", "emailbx" },
        .MR => &[_]str{"newname"},
        .NAPTR => &[_]str{ "order", "preference", "flags", "services", "regexp", "replacement" },
        .NSEC => &[_]str{ "next_dname", "types" },
        .NSEC3 => &[_]str{ "hash_alg", "opt_out", "iterations", "salt", "hash", "types" },
        .NSEC3PARAM => &[_]str{ "hash_alg", "flags", "iterations", "salt" },
        .NXT => &[_]str{ "dname", "types" },
        .RP => &[_]str{ "mbox", "txt" },
        .RRSIG => &[_]str{ "type_covered", "alg", "labels", "original_ttl", "expiration", "inception", "key_tag", "signers_name", "signature" },
        .RT => &[_]str{ "preference", "host" },
        .SOA => &[_]str{ "mname", "rname", "serial", "refresh", "retry", "expire", "minimum" },
        .SPF => &[_]str{"spf"},
        .SRV => &[_]str{ "priority", "weight", "port", "target" },
        .SSHFP => &[_]str{ "alg", "fp_type", "fp" },
        .TSIG => &[_]str{ "alg", "time", "fudge", "mac", "msgid", "err", "other" },
        .TXT => &[_]str{"txt"},
        else => {
            try ctx.ok(type_.appendStr(ctx.tmp_buf));
            try ctx.err_writer.print("unsupported record type: {s}", .{ctx.tmp_buf.data()});
            return error.UnsupportedRecordType;
        },
    };
}

pub fn emitRdf(rdf: *ldns.rdf, ctx: anytype) !void {
    const type_ = rdf.get_type();
    switch (type_) {
        .INT32, .PERIOD => try ctx.out.emitNumber(rdf.int32()),
        .INT16 => try ctx.out.emitNumber(rdf.int16()),
        .INT8 => try ctx.out.emitNumber(rdf.int8()),
        else => {
            try ctx.ok(rdf.appendStr(ctx.tmp_buf));
            var text = ctx.tmp_buf.data();

            switch (type_) {
                // strip the trailing dot
                .DNAME => text = text[0 .. text.len - 1],
                // strip the quotes
                .STR => text = text[1 .. text.len - 1],
                else => {},
            }

            try ctx.out.emitString(text);
            ctx.tmp_buf.clear();
        },
    }
}

fn testRdf(type_: ldns.rdf_type, expected_out: []const u8, in: [*:0]const u8) !void {
    var outBuf: [4096]u8 = undefined;
    var bufStream = std.io.fixedBufferStream(&outBuf);
    var out = json.writeStream(bufStream.writer(), 6);

    var errBuf: [4096]u8 = undefined;
    var errStream = std.io.fixedBufferStream(&outBuf);

    const buf = try ldns.buffer.new(4096);
    defer buf.free();

    const rdf = ldns.rdf.new_frm_str(type_, in) orelse return error.LdnsError;
    defer rdf.deep_free();

    var ctx = Context(@TypeOf(&out), @TypeOf(errStream.writer())){ .out = &out, .err_writer = errStream.writer(), .tmp_buf = buf };

    try emitRdf(rdf, &ctx);
    try testing.expectEqualStrings(expected_out, bufStream.getWritten());
    try testing.expectEqual(@as(usize, 0), errStream.getWritten().len);
}

test "emitRdf" {
    try testRdf(.STR,
        \\"m\\196\\133ka"
    ,
        \\m\196\133ka
    );
    try testRdf(.DNAME, "\"www.example.com\"", "www.example.com.");
    try testRdf(.INT8, "243", "243");
    try testRdf(.INT16, "5475", "5475");
    try testRdf(.INT32, "7464567", "7464567");
    try testRdf(.PERIOD, "7464567", "7464567");
    try testRdf(.A, "\"192.168.1.1\"", "192.168.1.1");

    try testing.expectError(error.LdnsError, testRdf(.INT32, "", "bogus"));
}

pub fn emitRr(rr: *ldns.rr, ctx: anytype) !void {
    const type_ = rr.get_type();

    try ctx.out.beginObject();

    try ctx.out.objectField("name");
    try emitRdf(rr.owner(), ctx);

    try ctx.out.objectField("type");
    try ctx.ok(type_.appendStr(ctx.tmp_buf));
    try ctx.out.emitString(ctx.tmp_buf.data());
    ctx.tmp_buf.clear();

    try ctx.out.objectField("ttl");
    try ctx.out.emitNumber(rr.ttl());

    try ctx.out.objectField("data");
    try ctx.out.beginObject();

    const fieldNames = try rrFieldNames(type_, ctx);

    const rdf_count = rr.rd_count();
    var rdf_index: usize = 0;
    while (rdf_index < rdf_count) : (rdf_index += 1) {
        try ctx.out.objectField(fieldNames[rdf_index]);
        try emitRdf(rr.rdf(rdf_index), ctx);
    }

    try ctx.out.endObject();
    try ctx.out.endObject();
}

fn testRr(expected_out: []const u8, in: [*:0]const u8) !void {
    var outBuf: [4096]u8 = undefined;
    var bufStream = std.io.fixedBufferStream(&outBuf);
    var out = json.writeStream(bufStream.writer(), 6);

    var errBuf: [4096]u8 = undefined;
    var errStream = std.io.fixedBufferStream(&outBuf);

    const buf = try ldns.buffer.new(4096);
    defer buf.free();

    const rr = switch (ldns.rr.new_frm_str(in, 0, null, null)) {
        .ok => |row| row,
        .err => |stat| return error.LdnsError,
    };
    defer rr.free();

    var ctx = Context(@TypeOf(&out), @TypeOf(errStream.writer())){ .out = &out, .err_writer = errStream.writer(), .tmp_buf = buf };

    try emitRr(rr, &ctx);
    try testing.expectEqualStrings(expected_out, bufStream.getWritten());
    try testing.expectEqual(@as(usize, 0), errStream.getWritten().len);
}

test "emitRr" {
    try testRr(
        \\{
        \\ "name": "minimal.com",
        \\ "type": "SOA",
        \\ "ttl": 3600,
        \\ "data": {
        \\  "mname": "ns.example.net",
        \\  "rname": "admin.minimal.com",
        \\  "serial": 2013022001,
        \\  "refresh": 86400,
        \\  "retry": 7200,
        \\  "expire": 3600,
        \\  "minimum": 3600
        \\ }
        \\}
    ,
        \\minimal.com.	3600	IN	SOA	    ns.example.net. admin.minimal.com. 2013022001 86400 7200 3600 3600
    );
    try testRr(
        \\{
        \\ "name": "minimal.com",
        \\ "type": "AAAA",
        \\ "ttl": 3600,
        \\ "data": {
        \\  "ip": "2001:6a8:0:1:210:4bff:fe4b:4c61"
        \\ }
        \\}
    ,
        \\minimal.com.	3600	IN	AAAA	2001:6a8:0:1:210:4bff:fe4b:4c61
    );
    try testing.expectError(error.LdnsError, testRr("", "bogus"));
}

pub fn emitZone(zone: *ldns.zone, ctx: anytype) !void {
    const rr_list = zone.rrs();
    const rr_count = rr_list.rr_count();

    const soa = zone.soa() orelse {
        try ctx.err_writer.print("no SOA record in zone", .{});
        return error.NoSoaRecord;
    };

    try ctx.out.beginObject();

    try ctx.out.objectField("name");
    try emitRdf(soa.owner(), ctx);

    try ctx.out.objectField("records");
    try ctx.out.beginArray();

    try ctx.out.arrayElem();
    try emitRr(soa, ctx);

    var rr_index: usize = 0;
    while (rr_index < rr_count) : (rr_index += 1) {
        const rr = rr_list.rr(rr_index);
        try ctx.out.arrayElem();
        try emitRr(rr, ctx);
    }
    try ctx.out.endArray();
    try ctx.out.endObject();
}

pub fn Context(comptime Writer: type, comptime ErrWriter: type) type {
    return struct {
        out: Writer,
        err_writer: ErrWriter,
        tmp_buf: *ldns.buffer,

        pub fn ok(self: *@This(), status: ldns.status) !void {
            if (status != .OK) {
                std.log.err("unexpected ldns error: {s}", .{status.get_errorstr()});
                return error.Unexpected;
            }
        }
    };
}

pub fn convertCFile(file: *c.FILE, json_writer: anytype, err_writer: anytype) !void {
    const zone = switch (ldns.zone.new_frm_fp(file, null, 0, .IN)) {
        .ok => |z| z,
        .err => |err| {
            try err_writer.print("parsing zone failed on line {}: {s}", .{ err.line, err.code.get_errorstr() });
            return error.ParseError;
        },
    };
    defer zone.deep_free();

    const buf = try ldns.buffer.new(4096);
    defer buf.free();

    var ctx = Context(@TypeOf(json_writer), @TypeOf(err_writer)){ .out = json_writer, .err_writer = err_writer, .tmp_buf = buf };
    try emitZone(zone, &ctx);
}

pub fn convertMem(zone: []const u8, json_writer: anytype, err_writer: anytype) !void {
    const file = c.fmemopen(@intToPtr(?*c_void, @ptrToInt(zone.ptr)), zone.len, "r") orelse return error.SystemResources;
    defer _ = c.fclose(file);
    return convertCFile(file, json_writer, err_writer);
}

pub fn convertApi(zone: []const u8, json_out: *std.ArrayList(u8)) !void {
    var err_buf: [256]u8 = undefined;
    var err_stream = std.io.fixedBufferStream(&err_buf);

    var json_writer = std.json.writeStream(json_out.writer(), 10);
    try json_writer.beginObject();
    try json_writer.objectField("ok");
    convertMem(zone, &json_writer, err_stream.writer()) catch |err| switch (err) {
        error.OutOfMemory, error.SystemResources, error.NoSpaceLeft, error.Unexpected => return err,
        error.ParseError, error.UnsupportedRecordType, error.NoSoaRecord => {
            json_out.shrinkRetainingCapacity(0);
            json_writer = std.json.writeStream(json_out.writer(), 10);
            try json_writer.beginObject();
            try json_writer.objectField("error");
            try json_writer.emitString(err_stream.getWritten());
        },
    };
    try json_writer.endObject();
}
