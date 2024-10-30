const std = @import("std");
const reader = @import("streamreader.zig");
const writer = @import("bencodeWriter.zig");
const sha = std.crypto.hash.Sha1;
const stdout = std.io.getStdOut().writer();
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
            try stdout.print("{s}\n", .{std.fmt.fmtSliceHexLower(pieces[i..i+20])});
            i +=20;
        }
    }
}

fn lessthan(_: void, lhs: []const u8, rhs: []const u8) bool {
    return std.mem.order(u8, lhs, rhs) == .lt;
}
