const std = @import("std");
const reader = @import("streamreader.zig");
const writer = @import("bencodeWriter.zig");
const sha = std.crypto.hash.Sha1;
const stdout = std.io.getStdOut().writer();
const Headers = std.http.Headers;
var allocator = std.heap.page_allocator;
var pieceIndex: u32 = 0;
var filePath: []u8 = undefined;

pub fn main() !void {
    const args = try std.process.argsAlloc(allocator);
    defer std.process.argsFree(allocator, args);

    if (args.len < 3) {
        try stdout.print("Usage: your_bittorrent.zig <command> <args>\n", .{});
        std.process.exit(1);
    }

    const command = args[1];

    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const alloca = arena.allocator();
    const option = args[2];
    var position: usize = 0;
    if (std.mem.eql(u8, command, "decode")) {
        const b = reader.getNextValue(option, &position, alloca) catch {
            try stdout.print("Invalid encoded value\n", .{});
            std.process.exit(1);
        };
        try printBencode(b);
        try stdout.print("\n", .{});
    }
    if (std.mem.eql(u8, command, "info")) {
        var file = try std.fs.cwd().openFile(option, .{});
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
        var file = try std.fs.cwd().openFile(option, .{});
        const encodedStr = try file.readToEndAlloc(allocator, 1024 * 1024);
        const b = reader.getNextValue(encodedStr, &position, alloca) catch {
            try stdout.print("Invalid encoded value\n", .{});
            std.process.exit(1);
        };
        defer file.close();

        _ = try getTorrent(b, alloca);
        try stdout.print("\n", .{});
    }

    if (std.mem.eql(u8, command, "handshake")) {
        const fileArg = option;
        const peer = args[3];
        var file = try std.fs.cwd().openFile(fileArg, .{});
        const encodedStr = try file.readToEndAlloc(allocator, 1024 * 1024);
        var b = reader.getNextValue(encodedStr, &position, alloca) catch {
            try stdout.print("Invalid encoded value\n", .{});
            std.process.exit(1);
        };
        defer file.close();

        var ip: std.net.Ip4Address = undefined;
        {
            var port: u16 = 0;
            const i = std.mem.indexOf(u8, peer, ":").?;
            for (peer[i + 1 ..]) |char| {
                if (char == undefined) {
                    break;
                }
                std.debug.print("Char in port {c}\n", .{char});
                port = port * 10 + (char - '0');
            }
            ip = try std.net.Ip4Address.parse(peer[0..i], port);
        }

        var requests: [1]*const TcpFunction = .{&getHandshake};
        try sendRequests(&b, ip, alloca, requests[0..]);
        try stdout.print("\n", .{});
    }
    if (std.mem.eql(u8, command, "download_piece")) {
        const output = args[3];
        const torrent = args[4];
        const piece = args[5];
        filePath = output;
        

        pieceIndex = try std.fmt.parseInt(u32, piece, 10);

        var file = try std.fs.cwd().openFile(torrent, .{});
        const encodedStr = try file.readToEndAlloc(allocator, 1024 * 1024);
        var b = reader.getNextValue(encodedStr, &position, alloca) catch {
            try stdout.print("Invalid encoded value\n", .{});
            std.process.exit(1);
        };
        defer file.close();
        const ip = try getTorrent(b, alloca);
        

        var requests: [2]*const TcpFunction = .{ &getHandshake, &getPiece };
        try sendRequests(&b, ip, alloca, requests[0..]);
        try stdout.print("\n", .{});
        std.debug.print("Downloading piece for output {s} torret {s} piece index {d}\n", .{ output, torrent, piece });
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

fn getTorrent(input: reader.BencodeValue, alloc: std.mem.Allocator) !std.net.Ip4Address {
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
            var ba: [2]u8 = undefined;
            ba[0] = aw[0];
            ba[1] = aw[1];
            const parsedPort = std.mem.readInt(u16, &ba, std.builtin.Endian.big);

            const address = .{ slice[0], slice[1], slice[2], slice[3] };
            try stdout.print("{d}.{d}.{d}.{d}:{d}\n", .{ slice[0], slice[1], slice[2], slice[3], parsedPort });
            return std.net.Ip4Address.init(address, parsedPort);
        }
    }
    return RequestError.NoIP;
}

