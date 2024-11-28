const std = @import("std");

pub fn getNextValue(input: []const u8, pos: *usize, allocator: std.mem.Allocator) ParserError!BencodeValue {
    switch (input[pos.*]) {
        'i' => {
            return getInteger(input, pos);
        },
        'l' => {
            return getList(input, pos, allocator);
        },
        'd' => {
            return getDictionary(input, pos, allocator);
        },
        '0'...'9' => {
            return getString(input, pos);
        },
        else => {
            std.log.err("Failed parsing {s} with pos {d}", .{ input, pos.* });
            return ParserError.InvalidArgument;
        },
    }
}

fn getInteger(input: []const u8, pos: *usize) ParserError!BencodeValue {
    pos.* += 1;
    var end = std.mem.indexOf(u8, input[pos.*..], "e") orelse return ParserError.InvalidArgument;

    end += pos.*;
    var intValue: i64 = 0;

    if (input[pos.*] == '-') {
        for (input[pos.* + 1 .. end]) |char| {
            intValue = (intValue * 10) - (char - '0');
        }
    } else {
        for (input[pos.*..end]) |char| {
            intValue = (intValue * 10) + char - '0';
        }
    }
    pos.* = end + 1;
    return BencodeValue{ .int = intValue };
}
fn getString(input: []const u8, pos: *usize) ParserError!BencodeValue {
    std.debug.print("reading string in '{s}'\n", .{input[pos.*..]});
    var firstColon = std.mem.indexOf(u8, input[pos.*..], ":") orelse unreachable;
    firstColon += pos.*;
    const len = getInt(input[pos.*..firstColon]);

    pos.* = firstColon + len + 1;
    return BencodeValue{ .string = input[firstColon + 1 .. pos.*] };
}
fn getList(input: []const u8, pos: *usize, allocator: std.mem.Allocator) ParserError!BencodeValue {
    var bencodedArray = std.ArrayList(BencodeValue).init(allocator);
    defer bencodedArray.deinit();
    pos.* += 1;
    while (true) {
        const peek = input[pos.*];
        if(peek == 'e') {
            break;
        }
        const b = try getNextValue(input, pos, allocator);
        bencodedArray.append(b) catch return ParserError.AllocatorError;
    }
    const a = bencodedArray.toOwnedSlice() catch return ParserError.AllocatorError;
    pos.* += 1;
    return BencodeValue{ .array = a };
}

fn getDictionary(input: []const u8, pos: *usize, allocator: std.mem.Allocator) ParserError!BencodeValue {
    pos.* += 1;
    var dict = std.StringArrayHashMap(BencodeValue).init(allocator);

    var  isArray:u8 = 0;
    while (true) {
        const peek = input[pos.*];
        if(peek == 'e') {
            break;
        }
        const key = try getString(input, pos);
        const value = try getNextValue(input, pos, allocator);
        switch (value) {
            BencodedType.array => {
                isArray = 1;
            },
            else => {},
        }
        dict.put(key.string, value) catch return ParserError.AllocatorError;
    }

    pos.* += 1;
    return BencodeValue{ .dictionary = dict };
}

pub fn getInt(digits: []const u8) usize {
    var int: usize = 0;
    for (digits) |char| {
        int = (int * 10) + char - '0';
    }
    return int;
}
pub const BencodedType = enum { int, string, array, dictionary };
pub const BencodeValue = union(BencodedType) {
    int: i64,
    string: []const u8,
    array: []BencodeValue,
    dictionary: std.StringArrayHashMap(BencodeValue),
};
pub const ParserError = error{ InvalidArgument, AllocatorError };

test "Parse string return string" {
    const alloc = std.testing.allocator;
    const testValue = "6:catmat";
    var pos: usize = 0;
    const result = try getNextValue(testValue, &pos, alloc);
    try std.testing.expectEqualStrings(result.string, "catmat");
    try std.testing.expectEqual(pos, testValue.len);
}
test "Parse int return int" {
    const alloc = std.testing.allocator;
    const testValue = "i3232e";
    var pos: usize = 0;
    const result = try getNextValue(testValue, &pos, alloc);
    try std.testing.expectEqual(result.int, 3232);
    try std.testing.expectEqual(pos, testValue.len);
}
test "Parse list with intreturn int" {
    const alloc = std.testing.allocator;
    const testValue = "li3232ee";
    var pos: usize = 0;
    const arr = try getNextValue(testValue, &pos, alloc);
    defer alloc.free(arr.array);
    try std.testing.expectEqual(arr.array[0].int, 3232);
    try std.testing.expectEqual(pos, testValue.len);
}

test "Parse list with int and string" {
    const alloc = std.testing.allocator;
    const testValue = "li3232e10:piineapplee";
    var pos: usize = 0;
    const arr = try getNextValue(testValue, &pos, alloc);

    try std.testing.expectEqual(arr.array[0].int, 3232);
    try std.testing.expectEqual(arr.array.len, 2);
    try std.testing.expectEqual(pos, testValue.len);
    defer alloc.free(arr.array);
}
test "Parse dict with int and string" {
    const alloc = std.testing.allocator;
    const testValue = "d10:piineapplei3232ee";
    var pos: usize = 0;
    var b = try getNextValue(testValue, &pos, alloc);

    const res = b.dictionary.get("piineapple").?;
    defer b.dictionary.clearAndFree();
    try std.testing.expectEqual(res.int, 3232);
    try std.testing.expectEqual(pos, testValue.len);
}
