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
        const encodedStr = args[2];
        const b = reader.getNextValue(encodedStr, &position, allocator) catch {
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
            if(!@inComptime()) {

            try stdout.print("{{", .{});
            var k = bencodedValue.dictionary.keyIterator();
            while(k.next()) |key| {

                var string = std.ArrayList(u8).init(allocator);
                try std.json.stringify(key.*, .{}, string.writer());
                const jsonStr = try string.toOwnedSlice();
                try stdout.print("{s}", .{jsonStr});
                try stdout.print(":", .{});
                try printBencode(bencodedValue.dictionary.get(key.*).?);
            }
            try stdout.print("}}", .{});
            }
        },
        .int => {
            try stdout.print("{d}", .{bencodedValue.int});
        },
        .array => {
            try stdout.print("[", .{});

            for (bencodedValue.array.*, 0..) |item, i| {
                try printBencode(item);
                if(i < bencodedValue.array.*.len - 1) {
                    try stdout.print(", ", .{});
                }
            }
            try stdout.print("]", .{});
        },
    }
}
