const std = @import("std");
const stdout = std.io.getStdOut().writer();
const bencode = @import("bencode.zig");
const http = std.http;
const net = std.net;
const Sha1 = std.crypto.hash.Sha1;
const bytes2hex = std.fmt.fmtSliceHexLower;
const SocketAddress = struct {
    ip: []u8,
    port: u16,
};

// const BT = struct {

// }

fn parse_torrent(filename: []const u8, allocator: std.mem.Allocator) !bencode.BElement {
    var buf: [1000]u8 = undefined;
    const fileContent = try std.fs.cwd().readFile(filename, &buf);
    var context = bencode.BContext{ .content = fileContent, .idx = 0, .allocator = allocator };
    const belement = bencode.decodeBencode(&context) catch |e| {
        try stdout.print("{s}\n", .{@errorName(e)});
        std.process.exit(1);
    };
    return belement;
}
fn get_info_hash(torrent: bencode.BElement, allocator: std.mem.Allocator) ![]u8 {
    const info_ele = try torrent.queryDict("info");
    const encode_info = try bencode.encodeElement(info_ele, allocator);
    var sha1_buf: [20]u8 = undefined;
    Sha1.hash(encode_info, &sha1_buf, .{});
    return allocator.dupe(u8, &sha1_buf);
}
fn urlencode(str: []u8, allocator: std.mem.Allocator) ![]u8 {
    var string = std.ArrayList(u8).init(allocator);
    var buf: [3]u8 = undefined;
    for (str) |ch| {
        switch (ch) {
            0x4c => try string.append('L'),
            0x54 => try string.append('T'),
            0x68 => try string.append('h'),
            0x71 => try string.append('q'),
            else => {
                const hex = try std.fmt.bufPrint(&buf, "%{x:0>2}", .{ch});
                try string.appendSlice(hex);
            },
        }
    }
    return string.toOwnedSlice();
}
fn BTUrl(torrent: bencode.BElement, allocator: std.mem.Allocator) ![]u8 {
    const urlElement = try torrent.queryDict("announce");
    const main_url = urlElement.str;
    const info_ele = try torrent.queryDict("info");
    const left = try info_ele.queryDict("length");
    const info_hash = try get_info_hash(torrent, allocator);
    const encode_hash = try urlencode(info_hash, allocator);
    const others = "peer_id=00112233445566778899" ++ "&" ++
        "port=6881" ++ "&" ++
        "uploaded=0" ++ "&" ++
        "downloaded=0" ++ "&" ++
        "compact=1";
    const url = std.fmt.allocPrint(allocator, "{s}?info_hash={s}&left={}&{s}", .{ main_url, encode_hash, left.integer, others });
    return url;
}
pub fn main() !void {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    const arena_alloc = arena.allocator();
    defer arena.deinit();

    const args = try std.process.argsAlloc(arena_alloc);
    defer std.process.argsFree(arena_alloc, args);

    if (args.len < 3) {
        try stdout.print("Usage: your_bittorrent.zig <command> <args>\n", .{});
        std.process.exit(1);
    }
    const command = args[1];

    if (std.mem.eql(u8, command, "decode")) {
        const encodedStr = args[2];
        try cmd_decode(encodedStr, arena_alloc);
    } else if (std.mem.eql(u8, command, "info")) {
        const filename = args[2];
        try cmd_info(filename, arena_alloc);
    } else if (std.mem.eql(u8, command, "peers")) {
        const filename = args[2];
        try cmd_peers(filename, arena_alloc);
    } else if (std.mem.eql(u8, command, "handshake")) {
        // 161.35.46.221:51414
        const filename = args[2];
        const ip_port_str = args[3];
        const colon_pos = std.mem.indexOf(u8, ip_port_str, ":");
        if (colon_pos == null) {
            try stdout.print("Wrong ip format {s}\n", .{ip_port_str});
            std.process.exit(1);
        }
        const ip = ip_port_str[0..colon_pos.?];
        const port_str = ip_port_str[colon_pos.? + 1 ..];
        const port = try std.fmt.parseInt(u16, port_str, 10);
        try cmd_handshake(filename, SocketAddress{ .ip = ip, .port = port }, arena_alloc);
    } else if (std.mem.eql(u8, command, "download_piece")) {
        if (!std.mem.eql(u8, args[2], "-o")) {
            try stdout.print("Wrong Argument in download_piece\n", .{});
            std.process.exit(1);
        }
        const temp_dir = args[3];
        const filename = args[4];
        const index = try std.fmt.parseInt(usize, args[5], 10);
        try download_piece(filename, temp_dir, index, arena_alloc);
    } else {
        try stdout.print("Unsupport command: {s}\n", .{command});
    }
}
fn cmd_decode(content: []u8, allocator: std.mem.Allocator) !void {
    var context = bencode.BContext{ .content = content, .idx = 0, .allocator = allocator };
    const decodedValue = bencode.decodeBencode(&context) catch |e| {
        try stdout.print("{s}\n", .{@errorName(e)});
        std.process.exit(1);
    };
    try stdout.print("{s}\n", .{try decodedValue.toString(allocator)});
}
fn cmd_info(filename: []u8, allocator: std.mem.Allocator) !void {
    const torrent = parse_torrent(filename, allocator) catch |e| {
        try stdout.print("{s}\n", .{@errorName(e)});
        std.process.exit(1);
    };
    const announce = try torrent.queryDict("announce");
    const url = announce.str;
    const info_ele = try torrent.queryDict("info");
    const lengthElement = try info_ele.queryDict("length");
    const length = lengthElement.integer;
    try stdout.print("Tracker URL: {s}\n", .{url});
    try stdout.print("Length: {}\n", .{length});
    const info_hash = try get_info_hash(torrent, allocator);
    try stdout.print("Info Hash: {s}\n", .{bytes2hex(info_hash[0..])});
    const pieces_length = try info_ele.queryDict("piece length");
    try stdout.print("Piece Length: {}\n", .{pieces_length.integer});
    try stdout.print("Piece Hashes:\n", .{});
    const pieces_hash = try info_ele.queryDict("pieces");
    const pieces_hash_str = pieces_hash.str;
    var i: usize = 0;
    while (i < pieces_hash_str.len) : (i += 20) {
        try stdout.print("{s}\n", .{bytes2hex(pieces_hash_str[i .. i + 20])});
    }
}
fn get_peers_from_torrent(torrent: bencode.BElement, allocator: std.mem.Allocator) ![]u8 {
    const url = try BTUrl(torrent, allocator);
    var client = http.Client{ .allocator = allocator };
    const headers = http.Client.Request.Headers{};
    const uri = std.Uri.parse(url) catch unreachable;
    const server_header_buffer: []u8 = try allocator.alloc(u8, 8 * 1024 * 4);
    var request = try client.open(.GET, uri, http.Client.RequestOptions{ .headers = headers, .server_header_buffer = server_header_buffer });
    try request.send();
    try request.finish();
    try request.wait();
    const body = try request.reader().readAllAlloc(allocator, 1024 * 1024 * 2);
    var context = bencode.BContext{ .content = body, .idx = 0, .allocator = allocator };
    const parsed_body = try bencode.decodeBencode(&context);
    const peers_ele = try parsed_body.queryDict("peers");
    const peer_str = peers_ele.str;
    return allocator.dupe(u8, peer_str);
}
fn cmd_peers(filename: []u8, allocator: std.mem.Allocator) !void {
    const torrent = parse_torrent(filename, allocator) catch |e| {
        try stdout.print("{s}\n", .{@errorName(e)});
        std.process.exit(1);
    };
    var i: usize = 0;
    const peers_str = try get_peers_from_torrent(torrent, allocator);
    while (i < peers_str.len) : (i += 6) {
        const socket_address = try get_address_from_peer(peers_str[i..], allocator);
        try stdout.print("{s}:{}\n", .{ socket_address.ip, socket_address.port });
    }
}
fn get_address_from_peer(peer_str: []u8, allocator: std.mem.Allocator) !SocketAddress {
    const port_2: [2]u8 = [_]u8{ peer_str[4], peer_str[5] };
    const port = std.mem.readInt(u16, &port_2, .big);
    const ip = try std.fmt.allocPrint(allocator, "{}.{}.{}.{}", .{ peer_str[0], peer_str[1], peer_str[2], peer_str[3] });
    return SocketAddress{ .ip = ip, .port = port };
}
fn cmd_handshake(filename: []u8, peer_address: SocketAddress, alloctor: std.mem.Allocator) !void {
    const torrent = parse_torrent(filename, alloctor) catch |e| {
        try stdout.print("{s}\n", .{@errorName(e)});
        std.process.exit(1);
    };
    // const info_ele = try torrent.queryDict("info");
    // std.debug.print("Address={s}:{}\n",.{peer_address.ip,peer_address.port});
    const peer = try net.Address.parseIp4(peer_address.ip, peer_address.port);

    const stream = try net.tcpConnectToAddress(peer);
    defer stream.close();

    const bt_header = [_]u8{19} ++ "BitTorrent protocol"; // 20
    const reverved_bytes: [8]u8 = [_]u8{0} ** 8; // 8
    const sha1 = try get_info_hash(torrent, alloctor); // 20
    std.debug.assert(sha1.len==20);
    const peer_id = "00112233445566778899"; //20
    var writer = stream.writer();
    _ = try writer.write(bt_header ++ reverved_bytes);
    _ = try writer.write(sha1);
    _ = try writer.write(peer_id);
    var buf: [1024]u8 = undefined;
    const resp_size = try stream.read(buf[0..]);
    std.debug.assert(resp_size>=68);
    try stdout.print("Peer ID: {s}\n", .{bytes2hex(buf[48..resp_size])});
}
const PeerMessage = struct {
    prefix: [4]u8,
    message_id: u8,
    payload: []u8,
};
const MessageType = enum(u8) {
    choke = 0,
    unchoke = 1,
    interested = 2,
    notInterested = 3,
    have = 4,
    bitfield = 5,
    request = 6,
    piece = 7,
    cancel = 8,

    pub fn value(self: MessageType) u8 {
        return @intFromEnum(self);
    }
};
// const MessageTag = [5]u8;
const Message =struct{
    tag: MessageType,
    payload: []u8,
};
fn download_piece(filename: []u8, tmp_dir: []u8, index: usize, allocator: std.mem.Allocator) !void {
    _ = tmp_dir;
    _ = index;
    const torrent = parse_torrent(filename, allocator) catch |e| {
        try stdout.print("{s}\n", .{@errorName(e)});
        std.process.exit(1);
    };
    const peers_str = try get_peers_from_torrent(torrent, allocator);
    const peer_address = try get_address_from_peer(peers_str[6..], allocator);
    const peer = try net.Address.parseIp4(peer_address.ip, peer_address.port);
    const stream = try net.tcpConnectToAddress(peer);
    defer stream.close();
    const bt_header = [_]u8{19} ++ "BitTorrent protocol"; // 20
    const reverved_bytes: [8]u8 = [_]u8{0} ** 8; // 8
    const sha1 = try get_info_hash(torrent, allocator); // 20
    std.debug.assert(sha1.len==20);
    const peer_id = "00112233445566778899"; //20
    var writer = stream.writer();
    _ = try writer.write(bt_header ++ reverved_bytes);
    _ = try writer.write(sha1);
    _ = try writer.write(peer_id);
    var buf: [1024]u8 = undefined;
    var hand_shake_buf:[68]u8=undefined;
    var resp_size = try stream.read(hand_shake_buf[0..]);
    try stdout.print("resp_size:{}\n", .{resp_size});
    try stdout.print("Handshake Success\nPeer ID: {s}\n", .{bytes2hex(buf[48..resp_size])});
    resp_size=1;
    // var tag: [5]u8 = [_]u8{ 0, 0, 0, 0, 1 };
    // std.mem.writeInt(u32, tag[0..4], 1, .big);
    // tag[4] = MessageType.bitfield.value();
    

    // _ = try writer.write(&tag);
    // resp_size = try stream.read(&buf);
    // if (resp_size == 0){
    //     resp_size=try stream.read(&buf);
    // }

    // try stdout.print("resp_size:{}\n", .{resp_size});
    // try stdout.print("resp_msg_length:{}\n", .{std.mem.readInt(u32, buf[0..4], .big)});
    // try stdout.print("type: {}\n", .{buf[4]});

    // const request_id = [1]u8{MessageType.request.value()}; // interested
    // std.mem.writeInt(u32,&length,1+12,.big);
    // _ = try writer.write(&length);
    // _ = try writer.write(&request_id);
    // var request_message:[4*3]u8 = undefined;
    // std.mem.writeInt(u32,request_message[0..4],0,.big);
    // std.mem.writeInt(u32,request_message[4..8],0,.big);
    // std.mem.writeInt(u32,request_message[8..],92063,.big);
    // _ = try writer.write(&request_message);
    // resp_size = try stream.read(&buf);
    // try stdout.print("resp_size:{}\n",.{resp_size});
    // try stdout.print("resp_msg_length:{}\n",.{std.mem.readInt(u32,buf[0..4],.big)});
    // try stdout.print("type: {}\n", .{buf[4]});
}
