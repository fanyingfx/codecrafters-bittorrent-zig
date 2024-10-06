const std = @import("std");
const page_allocator = std.heap.page_allocator;
pub const ParseError = error{
    ElementError,
    IntgerError,
    StringError,
    ListError,
    DictError,
    Overflow,
    InvalidCharacter,
    OutOfMemory,
};
pub const QueryError = error{ NotDict, QueryFailed };
pub const BElement = union(enum) {
    pub const DictItem = struct { key: []const u8, value: BElement };
    pub const Dict = []DictItem;
    str: []const u8,
    integer: i64,
    list: []BElement,
    dict: Dict,

    pub fn toString(self: *const BElement, allocator: std.mem.Allocator) ![]const u8 {
        var string = std.ArrayList(u8).init(allocator);

        switch (self.*) {
            .str => |v| {
                try string.append('"');
                try string.appendSlice(v);
                try string.append('"');
            },
            .integer => |i| {
                var buf: [1000]u8 = undefined;
                const num_str = try std.fmt.bufPrint(&buf, "{}", .{i});
                try string.appendSlice(num_str);
            },
            .list => |l| {
                var list_str = std.ArrayList(u8).init(allocator);
                // defer list_str.deinit();
                try list_str.append('[');
                for (l) |v| {
                    try list_str.appendSlice(try v.toString(allocator));
                    try list_str.append(',');
                }
                if (list_str.getLast() == ',') {
                    _ = list_str.pop();
                }
                try list_str.append(']');
                try string.appendSlice(list_str.items);
            },
            .dict => |pairs| {
                var list_str = std.ArrayList(u8).init(allocator);
                try list_str.append('{');
                for (pairs) |pair| {
                    try list_str.append('"');
                    try list_str.appendSlice(pair.key);
                    try list_str.append('"');
                    try list_str.append(':');
                    try list_str.appendSlice(try pair.value.toString(allocator));
                    try list_str.append(',');
                }
                if (list_str.getLast() == ',') {
                    _ = list_str.pop();
                }
                try list_str.append('}');
                // std.debug.print("dict_str:{s}\n",.{list_str.items});
                try string.appendSlice(list_str.items);
            },
        }

        return string.toOwnedSlice();
    }
    pub fn queryDict(self: *const BElement, key: []const u8) !BElement {
        switch (self.*) {
            .dict => |pairs| {
                for (pairs) |pair| {
                    if (std.mem.eql(u8, pair.key, key)) {
                        return pair.value;
                    }
                }
            },
            else => return QueryError.NotDict,
        }
        return QueryError.QueryFailed;
    }
};
pub const BContext = struct {
    const Self = @This();

    idx: usize,
    content: []const u8,
    allocator: std.mem.Allocator,

    pub fn current_char(self: *const Self) ?u8 {
        if (self.idx >= self.content.len) {
            return null;
        }
        return self.content[self.idx];
    }
    pub fn peek_next_char(self: *const Self) ?u8 {
        if ((self.idx + 1) >= self.content.len) {
            return null;
        }
        if ((self.idx + 1) < self.content.len) {
            return self.content[self.idx + 1];
        }
        return null;
    }
    pub fn advance(self: *Self) u8 {
        defer self.idx += 1;
        return self.current_char().?;
    }
};

