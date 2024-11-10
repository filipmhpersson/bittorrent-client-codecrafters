const std = @import("std");
const reader = @import("streamreader.zig");
const writer = @import("bencodeWriter.zig");
const sha = std.crypto.hash.Sha1;
const stdout = std.io.getStdOut().writer();
const Headers = std.http.Headers;
var allocator = std.heap.page_allocator;

pub fn main() !void {
    const args = try std.process.argsAlloc(allocator);
    defer std.process.argsFree(allocator, args);

    if (args.len < 3) {
        try stdout.print("Usage: your_bittorrent.zig <command> <args>\n", .{});
        std.process.exit(1);
    }

    const command = args[1];

    var position: usize = 0;
    if (std.mem.eql(u8, command, "decode")) {
        var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
        defer arena.deinit();
        const alloca = arena.allocator();

        const encodedStr = args[2];
        const b = reader.getNextValue(encodedStr, &position, alloca) catch {
            try stdout.print("Invalid encoded value\n", .{});
            std.process.exit(1);
        };
        try printBencode(b);
        try stdout.print("\n", .{});
    }
    if (std.mem.eql(u8, command, "info")) {
        var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
        defer arena.deinit();
        const alloca = arena.allocator();

        const fileArg = args[2];
        var file = try std.fs.cwd().openFile(fileArg, .{});
        const encodedStr = try file.readToEndAlloc(allocator, 1024 * 1024);
        const b = reader.getNextValue(encodedStr, &position, alloca) catch {
            try stdout.print("Invalid encoded value\n", .{});
            std.process.exit(1);
        };
        defer file.close();

        try printTorrent(b, alloca);
        try stdout.print("\n", .{});
    }
    if (std.mem.eql(u8, command, "peers")) {
        var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
        defer arena.deinit();
        const alloca = arena.allocator();

        const fileArg = args[2];
        var file = try std.fs.cwd().openFile(fileArg, .{});
        const encodedStr = try file.readToEndAlloc(allocator, 1024 * 1024);
        const b = reader.getNextValue(encodedStr, &position, alloca) catch {
            try stdout.print("Invalid encoded value\n", .{});
            std.process.exit(1);
        };
        defer file.close();

        try getTorrent(b, alloca);
        try stdout.print("\n", .{});
    }

    if (std.mem.eql(u8, command, "handshake")) {
        var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
        defer arena.deinit();
        const alloca = arena.allocator();

        const fileArg = args[2];
        const peer = args[3];
        var file = try std.fs.cwd().openFile(fileArg, .{});
        const encodedStr = try file.readToEndAlloc(allocator, 1024 * 1024);
        const b = reader.getNextValue(encodedStr, &position, alloca) catch {
            try stdout.print("Invalid encoded value\n", .{});
            std.process.exit(1);
        };
        defer file.close();

        try getHandshake(b, peer, alloca);
        try stdout.print("\n", .{});
    }
}

fn printBencode(bencodedValue: reader.BencodeValue) !void {
    switch (bencodedValue) {
        .string => {
            var string = std.ArrayList(u8).init(allocator);
            try std.json.stringify(bencodedValue.string, .{}, string.writer());
            const jsonStr = try string.toOwnedSlice();
            try stdout.print("{s}", .{jsonStr});
        },
        .dictionary => {
            try stdout.print("{{", .{});
            const d = bencodedValue.dictionary;
            const k = d.keys();
            var array = std.ArrayList([]const u8).init(allocator);

            defer array.deinit();
            for (k) |key| {
                try array.append(key);
            }
            const slice = try array.toOwnedSlice();
            std.mem.sort([]const u8, slice, {}, lessthan);
            for (slice, 0..) |key, i| {
                var string = std.ArrayList(u8).init(allocator);
                try std.json.stringify(key, .{}, string.writer());
                const jsonStr = try string.toOwnedSlice();
                try stdout.print("{s}", .{jsonStr});
                try stdout.print(":", .{});
                try printBencode(d.get(key).?);
                if (i < slice.len - 1) {
                    try stdout.print(",", .{});
                }
            }
            try stdout.print("}}", .{});
        },
        .int => {
            try stdout.print("{d}", .{bencodedValue.int});
        },
        .array => {
            try stdout.print("[", .{});

            for (bencodedValue.array, 0..) |item, i| {
                try printBencode(item);
                if (i < bencodedValue.array.len - 1) {
                    try stdout.print(",", .{});
                }
            }
            try stdout.print("]", .{});
        },
    }
}