const TcpFunction = fn (tcpReader: std.io.AnyReader, tcpWriter: std.io.AnyWriter, input: *reader.BencodeValue, alloc: std.mem.Allocator) RequestError!void;
fn sendRequests(input: *reader.BencodeValue, sampleIp: std.net.Ip4Address, alloc: std.mem.Allocator, requests: []*const TcpFunction) !void {
    const c = std.net.Address{ .in = sampleIp };
    const conn = try std.net.tcpConnectToAddress(c);

    std.debug.print("Post close\n", .{});
    defer conn.close();

    const tcpReader = conn.reader().any();
    const tcpwriter = conn.writer().any();
    for (requests) |request| {
        try request(tcpReader, tcpwriter, input, alloc);
    }
}
const RequestError = error{ TcpConnection, TcpWriter, TcpResponse, BencodeParser, NoIP, FileErr };

fn getHandshake(tcpReader: std.io.AnyReader, tcpWriter: std.io.AnyWriter, input: *reader.BencodeValue, alloc: std.mem.Allocator) RequestError!void {
    if (input.* != reader.BencodedType.dictionary) {
        return error.BencodeParser;
    }

    const metadata = input.*.dictionary.get("info").?;

    if (metadata != reader.BencodedType.dictionary) {
        return error.BencodeParser;
    }

    //const pieceLength = metadata.dictionary.get("piece length").?;
    //const pieces = metadata.dictionary.get("pieces").?.string;
    const bencodedInfo = writer.bencode(&metadata, alloc) catch {
        return RequestError.BencodeParser;
    };

    var sha1: [20]u8 = undefined;
    sha.hash(bencodedInfo, &sha1, sha.Options{});

    const handshake = Handshake{ .infoHash = sha1, .peerId = "00112233445566778891".* };
    tcpWriter.writeStruct(handshake) catch {
        return RequestError.TcpConnection;
    };

    _ = tcpReader.readStruct(Handshake) catch {
        return RequestError.TcpConnection;
    };
    _ = waitForResponse(&tcpReader, MessageType.Bitfield) catch {
        return RequestError.TcpResponse;
    };

    tcpWriter.writeInt(u32, 1, .big) catch {
        return RequestError.TcpWriter;
    };
    tcpWriter.writeByte(2) catch {
        return RequestError.TcpWriter;
    };

    _ = waitForResponse(&tcpReader, MessageType.UnChocke) catch {
        return RequestError.TcpResponse;
    };
    //_ = stdout.print("Peer ID: {s}", .{std.fmt.fmtSliceHexLower(res.peerId[0..])});
}

