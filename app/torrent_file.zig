const std = @import("std");
const bencode = @import("bencode.zig");
const net = std.net;
pub const BLOCK_SIZE = 1 << 14;
pub const BencodeInfo = struct {
    pieces: []const u8,
    piece_length: u32,
    length: u32,
    name: []const u8,

    pub fn deinit(self: *BencodeInfo, allocator: std.mem.Allocator) void {
        allocator.free(self.name);
        allocator.free(self.pieces);
    }
};
pub const TorrentFile = struct {
    announce: []const u8,
    info: BencodeInfo,
    info_hash: []u8,
    piece_hashes: [][]u8,
    allocator: std.mem.Allocator,

    pub fn parseTorrentFile(allocator: std.mem.Allocator, file_content: []u8) !TorrentFile {
        var context = bencode.BEContext{ .allocator = allocator, .content = file_content };
        var torrent_element = context.decode();
        defer torrent_element.deinit(allocator);
        const announce = try allocator.dupe(u8, torrent_element.query("announce").str);
        const info = torrent_element.query("info");
        std.debug.assert(info == .dict);
        var info_hash_buf: [20]u8 = undefined;
        const info_encode_str = try info.encode(allocator);
        defer allocator.free(info_encode_str);
        std.crypto.hash.Sha1.hash(info_encode_str, &info_hash_buf, .{});
        const info_hash = try allocator.dupe(u8, &info_hash_buf);
        const length: u32 = @intCast(info.query("length").integer);
        const name = try allocator.dupe(u8, info.query("name").str);
        const piece_length: u32 = @intCast(info.query("piece length").integer);
        const pieces = try allocator.dupe(u8, info.query("pieces").str);
        std.debug.assert(pieces.len % 20 == 0);
        var pieces_list = std.ArrayList([]u8).init(allocator);
        var idx: usize = 0;
        while (idx < pieces.len) : (idx += 20) {
            try pieces_list.append(pieces[idx .. idx + 20]);
        }
        const piece_hashes = try pieces_list.toOwnedSlice();
        const bencode_info = BencodeInfo{ .length = length, .name = name, .piece_length = piece_length, .pieces = pieces };
        return TorrentFile{ .announce = announce, .info = bencode_info, .allocator = allocator, .info_hash = info_hash, .piece_hashes = piece_hashes };
    }
    fn urlencode(str: []u8, allocator: std.mem.Allocator) ![]u8 {
        var string = std.ArrayList(u8).init(allocator);
        for (str) |ch| {
            switch (ch) {
                0x4c => try string.append('L'),
                0x54 => try string.append('T'),
                0x68 => try string.append('h'),
                0x71 => try string.append('q'),
                else => try string.writer().print("%{x:0>2}", .{ch}),
            }
        }
        return string.toOwnedSlice();
    }
    pub fn buildTrackerURL(self: *const TorrentFile, writer: anytype, peer_id: []const u8, port: u16) !std.Uri {
        const info_hash_encoded = try urlencode(self.info_hash, self.allocator);
        defer self.allocator.free(info_hash_encoded);
        try writer.print("{s}?", .{self.announce});
        try writer.print("info_hash={s}", .{info_hash_encoded});
        try writer.print("&peer_id={s}", .{peer_id});
        try writer.print("&port={d}", .{port});
        try writer.print("&uploaded=0", .{});
        try writer.print("&downloaded=0", .{});
        try writer.print("&compact=1", .{});
        try writer.print("&left={d}", .{self.info.length});
        const uri = std.Uri.parse(writer.context.items);
        // std.debug.print("host={s}\n", .{uri.host.?.percent_encoded});
        return uri;
    }
    pub fn getPeers(self: *const TorrentFile) ![]u8 {
        var arena = std.heap.ArenaAllocator.init(self.allocator);
        defer arena.deinit();
        const arena_alloc = arena.allocator();

        var url_list = std.ArrayList(u8).init(arena_alloc);
        const peer_id = "x0a122334b5566x78c99";
        const port = 6883;
        const url = try self.buildTrackerURL(url_list.writer(), peer_id, port);
        const server_header_buffer: []u8 = try arena_alloc.alloc(u8, 8 * 1024 * 4);
        defer arena_alloc.free(server_header_buffer);
        var client = std.http.Client{ .allocator = arena_alloc };
        const headers = std.http.Client.Request.Headers{};

        var request = try client.open(.GET, url, std.http.Client.RequestOptions{ .headers = headers, .server_header_buffer = server_header_buffer });
        try request.send();
        try request.finish();
        try request.wait();
        const body = try request.reader().readAllAlloc(arena_alloc, 1024 * 1024 * 2);
        var context = bencode.BEContext{ .content = body, .idx = 0, .allocator = arena_alloc };
        const parsed_body = context.decode();
        const peers = parsed_body.query("peers");
        return try self.allocator.dupe(u8, peers.str);
    }
    pub fn deinit(self: *TorrentFile) void {
        self.info.deinit(self.allocator);
        self.allocator.free(self.announce);
        self.allocator.free(self.info_hash);
        self.allocator.free(self.piece_hashes);
    }
    pub fn getPeerAddressesAlloc(self: *TorrentFile, allocator: std.mem.Allocator) []net.Address {
        var alist = std.ArrayList(net.Address).init(allocator);
        defer alist.deinit();
        const peers_str = self.getPeers() catch unreachable;
        defer self.allocator.free(peers_str);
        var i: usize = 0;
        while (i < peers_str.len) : (i += 6) {
            const port_buf: [2]u8 = [_]u8{ peers_str[4], peers_str[5] };
            const port = std.mem.readInt(u16, &port_buf, .big);
            var address_buf: [100]u8 = undefined;
            const address_str = std.fmt.bufPrint(&address_buf, "{d}.{d}.{d}.{d}", .{ peers_str[i], peers_str[i + 1], peers_str[i + 2], peers_str[i + 3] }) catch unreachable;
            const address = net.Address.parseIp4(address_str, port) catch unreachable;
            alist.append(address) catch unreachable;
        }
        return alist.toOwnedSlice() catch unreachable;
    }
    pub fn current_piece_length(bt_torrent: TorrentFile, index: u32) u32 {
        const info = bt_torrent.info;
        std.debug.assert(index < info.pieces.len);
        var last_piece_length = info.length % info.piece_length;
        if (last_piece_length == 0) {
            last_piece_length = info.piece_length;
        }
        const last_pieces_index = bt_torrent.piece_hashes.len - 1;
        return if (index != last_pieces_index) info.piece_length else last_piece_length;
    }
};
pub fn calculate_block_length(curr_piece_length:u32, begin_index: u32) u32 {
    // const cur_piece_length = bt_torrent.current_piece_length(index);
    var length: u32 = undefined;
    std.debug.assert(begin_index * BLOCK_SIZE < curr_piece_length); // safe check
    if ((begin_index + 1) * BLOCK_SIZE < curr_piece_length) {
        length = BLOCK_SIZE;
    } else {
        length = curr_piece_length - (begin_index * BLOCK_SIZE);
    }
    return length;
}

fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    const allocator = gpa.allocator();
    defer _ = gpa.deinit();
    const bt_torrent_file = try std.fs.cwd().readFileAlloc(allocator, "sample.torrent", 65535);
    defer allocator.free(bt_torrent_file);
    var bt_torrent = try TorrentFile.parseTorrentFile(allocator, bt_torrent_file);
    defer bt_torrent.deinit();
    var url_list = std.ArrayList(u8).init(allocator);
    defer url_list.deinit();

    const peers = try bt_torrent.getPeers();
    defer allocator.free(peers);
    const peer_addresses = bt_torrent.getPeerAddressesAlloc(allocator);
    defer allocator.free(peer_addresses);

    var address_list = std.ArrayList(u8).init(allocator);
    defer address_list.deinit();
    const writer = address_list.writer();

    for (peer_addresses) |address| {
        try address.format("", .{}, writer);
        try writer.writeByte('\n');
    }
    std.debug.print("{s}", .{address_list.items});
}
