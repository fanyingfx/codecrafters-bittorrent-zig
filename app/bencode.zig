const std = @import("std");
const Allocator = std.mem.Allocator;
const expect = std.testing.expect;
pub const BElement = union(enum) {
    pub const DictItem = struct { key: []const u8, value: BElement };
    integer: i64,
    str: []const u8,
    list: []BElement,
    dict: []DictItem,
    pub fn query(self:*const BElement,key:[]const u8) BElement{
        std.debug.assert(self.* == .dict);
        for (self.dict)|pair|{
            if (std.mem.eql(u8,pair.key,key)){
                return pair.value;
            }
        }
        @panic("Key not exists");
    }
    pub fn deinit(self:*const BElement,allocator:Allocator) void{
        switch(self.*){
            .integer=>{},
            .str  =>  {
                // allocator.free(s);
            },
            .list => |l| {
                for(l)|ele|{
                    ele.deinit(allocator);
                }
                allocator.free(l);
            },
            .dict => |pairs|{
                for(pairs)|pair|{
                    // allocator.free(pair.key);
                    pair.value.deinit(allocator);
                }
                allocator.free(pairs);
            }
        }
    }

    pub fn toString(self: *const BElement, allocator: Allocator) ![]const u8 {
        var string = std.ArrayList(u8).init(allocator);
        const writer = string.writer();
        try writeString(self, writer);
        defer string.deinit();
        return string.toOwnedSlice();
    }
    fn writeString(self: *const BElement, writer: anytype) !void {
        switch (self.*) {
            .integer => |i| {
                try writer.print("{d}", .{i});
            },
            .str => |s| {
                try writer.print("\"{s}\"", .{s});
            },
            .list => |l| {
                try writer.writeByte('[');
                for (l, 0..) |e, i| {
                    try e.writeString(writer);
                    if (i < l.len - 1) { // skip the last element
                        try writer.writeByte(',');
                    }
                }
                try writer.writeByte(']');
            },
            .dict => |pairs| {
                try writer.writeByte('{');
                for (pairs, 0..) |pair, i| {
                    try writer.print("\"{s}\":", .{pair.key});
                    try pair.value.writeString(writer);
                    if (i < pairs.len - 1) {
                        try writer.writeByte(',');
                    }
                }
                try writer.writeByte('}');
            },
        }
    }
    pub fn encode(self: *const BElement, allocator: Allocator) ![]u8 {
        var string = std.ArrayList(u8).init(allocator);
        const writer = string.writer();
        try writeEncodeString(self, writer);
        defer string.deinit();
        return try string.toOwnedSlice();
    }
    fn writeEncodeString(self: *const BElement, writer: anytype) !void {
        switch (self.*) {
            .integer => |i| try writer.print("i{d}e", .{i}),
            .str => |s| try writer.print("{d}:{s}", .{ s.len, s }),
            .list => |l| {
                try writer.writeByte('l');
                for (l) |e| {
                    try e.writeEncodeString(writer);
                }
                try writer.writeByte('e');
            },
            .dict => |pairs| {
                try writer.writeByte('d');
                for (pairs) |pair| {
                    // pair.key
                    try writer.print("{d}:{s}", .{ pair.key.len, pair.key });
                    try pair.value.writeEncodeString(writer);
                }
                try writer.writeByte('e');
            },
        }
    }
};
pub const BEContext = struct {
    allocator: Allocator,
    content: []const u8,
    idx: usize = 0,

    fn currentChar(self: *const BEContext) u8 {
        return self.content[self.idx];
    }
    fn peekNext(self: *const BEContext) u8 {
        if ((self.idx + 1) >= self.content.len) {
            std.debug.panic("Peek failed\n", .{});
        }
        return self.content[self.idx + 1];
    }

    pub fn decode(context: *BEContext) BElement {
        switch (context.currentChar()) {
            '0'...'9' => return decodeString(context),
            'i' => return decodeInteger(context),
            'l' => return decodeList(context),
            'd' => return decodeDict(context),
            else => {
                std.debug.panic("Decode Failed!", .{});
            },
        }
    }
    fn decodeString(context: *BEContext) BElement {
        const content = context.content;

        const colon_offset = std.mem.indexOf(u8, content[context.idx..], ":");
        if (colon_offset == null) {
            std.debug.panic("Wrong string format!,", .{});
        }
        const colon_idx: usize = context.idx + colon_offset.?;
        const length = std.fmt.parseInt(u32, content[context.idx..colon_idx], 10) catch unreachable;
        defer context.idx = colon_idx + length + 1;

        // NOTE  the context should be live longer enough than all childern element in the later;
        // const str = context.allocator.dupe(u8,content[(colon_idx + 1)..(colon_idx + length + 1)]) catch unreachable;
        const str = content[(colon_idx + 1)..(colon_idx + length + 1)];
        return BElement{ .str = str };
    }
    fn decodeInteger(context: *BEContext) BElement {
        context.idx += 1; // skip 'i'
        defer context.idx += 1; // skip the end 'e'

        const cur_char = context.currentChar();
        const next_char = context.peekNext();
        if ((cur_char == '0' and next_char != 'e') or
            (cur_char == '-' and next_char == '0') or
            (cur_char == 'e'))
        {
            std.debug.panic("Wrong integer format", .{});
        }
        const num_start = context.idx;
        while (context.currentChar() != 'e') {
            switch (context.currentChar()) {
                '0'...'9' => context.idx += 1,
                '-' => context.idx += 1,
                else => std.debug.panic("{c} is not number\n", .{context.currentChar()}),
            }
        }
        const num = std.fmt.parseInt(i64, context.content[num_start..context.idx], 10) catch unreachable;
        return BElement{ .integer = num };
    }
    fn decodeList(context: *BEContext) BElement {
        context.idx += 1; // skip 'l'
        defer {
            // skip 'e'
            std.debug.assert(context.currentChar() == 'e');
            context.idx += 1;
        }
        // TODO find a better way to handle recusive alloc
        // just using a arena
        var bElementList = std.ArrayList(BElement).init(context.allocator);
        defer bElementList.deinit();
        while (context.currentChar() != 'e') {
            bElementList.append(decode(context)) catch {
                std.debug.panic("paring List failed!", .{});
            };
        }
        const blist = bElementList.toOwnedSlice() catch unreachable;
        return BElement{ .list = blist };
    }
    fn decodeDict(context: *BEContext) BElement {
        context.idx += 1; //skip 'd'
        defer {
            // skip 'e'
            std.debug.assert(context.currentChar() == 'e');
            context.idx += 1;
        }
        var bElementDict = std.ArrayList(BElement.DictItem).init(context.allocator);
        defer bElementDict.deinit();
        while (context.currentChar() != 'e') {
            const key = decodeString(context);
            const value = decode(context);
            // TODO find a better way to check key type
            switch (key) {
                .str => |key_str| {
                    const ele = BElement.DictItem{ .key = key_str, .value = value };
                    bElementDict.append(ele) catch unreachable;
                },
                else => unreachable,
            }
        }
        const bDict = bElementDict.toOwnedSlice() catch unreachable;
        return BElement{ .dict = bDict };
    }
};
const TestContext = struct {
    allocator: Allocator,
    fn expect_be_str(self: *@This(), bestr: []const u8, str: []const u8) !void {
        var context = BEContext{ .content = bestr, .allocator = self.allocator };
        const bele = context.decode();
        const bstr = try bele.toString(self.allocator);
        defer self.allocator.free(bstr);
        try expect(std.mem.eql(u8, bstr, str));
    }
    fn expect_encode(self: *@This(), str: []const u8) !void {
        var context = BEContext{ .content = str, .allocator = self.allocator };
        const bele = context.decode();
        const bstr = try bele.encode(self.allocator);
        try expect(std.mem.eql(u8,str,bstr));
    }
};

