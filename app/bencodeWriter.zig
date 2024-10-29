const std = @import("std");
const reader = @import("streamreader.zig");

pub fn bencode(bencodedValue: *const reader.BencodeValue, allocator: std.mem.Allocator) ![]u8 {
    switch (bencodedValue.*) {
        reader.BencodedType.int => {
            var buf: [256]u8 = undefined;
            const str = try std.fmt.bufPrint(&buf, "{}", .{bencodedValue.*.int});

            var array = try allocator.alloc(u8, str.len + 2);
            array[0] = 'i';
            for (str, 1..) |char, i| {
                array[i] = char;
            }
            array[str.len + 1] = 'e';

            return array;
        },
        reader.BencodedType.string => {
            var buf: [256]u8 = undefined;
            const str = try std.fmt.bufPrint(&buf, "{}", .{bencodedValue.*.string.len});
            var array = try allocator.alloc(u8, bencodedValue.*.string.len + 1 + str.len);

            for (str, 0..) |char, i| {
                array[i] = char;
            }
            array[str.len] = ':';

            for (bencodedValue.*.string, str.len + 1..) |char, i| {
                array[i] = char;
            }
            return array;
        },
        reader.BencodedType.array => {
            var size: usize = 2;
            var resultStrings = try allocator.alloc([]u8, bencodedValue.*.array.len);
            defer allocator.free(resultStrings);

            for (bencodedValue.*.array, 0..) |value, i| {
                resultStrings[i] = try bencode(&value, allocator);
                size += resultStrings[i].len;
            }
            var array = try allocator.alloc(u8, size);
            array[0] = 'l';
            array[size - 1] = 'e';
            var i: usize = 1;
            for (resultStrings) |string| {
                var j = i;
                for (string) |char| {
                    array[j] = char;
                    j += 1;
                }
                i = j;
                allocator.free(string);
            }
            return array;
        },
        reader.BencodedType.dictionary => {
            var resultStrings = try allocator.alloc([]u8, bencodedValue.*.dictionary.count() * 2);

            defer allocator.free(resultStrings);

            var iter = bencodedValue.*.dictionary.iterator();
            var size: usize = 2;
            {
                var i: usize = 0;
                while (iter.next()) |item| {
                    const b = reader.BencodeValue{ .string = item.key_ptr.* };
                    const key = try bencode(&b, allocator);
                    const val = try bencode(item.value_ptr, allocator);
                    resultStrings[i] = key;
                    resultStrings[i + 1] = val;
                    size += key.len;
                    size += val.len;
                    i += 2;
                }
            }
            var array = try allocator.alloc(u8, size);
            array[0] = 'd';
            array[size - 1] = 'e';
            var i: usize = 1;
            for (resultStrings) |string| {
                var j = i;
                for (string) |char| {
                    array[j] = char;
                    j += 1;
                }
                i = j;
                allocator.free(string);
            }
            return array;
        },
    }
    return error.InvalidArgument;
}
test "Bencode int" {
    var b = reader.BencodeValue{ .int = 10 };
    const alloc = std.testing.allocator;
    const e = try bencode(&b, alloc);
    defer alloc.free(e);
    try std.testing.expectEqualStrings("i10e", e);
}
test "Bencode string" {
    var b = reader.BencodeValue{ .string = "hello" };
    const alloc = std.testing.allocator;
    const e = try bencode(&b, alloc);
    defer alloc.free(e);
    try std.testing.expectEqualStrings("5:hello", e);
}

test "Bencode string long" {
    var b = reader.BencodeValue{ .string = "hellohello" };
    const alloc = std.testing.allocator;
    const e = try bencode(&b, alloc);
    defer alloc.free(e);
    try std.testing.expectEqualStrings("10:hellohello", e);
}

test "Bencode array" {
    const b = reader.BencodeValue{ .string = "hellohello" };
    var arr = [_]reader.BencodeValue{b};
    var l = reader.BencodeValue{ .array = &arr };
    const alloc = std.testing.allocator;
    const e = try bencode(&l, alloc);
    defer alloc.free(e);
    try std.testing.expectEqualStrings("l10:hellohelloe", e);
}

test "Bencode array multiple" {
    const b = reader.BencodeValue{ .string = "hellohello" };
    const c = reader.BencodeValue{ .int = 64 };
    var arr = [_]reader.BencodeValue{ b, c };
    var l = reader.BencodeValue{ .array = &arr };
    const alloc = std.testing.allocator;
    const e = try bencode(&l, alloc);
    defer alloc.free(e);
    try std.testing.expectEqualStrings("l10:hellohelloi64ee", e);
}

test "Bencode dictionary multiple" {
    const c = reader.BencodeValue{ .int = 64 };
    const alloc = std.testing.allocator;
    var hm = std.StringArrayHashMap(reader.BencodeValue).init(alloc);
    try hm.put("hellohello", c);
    var l = reader.BencodeValue{ .dictionary =  hm };
    const e = try bencode(&l, alloc);
    defer alloc.free(e);
    hm.clearAndFree();
    try std.testing.expectEqualStrings("d10:hellohelloi64ee", e);
}