fn printTorrent(input: reader.BencodeValue, alloc: std.mem.Allocator) !void {
    if (input != reader.BencodedType.dictionary) {
        return error.InvalidArgument;
    }

    const url = input.dictionary.get("announce").?;
    const metadata = input.dictionary.get("info").?;

    if (metadata != reader.BencodedType.dictionary) {
        return error.InvalidArgument;
    }

    const length = metadata.dictionary.get("length").?;
    const pieceLength = metadata.dictionary.get("piece length").?;
    const pieces = metadata.dictionary.get("pieces").?.string;
    const bencodedInfo = try writer.bencode(&metadata, alloc);

    var sha1: [20]u8 = undefined;
    sha.hash(bencodedInfo, &sha1, sha.Options{});

    try stdout.print("Tracker URL: {s}\n", .{url.string});
    try stdout.print("Length: {d}\n", .{length.int});
    try stdout.print("Info Hash: ", .{});
    try stdout.print("{s}", .{std.fmt.fmtSliceHexLower(sha1[0..])});
    try stdout.print("Piece Length: {d}\n", .{pieceLength.int});
    try stdout.print("Piece Hashes:\n", .{});
    {
        var i: usize = 0;
        while (i < pieces.len) {
            try stdout.print("{s}\n", .{std.fmt.fmtSliceHexLower(pieces[i .. i + 20])});
            i += 20;
        }
    }
}

fn getTorrent(input: reader.BencodeValue, alloc: std.mem.Allocator) !void {
    if (input != reader.BencodedType.dictionary) {
        return error.InvalidArgument;
    }

    const url = input.dictionary.get("announce").?;
    const metadata = input.dictionary.get("info").?;

    if (metadata != reader.BencodedType.dictionary) {
        return error.InvalidArgument;
    }

    //const pieceLength = metadata.dictionary.get("piece length").?;
    //const pieces = metadata.dictionary.get("pieces").?.string;
    const bencodedInfo = try writer.bencode(&metadata, alloc);

    var sha1: [20]u8 = undefined;
    sha.hash(bencodedInfo, &sha1, sha.Options{});
    var client = std.http.Client{ .allocator = alloc };
    const length = metadata.dictionary.get("length").?;
    const downloaded: usize = 0;
    const uploaded: usize = 0;
    defer client.deinit();
    var list = std.ArrayList(u8).init(alloc);

    const infohash = try std.fmt.allocPrint(alloc, "{s}", .{std.fmt.fmtSliceHexLower(sha1[0..])});

    try list.appendSlice(url.string);
    try list.appendSlice("?info_hash=");
    {
        var i: usize = 0;
        while (i < infohash.len) : (i += 2) {
            try list.appendSlice(try std.fmt.allocPrint(alloc, "%{s}", .{infohash[i .. i + 2]}));
        }
    }
    try list.appendSlice("&peer_id=homersimpsontvcatgoo");
    try list.appendSlice("&port=6881");
    try list.appendSlice(try std.fmt.allocPrint(alloc, "&uploaded={d}", .{uploaded}));
    try list.appendSlice(try std.fmt.allocPrint(alloc, "&downloaded={d}", .{downloaded}));
    try list.appendSlice(try std.fmt.allocPrint(alloc, "&left={d}", .{length.int}));
    try list.appendSlice("&compact=1");
    const fmtUrl = try list.toOwnedSlice();

    std.debug.print("Request URL {s}\n", .{fmtUrl});
    const uri = try std.Uri.parse(fmtUrl);

    std.debug.print("Request parsed URL {s}\n", .{uri.query.?.percent_encoded});
    var headerbuf: [1000]u8 = undefined;
    const options = std.http.Client.RequestOptions{ .server_header_buffer = &headerbuf };
    var con = try client.open(std.http.Method.GET, uri, options);
    defer con.deinit();
    try con.send();
    try con.wait();
    const resp = con.response;
    const buf = try alloc.alloc(u8, resp.content_length.?);
    _ = try con.readAll(buf);
    std.debug.print("HTTP Response {s}, code {d}\n", .{ buf, resp.status });
    var position: usize = 0;
    const response = try reader.getNextValue(buf, &position, alloc);
    const p = response.dictionary.get("peers").?.string;
    {
        var i: usize = 0;
        while (i < p.len) : (i += 6) {
            const slice = p[i .. i + 6];

            const aw = std.fmt.fmtSliceHexLower(slice[4..]).data;
            var ba: [8]u8 = undefined;
            ba[0] = 0;
            ba[1] = 0;
            ba[2] = 0;
            ba[3] = 0;
            ba[4] = 0;
            ba[5] = 0;
            ba[6] = aw[0];
            ba[7] = aw[1];
            const parsedPort = std.mem.readInt(usize, &ba, std.builtin.Endian.big);

            try stdout.print("{d}.{d}.{d}.{d}:{d}\n", .{ slice[0], slice[1], slice[2], slice[3], parsedPort });
        }
    }
}

