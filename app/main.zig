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
        defer file.close();

        var buf_reader = std.io.bufferedReader(file.reader());
        var in_stream = buf_reader.reader();

        var buf: [1024]u8 = undefined;
        while (try in_stream.readUntilDelimiterOrEof(&buf, '\n')) |line| {
                std.debug.print("Starting next value, with input {s}", .{line});
            const b = reader.getNextValue(line, &position, alloca) catch {
                try stdout.print("Invalid encoded value\n", .{});
                std.process.exit(1);
            };
            try printTorrent(b,alloca);
            try stdout.print("\n", .{});
        }
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
    const bencodedInfo = try writer.bencode(&metadata, alloc);

    var sha1: [20]u8 = undefined;
    sha.hash(bencodedInfo, &sha1, sha.Options{});

    try stdout.print("Tracker URL: {s}\n", .{url.string});
    try stdout.print("Length: {d}\n", .{length.int});
    try stdout.print("Info Hash: ", .{});
    for(sha1) |char| {
        try stdout.print("{x}", .{char});
    }
}

fn lessthan(_: void, lhs: []const u8, rhs: []const u8) bool {
    return std.mem.order(u8, lhs, rhs) == .lt;
}
