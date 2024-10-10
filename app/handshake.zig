const std = @import("std");
const torrent = @import("torrent_file.zig");
const net = std.net;
const assert = std.debug.assert;
const BTStr= "BitTorrent protocol";
const Handshake = struct {
    pstr: []const u8 = BTStr,
    info_hash: []u8,
    peer_id: []const u8,
    pub fn serialize(self: *const Handshake, allocator: std.mem.Allocator) []u8 {
        var string_list = std.ArrayList(u8).initCapacity(allocator, 68) catch unreachable;
        defer string_list.deinit();
        errdefer unreachable;
        const writer = string_list.fixedWriter();
        try writer.writeByte(0x13);
        _ = try writer.write(self.pstr);
        try writer.writeByteNTimes(0, 8);
        std.debug.assert(self.info_hash.len == 20);
        _ = try writer.write(self.info_hash);
        _ = try writer.write(self.peer_id);
        std.debug.assert(self.peer_id.len == 20);
        return try string_list.toOwnedSlice();
    }
    pub fn read(buf: []u8) Handshake {
        assert(buf[0] == 0x13);
        assert(std.mem.eql(u8,buf[1..20],BTStr));
        return Handshake{
            .info_hash=buf[28..48],
            .peer_id = buf[48..68]
        };
    }
};
pub fn handshake(stream:net.Stream, torrent_file: torrent.TorrentFile) !void {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const arena_alloc = arena.allocator();
    // const stream = try net.tcpConnectToAddress(address);
    // defer stream.close();
    const peer_id = "00112233445566778899"; //20
    const my_handshake = Handshake{ .info_hash = torrent_file.info_hash, .peer_id = peer_id };

    var writer = stream.writer();
    const my_handshake_msg = my_handshake.serialize(arena_alloc);
    _ = try writer.writeAll(my_handshake_msg);
    var buf: [68]u8 = undefined;
    const resp_size = try stream.read(&buf);
    std.debug.assert(resp_size == 68);
    const recv_handshake = Handshake.read(&buf);

    std.debug.print("Peer ID: {s}\n", .{std.fmt.fmtSliceHexLower(recv_handshake.peer_id)});
}
// pub fn main() !void {
//     var gpa = std.heap.GeneralPurposeAllocator(.{}){};
//     const allocator = gpa.allocator();
//     defer _ = gpa.deinit();
//     const bt_torrent_file = try std.fs.cwd().readFileAlloc(allocator, "sample.torrent", 65535);
//     defer allocator.free(bt_torrent_file);
//     var bt_torrent = try torrent.TorrentFile.parseTorrentFile(allocator, bt_torrent_file);
//     defer bt_torrent.deinit();
//     const peer_addresses = bt_torrent.getPeerAddressesAlloc(allocator);
//     defer allocator.free(peer_addresses);
//     // try handshake(peer_addresses[0], bt_torrent);
    
// }