fn getHandshake(input: reader.BencodeValue, sampleIp: []u8, alloc: std.mem.Allocator) !void {
    if (input != reader.BencodedType.dictionary) {
        return error.InvalidArgument;
    }

    const metadata = input.dictionary.get("info").?;

    if (metadata != reader.BencodedType.dictionary) {
        return error.InvalidArgument;
    }

    //const pieceLength = metadata.dictionary.get("piece length").?;
    //const pieces = metadata.dictionary.get("pieces").?.string;
    const bencodedInfo = try writer.bencode(&metadata, alloc);

    var sha1: [20]u8 = undefined;
    sha.hash(bencodedInfo, &sha1, sha.Options{});

    const indexSemi = std.mem.indexOf(u8, sampleIp, ":").?;

    var port: u16 = 0;
    for (sampleIp[indexSemi + 1 ..]) |char| {
        std.debug.print("Char in port {c}\n", .{char});
        port = port * 10 + (char - '0');
    }

    const ip = try std.net.Ip4Address.parse(sampleIp[0..indexSemi], port);

    const c = std.net.Address{ .in = ip };

    const conn = try std.net.tcpConnectToAddress(c);

    std.debug.print("Post close\n", .{});
    defer conn.close();

    const tcpReader = conn.reader().any();
    const tcpwriter = conn.writer().any();

    const handshake = Handshake{ .infoHash = sha1, .peerId = "00112233445566778891".* };
    try tcpwriter.writeStruct(handshake);

    const res = try tcpReader.readStruct(Handshake);
    _ = try waitForResponse(&tcpReader, MessageType.Bitfield);
    try tcpwriter.writeStruct(BasicMessage {.messageType = 2 });
    std.debug.print("Wrote 2\n", .{});

    _ = try waitForResponse(&tcpReader, MessageType.UnChocke);
    try stdout.print("Peer ID: {s}", .{std.fmt.fmtSliceHexLower(res.peerId[0..])});
}

fn waitForResponse(tcpReader: *const std.io.AnyReader, expectedResponse: MessageType) !BasicMessage {


    while (true) {
        const message = try getNextMessage(tcpReader);

        if(message.messageType == @intFromEnum(expectedResponse))
            return message;

    }
}
fn getNextMessage(tcpReader: *const std.io.AnyReader) !BasicMessage {
    var len: u32 = 0;
    while(len == 0) {
        
        std.debug.print("WTF bits: {d} \n", .{@divExact(@typeInfo(u32).int.bits, 8)});
        //const bytes = try tcpReader.*.readBytesNoEof(4);
        //len = std.mem.readInt(u32, &bytes, .big);
        len = try tcpReader.*.readInt(u32, .big);
    }

    const bytes = try tcpReader.*.readBytesNoEof(1);
    const messageType: MessageType = @enumFromInt(std.mem.readInt(u8, &bytes, .big));

        std.debug.print("Byte: {any} Len: {d}\n", .{messageType, len});
    len -= 1;

    try tcpReader.skipBytes(len, .{});
    return BasicMessage { .messageType = @intFromEnum(messageType)};


}
const Handshake = extern struct {
    protocolLength: u8 = 19,

    ident: [19]u8 = "BitTorrent protocol".*,

    reserved: [8]u8 = std.mem.zeroes([8]u8),

    infoHash: [20]u8,

    peerId: [20]u8,
};

const BasicMessage = extern struct {
    messageType: u8
};

const BitfieldMessage = struct {
    messageType: MessageType,
    bitfield: u4
};
const MessageType = enum { Choke, UnChocke, Interested, NotInterested, Have, Bitfield, Request, Piece, Cancel };

fn lessthan(_: void, lhs: []const u8, rhs: []const u8) bool {
    return std.mem.order(u8, lhs, rhs) == .lt;
}
