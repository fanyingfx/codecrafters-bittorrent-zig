const std = @import("std");
const torrent = @import("torrent_file.zig");
pub const PiecePayload = struct {
    index: u32,
    begin: u32,
    block: []u8,
};
const MessageID = enum(u8) {
    choke = 0,
    unchoke = 1,
    interested = 2,
    notInterested = 3,
    have = 4,
    bitfield = 5,
    request = 6,
    piece = 7,
    cancel = 8,

    pub fn value(self: MessageID) u8 {
        return @intFromEnum(self);
    }
};
pub const Message = struct {
    ID: MessageID,
    payload: []u8 = &[_]u8{},
    fn serialize(self: Message, allocator: std.mem.Allocator) []u8 {
        var data = std.ArrayList(u8).init(allocator);
        defer data.deinit();
        errdefer unreachable;
        const length: u32 = @as(u32, @intCast(self.payload.len)) + 1;
        var length_buf: [4]u8 = undefined;
        std.mem.writeInt(u32, &length_buf, length, .big);
        try data.appendSlice(&length_buf);
        try data.append(self.ID.value());
        try data.appendSlice(self.payload);
        return try data.toOwnedSlice();
    }
    pub fn send(self: Message, allocator: std.mem.Allocator, stream: std.net.Stream) !void {
        const message_bytes = self.serialize(allocator);
        defer allocator.free(message_bytes);
        _ = try stream.write(message_bytes);
    }
};
pub fn readPiece(msg: Message) PiecePayload {
    std.debug.assert(msg.ID == .piece);
    const payload = msg.payload;
    // var integer_buf: [4]u8 = undefined;
    const index = std.mem.readInt(u32, payload[0..4], .big);
    const begin = std.mem.readInt(u32, payload[4..8], .big);
    const block = payload[8..];
    return PiecePayload{
        .begin = begin,
        .index = index,
        .block = block,
    };
}
pub fn readLength(stream: std.net.Stream) u32 {
    var length_buf: [4]u8 = undefined;
    _ = stream.read(&length_buf) catch unreachable;
    var length = std.mem.readInt(u32, &length_buf, .big);
    if (length == 0) {
        _ = stream.read(&length_buf) catch unreachable;
        length = std.mem.readInt(u32, &length_buf, .big);
    }
    return length;
}
pub fn readBody(stream: std.net.Stream, message_buf: []u8) !Message {
    _ = try stream.readAll(message_buf);
    const message_type: MessageID = @enumFromInt(message_buf[0]);
    return Message{ .ID = message_type, .payload = message_buf[1..] };
}
pub fn sendRequest(allocator: std.mem.Allocator, stream: std.net.Stream, bt_torrent: torrent.TorrentFile,index:u32,begin_index:u32) !void {
    const request_payload = try allocator.alloc(u8, 3 * 4);
    defer allocator.free(request_payload);
    const length = torrent.calculate_block_length(bt_torrent, index, begin_index);
    std.mem.writeInt(u32, request_payload[0..4], index, .big);
    std.mem.writeInt(u32, request_payload[4..8], begin_index*torrent.BLOCK_SIZE, .big);
    std.mem.writeInt(u32, request_payload[8..12], length, .big);
    const req_msg = Message{ .ID = .request, .payload = request_payload };
    try req_msg.send(allocator, stream);
}
