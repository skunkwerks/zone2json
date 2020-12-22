const std = @import("std");
const ldns = @import("zdns");
const c = std.c;
const json = std.json;
const testing = std.testing;

pub fn rrFieldNames(type_: ldns.rr_type) []const []const u8 {
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
            const buf = ldns.buffer.new(32) catch @panic("oom");
            const status = type_.appendStr(buf);
            status.ok() catch @panic(std.mem.span(status.get_errorstr()));
            std.debug.panic("unsupported record type: {s}", .{buf.data()});
        },
    };
}

pub fn emitRdf(rdf: *ldns.rdf, out: anytype, tmp_buf: *ldns.buffer) !void {
    switch (rdf.get_type()) {
        .INT32, .PERIOD => try out.emitNumber(rdf.int32()),
        .INT16 => try out.emitNumber(rdf.int16()),
        .INT8 => try out.emitNumber(rdf.int8()),
        .DNAME => {
            try rdf.appendStr(tmp_buf).ok();
            const data = tmp_buf.data();
            // strip the trailing dot
            try out.emitString(data[0 .. data.len - 1]);
            tmp_buf.clear();
        },
        .STR => {
            try rdf.appendStr(tmp_buf).ok();
            const data = tmp_buf.data();
            // strip the quotes
            try out.emitString(data[1 .. data.len - 1]);
            tmp_buf.clear();
        },
        else => {
            try rdf.appendStr(tmp_buf).ok();
            try out.emitString(tmp_buf.data());
            tmp_buf.clear();
        },
    }
}

fn testRdf(type_: ldns.rdf_type, expected_out: []const u8, in: [*:0]const u8) !void {
    var outBuf: [4096]u8 = undefined;
    var bufStream = std.io.fixedBufferStream(&outBuf);
    var out = json.writeStream(bufStream.writer(), 6);

    const buf = try ldns.buffer.new(4096);
    defer buf.free();

    const rdf = try ldns.rdf.new_frm_str(type_, in);
    defer rdf.deep_free();

    try emitRdf(rdf, &out, buf);
    testing.expectEqualStrings(expected_out, bufStream.getWritten());
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

    testing.expectError(error.LdnsError, testRdf(.INT32, "", "bogus"));
}

pub fn emitRr(rr: *ldns.rr, out: anytype, tmp_buf: *ldns.buffer) !void {
    const type_ = rr.get_type();

    try out.beginObject();

    try out.objectField("name");
    try emitRdf(rr.owner(), out, tmp_buf);

    try out.objectField("type");
    try type_.appendStr(tmp_buf).ok();
    try out.emitString(tmp_buf.data());
    tmp_buf.clear();

    try out.objectField("ttl");
    try out.emitNumber(rr.ttl());

    try out.objectField("data");
    try out.beginObject();

    const fieldNames = rrFieldNames(type_);

    const rdf_count = rr.rd_count();
    var rdf_index: usize = 0;
    while (rdf_index < rdf_count) : (rdf_index += 1) {
        try out.objectField(fieldNames[rdf_index]);
        try emitRdf(rr.rdf(rdf_index), out, tmp_buf);
    }

    try out.endObject();
    try out.endObject();
}

fn testRr(expected_out: []const u8, in: [*:0]const u8) !void {
    var outBuf: [4096]u8 = undefined;
    var bufStream = std.io.fixedBufferStream(&outBuf);
    var out = json.writeStream(bufStream.writer(), 6);

    const buf = try ldns.buffer.new(4096);
    defer buf.free();

    const rr = switch (ldns.rr.new_frm_str(in, 0, null, null)) {
        .ok => |row| row,
        .err => |stat| return error.LdnsError,
    };
    defer rr.free();

    try emitRr(rr, &out, buf);
    testing.expectEqualStrings(expected_out, bufStream.getWritten());
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
    testing.expectError(error.LdnsError, testRr("", "bogus"));
}

pub fn emitZone(zone: *ldns.zone, out: anytype, tmp_buf: *ldns.buffer) !void {
    const rr_list = zone.rrs();
    const rr_count = rr_list.rr_count();

    const soa = zone.soa() orelse return error.NoSoaRecord;

    try out.beginObject();

    try out.objectField("name");
    try emitRdf(soa.owner(), out, tmp_buf);

    try out.objectField("records");
    try out.beginArray();

    try out.arrayElem();
    try emitRr(soa, out, tmp_buf);

    var rr_index: usize = 0;
    while (rr_index < rr_count) : (rr_index += 1) {
        const rr = rr_list.rr(rr_index);
        try out.arrayElem();
        try emitRr(rr, out, tmp_buf);
    }
    try out.endArray();
    try out.endObject();
}

pub fn convertCFile(file: *c.FILE, writer: anytype) !void {
    const zone = switch (ldns.zone.new_frm_fp(file, null, 0, .IN)) {
        .ok => |z| z,
        .err => |err| std.debug.panic("loading zone failed on line {}: {s}", .{ err.line, err.code.get_errorstr() }),
    };
    defer zone.deep_free();

    var out = json.writeStream(writer, 6);

    const buf = try ldns.buffer.new(4096);
    defer buf.free();

    try emitZone(zone, &out, buf);
}

extern "c" fn fmemopen(noalias buf: ?[*]u8, size: usize, noalias mode: [*:0]const u8) ?*c.FILE;

pub fn convertMem(zone: []const u8, writer: anytype) !void {
    const file = fmemopen(@intToPtr(?[*]u8, @ptrToInt(zone.ptr)), zone.len, "r") orelse return error.SystemResources;
    defer _ = c.fclose(file);
    return convertCFile(file, writer);
}