test "bcode element to string" {
    std.testing.log_level = std.log.Level.info;
    var test_arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer test_arena.deinit();
    const arena_alloc = test_arena.allocator();

    const bstr = BElement{ .str = "bstr" };
    const rstr = try bstr.toString(arena_alloc);
    try expect(std.mem.eql(u8, rstr, "\"bstr\""));

    const bint = BElement{ .integer = 32 };
    const bnint = BElement{ .integer = -10 };
    const bzero = BElement{ .integer = 0 };
    try expect(std.mem.eql(u8, try bint.toString(arena_alloc), "32"));
    try expect(std.mem.eql(u8, try bnint.toString(arena_alloc), "-10"));
    try expect(std.mem.eql(u8, try bzero.toString(arena_alloc), "0"));

    var bAlist = std.ArrayList(BElement).init(arena_alloc);
    defer bAlist.deinit();
    try bAlist.append(bstr);
    try bAlist.append(bint);
    const blist = try bAlist.toOwnedSlice();
    const belist = BElement{ .list = blist };
    try expect(std.mem.eql(u8, try belist.toString(arena_alloc), "[\"bstr\",32]"));

    const dictItem = BElement.DictItem{ .key = "key", .value = bint };
    var dict = [_]BElement.DictItem{dictItem};
    const dictSlice = dict[0..];
    const bdict = BElement{ .dict = dictSlice };
    try expect(std.mem.eql(u8, try bdict.toString(arena_alloc), "{\"key\":32}"));
}
test "simple to string" {
    var tCtx = TestContext{ .allocator = std.testing.allocator };
    try tCtx.expect_be_str("5:hello", "\"hello\"");
}
test "decode bcode string" {
    std.testing.log_level = std.log.Level.info;

    var test_arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer test_arena.deinit();
    const arena_alloc = test_arena.allocator();
    var tCtx = TestContext{ .allocator = arena_alloc };

    try tCtx.expect_be_str("5:hello", "\"hello\"");
    try tCtx.expect_be_str("i69e", "69");
    try tCtx.expect_be_str("li69e4:helle", "[69,\"hell\"]");
    try tCtx.expect_be_str("lli69e4:hellee", "[[69,\"hell\"]]");
    try tCtx.expect_be_str("d3:keyi69ee", "{\"key\":69}");
    try tCtx.expect_be_str("d3:key" ++ "li69e4:helle" ++ "e", "{\"key\":[69,\"hell\"]}");
}

test "encode bencode string" {
    std.testing.log_level = std.log.Level.info;

    var test_arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer test_arena.deinit();
    const arena_alloc = test_arena.allocator();
    var tCtx = TestContext{ .allocator = arena_alloc };
    try tCtx.expect_encode("5:hello");
    try tCtx.expect_encode("i69e");
    try tCtx.expect_encode("li69e4:helle");
    try tCtx.expect_encode("lli69e4:hellee");
    try tCtx.expect_encode("d3:keyi69ee");
    try tCtx.expect_encode("d3:key" ++ "li69e4:helle" ++ "e");
}