fn encodeStr(str: []const u8, allocator: std.mem.Allocator) ![]u8 {
    var string = std.ArrayList(u8).init(allocator);
    var buf: [256]u8 = undefined;
    const num_str = try std.fmt.bufPrint(&buf, "{}:", .{str.len});
    try string.appendSlice(num_str);
    try string.appendSlice(str);
    return string.toOwnedSlice();
}
pub fn encodeElement(element: BElement, allocator: std.mem.Allocator) ![]u8 {
    var string = std.ArrayList(u8).init(allocator);
    var buf: [256]u8 = undefined;
    switch (element) {
        .str => |strVal| {
            // const num_str = try std.fmt.bufPrint(&buf, "{}:", .{strVal.len});
            // try string.appendSlice(num_str);
            // try string.appendSlice(strVal);
            try string.appendSlice(try encodeStr(strVal,allocator));
        },
        .integer => |intVal| {
            const int_encode = try std.fmt.bufPrint(&buf, "i{}e", .{intVal});
            try string.appendSlice(int_encode);
        },
        .list => |listVal| {
            try string.append('l');
            for (listVal) |ele| {
                try string.appendSlice(try encodeElement(ele,allocator));
            }
            try string.append('e');
        },
        .dict => |dictVal| {
            try string.append('d');
            for (dictVal) |pair| {
                // encode key
                // const num_str = try std.fmt.bufPrint(&buf, "{}:", .{pair.key.len});
                // try string.appendSlice(num_str);
                // try string.appendSlice(pair.key);
                try string.appendSlice(try encodeStr(pair.key,allocator));
                // encode val
                try string.appendSlice(try encodeElement(pair.value,allocator));
            }
            try string.append('e');
        },
    }
    return try string.toOwnedSlice();
}
fn decodeElement(context: *BContext) ParseError!BElement {
    switch (context.current_char().?) {
        '0'...'9' => return try decodeString(context),
        'i' => return try decodeInteger(context),
        'l' => return try decodeList(context),
        'd' => return try decodeDict(context),
        else => {
            return ParseError.ElementError;
        },
    }
}

pub fn decodeBencode(context: *BContext) ParseError!BElement {
    return try decodeElement(context);
}
fn decodeInteger(context: *BContext) ParseError!BElement {
    context.idx += 1;
    // const num_str = encodedValue[1..(encodedValue.len - 1)];
    const current_char = context.current_char();
    if ((current_char == '0' and context.peek_next_char() != 'e') or
        (current_char == '-' and context.peek_next_char() == '0') or
        current_char == 'e')
    {
        return ParseError.IntgerError;
    }
    var num_str = std.ArrayList(u8).init(context.allocator);
    defer num_str.deinit();
    while (context.current_char() != 'e') {
        if (0 <= context.current_char().? and context.current_char().? <= '9') {
            try num_str.append(context.advance());
        } else {
            return ParseError.IntgerError;
        }
    }
    const num = try std.fmt.parseInt(i64, num_str.items, 10);
    context.idx += 1;
    return BElement{ .integer = num };
}
fn decodeString(context: *BContext) ParseError!BElement {
    // 3:hel 1
    const colon_offset = std.mem.indexOf(u8, context.content[context.idx..], ":");
    if (colon_offset == null) {
        return ParseError.StringError;
    }
    const colon_idx = context.idx + colon_offset.?;
    // std.debug.print("colon_idx:{},num:{s}\n",.{colon_idx,context.content[context.idx..colon_idx]});
    const length = try std.fmt.parseInt(u32, context.content[context.idx..colon_idx], 10);
    defer context.idx += colon_offset.? + length + 1;
    const str_dup = try std.heap.page_allocator.dupe(u8, context.content[colon_idx + 1 .. colon_idx + length + 1]);
    return BElement{ .str = str_dup };
}
fn decodeList(context: *BContext) ParseError!BElement {
    context.idx += 1; // for 'i'
    var BElementList = std.ArrayList(BElement).init(context.allocator);
    while (context.current_char().? != 'e') {
        try BElementList.append(try decodeElement(context));
    }
    // std.debug.print("current_list: {s}\n", .{CMDList.items[0].str});
    if (context.current_char() != 'e') {
        return ParseError.ListError;
    }
    context.idx += 1; // for 'e'
    return BElement{ .list = try BElementList.toOwnedSlice() };
}
fn decodeDict(context: *BContext) ParseError!BElement {
    context.idx += 1;
    var BElementDict = std.ArrayList(BElement.DictItem).init(context.allocator);
    while (context.current_char().? != 'e') {
        const key = try decodeString(context);
        const value = try decodeElement(context);
        switch (key) {
            .str => |key_str| {
                const ele = BElement.DictItem{ .key = key_str, .value = value };
                try BElementDict.append(ele);
            },
            else => return ParseError.DictError,
        }
    }
    if (context.current_char() != 'e') {
        return ParseError.DictError;
    }
    context.idx += 1;

    return BElement{ .dict = try BElementDict.toOwnedSlice() };
}
