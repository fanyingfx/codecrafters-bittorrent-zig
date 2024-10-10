const std = @import("std");
const torrent = @import("torrent_file.zig");
const net = std.net;
const handshake = @import("handshake.zig");
const message = @import("message.zig");
const Message = message.Message;
const assert = std.debug.assert;
const Sha1 = std.crypto.hash.Sha1;
const bytes2hex = std.fmt.fmtSliceHexLower;
pub fn download_piece(allocator: std.mem.Allocator, bt_filename: []const u8, tmp_filename: []u8, piece_index: u32) !void {
    const bt_torrent_file = try std.fs.cwd().readFileAlloc(allocator, bt_filename, 65535);
    defer allocator.free(bt_torrent_file);
    var bt_torrent = try torrent.TorrentFile.parseTorrentFile(allocator, bt_torrent_file);
    defer bt_torrent.deinit();
    const peer_addresses = bt_torrent.getPeerAddressesAlloc(allocator);
    defer allocator.free(peer_addresses);
    const stream = try net.tcpConnectToAddress(peer_addresses[0]);
    defer stream.close();
    // handshake
    try handshake.handshake(stream, bt_torrent);

    // read bitfield
    const bitfield_msg_length = message.readLength(stream);
    const msg_buf = try allocator.alloc(u8, bitfield_msg_length);
    defer allocator.free(msg_buf);
    const msg = try message.readBody(stream, msg_buf);
    assert(msg.ID == .bitfield);

    // send interested
    const interested = Message{ .ID = .interested };
    try interested.send(allocator, stream);
    // receive unchoke
    const unchoke_length = message.readLength(stream);
    const unchoke_msg_buf = try allocator.alloc(u8, unchoke_length);
    defer allocator.free(unchoke_msg_buf);
    const unchoke_msg = try message.readBody(stream, unchoke_msg_buf);
    assert(unchoke_msg.ID == .unchoke);
    assert(unchoke_msg.payload.len == 0);
    var file_data = std.ArrayList(u8).init(allocator);
    defer file_data.deinit();

    const current_piece_length = bt_torrent.current_piece_length(piece_index);
    // std.debug.print("start: index={},piece_length={}\n", .{ piece_idx, current_piece_length });
    var begin_index: u32 = 0;
    while (begin_index * torrent.BLOCK_SIZE < current_piece_length) {
        try message.sendRequest(allocator, stream, bt_torrent, piece_index, begin_index);

        // receive piece message
        const piece_length = message.readLength(stream);
        const piece_msg_buf = try allocator.alloc(u8, piece_length);
        defer allocator.free(piece_msg_buf);
        const piece_msg = try message.readBody(stream, piece_msg_buf);
        const piece_data = message.readPiece(piece_msg);
        std.debug.assert(piece_data.begin == begin_index * torrent.BLOCK_SIZE);
        std.debug.assert(piece_data.index == piece_index);
        // std.debug.print("index={},begin={},block_length={}\n", .{ piece_data.index, piece_data.begin, piece_data.block.len });
        try file_data.appendSlice(piece_data.block);
        begin_index += 1;
    }
    var sha1_buf: [20]u8 = undefined;
    Sha1.hash(file_data.items, &sha1_buf, .{});
    std.debug.assert(std.mem.eql(u8, &sha1_buf, bt_torrent.piece_hashes[piece_index]));

    // var file_name_buf: [1024]u8 = undefined;
    // const file_name = try std.fmt.bufPrint(&file_name_buf, "data-{d}.txt", .{piece_index});
    const file = try std.fs.createFileAbsolute(tmp_filename, .{ .read = true });
    defer file.close();

    try file.writeAll(file_data.items);
    // }
}
pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    const allocator = gpa.allocator();
    defer _ = gpa.deinit();
    const bt_torrent_file = try std.fs.cwd().readFileAlloc(allocator, "sample.torrent", 65535);
    defer allocator.free(bt_torrent_file);
    var bt_torrent = try torrent.TorrentFile.parseTorrentFile(allocator, bt_torrent_file);
    defer bt_torrent.deinit();
    const peer_addresses = bt_torrent.getPeerAddressesAlloc(allocator);
    defer allocator.free(peer_addresses);
    const stream = try net.tcpConnectToAddress(peer_addresses[0]);
    defer stream.close();
    // handshake
    try handshake.handshake(stream, bt_torrent);

    // read bitfield
    const bitfield_msg_length = message.readLength(stream);
    const msg_buf = try allocator.alloc(u8, bitfield_msg_length);
    defer allocator.free(msg_buf);
    const msg = try message.readBody(stream, msg_buf);
    assert(msg.ID == .bitfield);

    // send interested
    const interested = Message{ .ID = .interested };
    try interested.send(allocator, stream);
    // receive unchoke
    const unchoke_length = message.readLength(stream);
    const unchoke_msg_buf = try allocator.alloc(u8, unchoke_length);
    defer allocator.free(unchoke_msg_buf);
    const unchoke_msg = try message.readBody(stream, unchoke_msg_buf);
    assert(unchoke_msg.ID == .unchoke);
    assert(unchoke_msg.payload.len == 0);

    // const piece_index = 1;
    const piece_count: u32 = @intCast(bt_torrent.piece_hashes.len);
    // std.debug.print("piece_count={}\n", .{piece_count});
    // std.debug.print("length={},piece_length={}\n", .{ bt_torrent.info.length, bt_torrent.info.piece_length });
    for (0..piece_count) |piece_idx| {
        const piece_index: u32 = @intCast(piece_idx);
        var file_data = std.ArrayList(u8).init(allocator);
        defer file_data.deinit();

        const current_piece_length = bt_torrent.current_piece_length(piece_index);
        // std.debug.print("start: index={},piece_length={}\n", .{ piece_idx, current_piece_length });
        var begin_index: u32 = 0;
        while (begin_index * torrent.BLOCK_SIZE < current_piece_length) {
            try message.sendRequest(allocator, stream, bt_torrent, piece_index, begin_index);

            // receive piece message
            const piece_length = message.readLength(stream);
            const piece_msg_buf = try allocator.alloc(u8, piece_length);
            defer allocator.free(piece_msg_buf);
            const piece_msg = try message.readBody(stream, piece_msg_buf);
            const piece_data = message.readPiece(piece_msg);
            std.debug.assert(piece_data.begin == begin_index * torrent.BLOCK_SIZE);
            std.debug.assert(piece_data.index == piece_idx);
            // std.debug.print("index={},begin={},block_length={}\n", .{ piece_data.index, piece_data.begin, piece_data.block.len });
            try file_data.appendSlice(piece_data.block);
            begin_index += 1;
        }
        var sha1_buf: [20]u8 = undefined;
        Sha1.hash(file_data.items, &sha1_buf, .{});
        std.debug.assert(std.mem.eql(u8, &sha1_buf, bt_torrent.piece_hashes[piece_idx]));

        var file_name_buf: [1024]u8 = undefined;
        const file_name = try std.fmt.bufPrint(&file_name_buf, "data-{d}.txt", .{piece_index});
        const file = try std.fs.cwd().createFile(file_name, .{ .read = true });
        defer file.close();

        try file.writeAll(file_data.items);
    }
}
