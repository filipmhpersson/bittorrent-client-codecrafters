const std = @import("std");
const reader = @import("streamreader.zig");
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
            var k = d.keyIterator();
            var array = std.ArrayList([]const u8).init(allocator);

            defer array.deinit();
            while (k.next()) |key| {
                try array.append(key.*);
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
                    try stdout.print(", ", .{});
                }
            }
            try stdout.print("]", .{});
        },
    }
}
fn lessthan(_: void, lhs: []const u8, rhs: []const u8) bool {
    return std.mem.order(u8, lhs, rhs) == .lt;
}
