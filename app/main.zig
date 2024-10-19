const std = @import("std");
const stdout = std.io.getStdOut().writer();
const allocator = std.heap.page_allocator;

pub fn main() !void {
    const args = try std.process.argsAlloc(allocator);
    defer std.process.argsFree(allocator, args);

    if (args.len < 3) {
        try stdout.print("Usage: your_bittorrent.zig <command> <args>\n", .{});
        std.process.exit(1);
    }

    const command = args[1];

    if (std.mem.eql(u8, command, "decode")) {
        const encodedStr = args[2];
        const decodedStr = decodeBencode(encodedStr) catch {
            try stdout.print("Invalid encoded value\n", .{});
            std.process.exit(1);
        };
        switch (decodedStr.type) {
            BencodedType.string => {
                var string = std.ArrayList(u8).init(allocator);
                try std.json.stringify(decodedStr.value.*, .{}, string.writer());
                const jsonStr = try string.toOwnedSlice();
                try stdout.print("{s}\n", .{jsonStr});
            },
            BencodedType.int => {
                for (decodedStr.value.*) |char| {
                    try stdout.print("{d}", .{char - '0'});
                }
                try stdout.print("\n", .{});
            },
        }
    }
}

fn decodeBencode(encodedValue: []const u8) !BencodedValue {
    if (encodedValue[0] >= '0' and encodedValue[0] <= '9') {
        const firstColon = std.mem.indexOf(u8, encodedValue, ":");
        if (firstColon == null) {
            return error.InvalidArgument;
        }
        return BencodedValue{ .type = BencodedType.string, .value = &encodedValue[firstColon.? + 1 ..] };
    } else if (encodedValue[0] == 'i' and encodedValue[encodedValue.len - 1] == 'e') {
        return BencodedValue{ .type = BencodedType.int, .value = &encodedValue[1 .. encodedValue.len - 1] };
    } else {
        try stdout.print("Only strings are supported at the moment\n", .{});
        std.process.exit(1);
    }
}

const BencodedType = enum { string, int };

const BencodedValue = struct { type: BencodedType, value: *const []const u8 };
