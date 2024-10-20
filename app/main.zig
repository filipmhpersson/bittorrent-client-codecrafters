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
        try printBencode(decodedStr);
        try stdout.print("\n", .{});
    }
}

fn printBencode(bencodedValue: BencodeValue) !void {
    switch (bencodedValue) {
        .string => {
            var string = std.ArrayList(u8).init(allocator);
            try std.json.stringify(bencodedValue.string, .{}, string.writer());
            const jsonStr = try string.toOwnedSlice();
            try stdout.print("{s}", .{jsonStr});
        },
        .int => {
            try stdout.print("{d}", .{bencodedValue.int});
        },
        .array => {
            try stdout.print("[", .{});

            for (bencodedValue.array, 0..) |item, i| {
                try printBencode(item);
                if(i < bencodedValue.array.len - 1) {
                    try stdout.print(", ", .{});
                }
            }
            try stdout.print("]", .{});
        },
    }
}
fn decodeBencode(encodedValue: []const u8) !BencodeValue {
    std.debug.print("Decoding {s}\n", .{encodedValue});
    if (encodedValue[0] >= '0' and encodedValue[0] <= '9') {
        const firstColon = std.mem.indexOf(u8, encodedValue, ":");
        if (firstColon == null) {
            return error.InvalidArgument;
        }
        return BencodeValue{ .string = encodedValue[firstColon.? + 1 ..] };
    } else if (encodedValue[0] == 'i' ) {
        if(encodedValue[encodedValue.len - 1] != 'e') {
            std.debug.print("Expected {d} but got {d}\n", .{'e', encodedValue[encodedValue.len - 1]});
            return error.InvalidArgument;
        }
        var intValue: i64 = 0;

        if(encodedValue[1] == '-') {
            for(encodedValue[2..encodedValue.len-1]) |char| {
                intValue = (intValue * 10) - (char - '0');
            }
        } else {
            for(encodedValue[1..encodedValue.len-1]) |char| {
                intValue = (intValue * 10) + char - '0';
            }
        }
        return BencodeValue{ .int = intValue };
    } else if(encodedValue[0] == 'l' and encodedValue[encodedValue.len - 1] == 'e') {

        var i:usize = 1;
        var bencodedArray = std.ArrayList(BencodeValue).init(allocator);

        std.debug.print("Parsing bencoded list", .{});
        while(i < encodedValue.len - 1) {
            const curr = encodedValue[i];
            std.debug.print("Iterating encoded value at index {d} with value {d}\n", .{ i,  curr});
            if(curr >= '0' and curr <= '9') {
                var firstColon = std.mem.indexOf(u8, encodedValue[i..], ":")  orelse unreachable;
                firstColon += i;
                const len = getInt(encodedValue[i..firstColon]);
                std.debug.print("For text {s} Parsing string colon  {d}, with len {d} and index {d}\n", .{ encodedValue, firstColon, len, i});
                const decodedText = try decodeBencode(encodedValue[i..len + firstColon + 1]);
                try bencodedArray.append(decodedText);
                i = firstColon + len + 1;

            } else if (curr == 'i'){

                const firstEnd = std.mem.indexOf(u8, encodedValue[i..], "e");
                
                if (firstEnd) |end| {
                    std.debug.print("Parsing int with end {d}\n", .{ end });
                    const obj = try decodeBencode(encodedValue[i..end + i + 1]);
                    try bencodedArray.append(obj);
                    i += end + 1;
                } else {
                    try stdout.print("Cannot find end for int in array\n", .{});
                    std.process.exit(1);
                }
            } 
            else if (curr == 'l') {
                const innerListIndex = std.mem.lastIndexOf(u8, encodedValue[i..encodedValue.len - 1], "ee") orelse unreachable;
                std.debug.print("Found inner list, end index {d}\n", .{innerListIndex});

                const obj = try decodeBencode(encodedValue[i..innerListIndex + i + 2]);
                try bencodedArray.append(obj);
                std.debug.print("Done inner", .{});
                i += innerListIndex + 2;
            }
            else {
                    try stdout.print("Only strings and ints allowed in arrays\n", .{});
                    std.process.exit(1);
            }
        }
            const slice = try bencodedArray.toOwnedSlice();
            return BencodeValue{.array = slice};
    }
    else {
        try stdout.print("Only strings are supported at the moment, you send value {d}\n", .{encodedValue[0]});
        std.process.exit(1);
    }
}

fn getInt(digits: [] const u8) usize {

    var int:usize = 0;
    for(digits) |char| {
        int = (int * 10) + char - '0';
    }
    return int;

}


const BencodedType = enum { int, string, array };
const BencodeValue = union(BencodedType){
    int: i64,
    string: []const u8,
    array: []const BencodeValue
};