fn getPiece(tcpReader: std.io.AnyReader, tcpWriter: std.io.AnyWriter, input: *reader.BencodeValue, alloc: std.mem.Allocator) RequestError!void {
    if (input.* != reader.BencodedType.dictionary) {
        return error.BencodeParser;
    }

    const metadata = input.*.dictionary.get("info").?;

    if (metadata != reader.BencodedType.dictionary) {
        return error.BencodeParser;
    }

    //const pieceLength = metadata.dictionary.get("piece length").?;
    //const pieces = metadata.dictionary.get("pieces").?.string;
    const bencodedInfo = writer.bencode(&metadata, alloc) catch {
        return RequestError.BencodeParser;
    };

    var sha1: [20]u8 = undefined;
    sha.hash(bencodedInfo, &sha1, sha.Options{});

    const pieces = metadata.dictionary.get("pieces").?;
    const pieceLength = metadata.dictionary.get("piece length").?.int;
    var length = metadata.dictionary.get("length").?.int;

    const count = pieces.string.len / 20;
    var downloadPerPieces = alloc.alloc(i64, count) catch {
        return RequestError.TcpConnection;
    };
    defer alloc.free(downloadPerPieces);

    {
        for (0..count) |i| {
            if (length > pieceLength) {
                downloadPerPieces[i] = pieceLength;
                length -= pieceLength;
            } else {
                downloadPerPieces[i] = length;
                length -= length;
            }
        }
    }

    std.debug.print("SIZE {any}", .{downloadPerPieces});
    const downloadForPiece = downloadPerPieces[pieceIndex];
    var totalDownloadSize: u32 = 0;
    const castedPieceLength: u32 = @intCast(downloadForPiece);
    const file = std.fs.cwd().createFile(
        filePath,
        .{ .read = true },
    ) catch {
        return RequestError.FileErr;
    };
    while (totalDownloadSize < downloadForPiece) {
        var take: u32 = 16 * 1024;
        if (take + totalDownloadSize > castedPieceLength) {
            take = castedPieceLength - totalDownloadSize;
        }
        std.debug.print("Size {d} Index {d} begin {d} length {d}\n", .{ castedPieceLength, pieceIndex, totalDownloadSize, take });

        tcpWriter.writeInt(u32, 13, .big) catch {
            return RequestError.TcpWriter;
        };

        tcpWriter.writeByte(6) catch {
            return RequestError.TcpWriter;
        };

        tcpWriter.writeInt(u32, pieceIndex, .big) catch {
            return RequestError.TcpWriter;
        };
        tcpWriter.writeInt(u32, totalDownloadSize, .big) catch {
            return RequestError.TcpWriter;
        };
        tcpWriter.writeInt(u32, take, .big) catch {
            return RequestError.TcpWriter;
        };

        const response = waitForResponse(&tcpReader, MessageType.Piece) catch {
            return RequestError.TcpResponse;
        };
        std.debug.print("Prefile {s}\n", .{filePath});
        std.debug.print("postfile {s}\n", .{filePath});
        _ = file.write(response.body) catch {
            return RequestError.FileErr;
        };
        totalDownloadSize += take;
    }
}

fn waitForResponse(tcpReader: *const std.io.AnyReader, expectedResponse: MessageType) !BasicMessage {
    while (true) {
        const message = try getNextMessage(tcpReader);

        if (message.messageType == @intFromEnum(expectedResponse)) {
            return message;
        } else {
            std.debug.print("Unknown message {d}", .{message.messageType});
        }
    }
}
fn getNextMessage(tcpReader: *const std.io.AnyReader) !BasicMessage {
    var len: u32 = 0;
    while (len == 0) {
        std.debug.print("WTF bits: {d} \n", .{@divExact(@typeInfo(u32).Int.bits, 8)});
        //const bytes = try tcpReader.*.readBytesNoEof(4);
        //len = std.mem.readInt(u32, &bytes, .big);
        len = try tcpReader.*.readInt(u32, .big);
    }

    const bytes = try tcpReader.*.readBytesNoEof(1);
    const messageType: MessageType = @enumFromInt(std.mem.readInt(u8, &bytes, .big));

    len -= 1;
    const body = try allocator.alloc(u8, len);

    for (0..len) |i| {
        body[i] = try tcpReader.readByte();
    }
    //const body = try tcpReader.*.readAllAlloc(allocator, len);
    //std.debug.print("Left in response body {any}", .{body});

    return BasicMessage{ .size = len, .messageType = @intFromEnum(messageType), .body = body };
}

const Handshake = extern struct {
    protocolLength: u8 = 19,

    ident: [19]u8 = "BitTorrent protocol".*,

    reserved: [8]u8 = std.mem.zeroes([8]u8),

    infoHash: [20]u8,

    peerId: [20]u8,
};

const BasicMessage = struct { size: u32, messageType: u8, body: []u8 };
const RequestMessage = extern struct { size: u32, messageType: u8, index: u32, begin: u32, length: u32 };
const RequestMessageClean = extern struct { index: u32, begin: u32, length: u32 };

const BitfieldMessage = struct { messageType: MessageType, bitfield: u4 };
const MessageType = enum(u8) { Choke, UnChocke, Interested, NotInterested, Have, Bitfield, Request, Piece, Cancel };

fn lessthan(_: void, lhs: []const u8, rhs: []const u8) bool {
    return std.mem.order(u8, lhs, rhs) == .lt;
}
