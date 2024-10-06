const std = @import("std");
const stdout = std.io.getStdOut().writer();
const bencode = @import("bencode.zig");
const http = std.http;
const net = std.net;
const BLOCK_SIZE = (1 << 14) + 20;
const Sha1 = std.crypto.hash.Sha1;
const bytes2hex = std.fmt.fmtSliceHexLower;
const RndGen = std.rand.DefaultPrng;

const SocketAddress = struct {
    ip: []const u8,
    port: u16,
};

fn parse_torrent(filename: []const u8, allocator: std.mem.Allocator) !bencode.BElement {
    var buf: [80000]u8 = undefined;
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
fn parse_address(address_str: []const u8) !SocketAddress {
    const colon_pos = std.mem.indexOf(u8, address_str, ":");
    if (colon_pos == null) {
        try stdout.print("Wrong ip format {s}\n", .{address_str});
        std.process.exit(1);
    }
    const ip = address_str[0..colon_pos.?];
    const port_str = address_str[colon_pos.? + 1 ..];
    const port = try std.fmt.parseInt(u16, port_str, 10);
    return SocketAddress{ .ip = ip, .port = port };
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
        const address_str = args[3];
        try cmd_handshake(filename, try parse_address(address_str), arena_alloc);
    } else if (std.mem.eql(u8, command, "download_piece")) {
        if (!std.mem.eql(u8, args[2], "-o")) {
            try stdout.print("Wrong Argument in download_piece\n", .{});
            std.process.exit(1);
        }
        const temp_dir = args[3];
        const filename = args[4];
        const index = try std.fmt.parseInt(u32, args[5], 10);
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
    std.debug.assert(sha1.len == 20);
    const peer_id = "00112233445566778899"; //20
    var writer = stream.writer();
    _ = try writer.write(bt_header ++ reverved_bytes);
    _ = try writer.write(sha1);
    _ = try writer.write(peer_id);
    var buf: [68]u8 = undefined;
    const resp_size = try stream.read(buf[0..]);
    std.debug.assert(resp_size >= 68);
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
const Message = struct {
    // length:u32,
    tag: MessageType,
    payload: []u8,

    pub fn serialize(self: *const Message, allocator: std.mem.Allocator) ![]u8 {
        var data = std.ArrayList(u8).init(allocator);
        const length: u32 = @as(u32, @intCast(self.payload.len)) + 1;

        var length_buf: [4]u8 = undefined;
        std.mem.writeInt(u32, &length_buf, length, .big);
        try data.appendSlice(&length_buf);
        try data.append(@intFromEnum(self.tag));
        try data.appendSlice(self.payload);
        return data.toOwnedSlice();
    }
    pub fn deserialize(bytes: []u8, allocator: std.mem.Allocator) !Message {
        // const length = std.mem.readInt(u32, bytes[0..4], .big);
        // std.debug.print("message_length={}\n",.{length});
        const tag: MessageType = @enumFromInt(bytes[0]);
        const payload = if (bytes.len > 1)
            bytes[1..]
        else
            &[_]u8{};
        return Message{ .tag = tag, .payload = try allocator.dupe(u8, payload) };
    }
};
fn read_message(stream: net.Stream, block_buf: []u8) !Message {
    var length_buf: [4]u8 = undefined;
    _ = try stream.read(&length_buf);
    var length = std.mem.readInt(u32, &length_buf, .big);
    while (length == 0) {
        _ = try stream.read(&length_buf);
        length = std.mem.readInt(u32, &length_buf, .big);
    }
    _ = try stream.readAll(block_buf[0..length]);
    const message_type: MessageType = @enumFromInt(block_buf[0]);
    return Message{ .tag = message_type, .payload = block_buf[1..] };
}
fn send_message(writer: anytype, message: Message, allocator: std.mem.Allocator) !void {
    const intersted_message_bytes = try message.serialize(allocator);

    _ = try writer.write(intersted_message_bytes);
}
const PieceMessage = struct {
    index: u32,
    begin: u32,
    block: []u8,

    pub fn load(bytes: []u8) PieceMessage {
        std.debug.assert(bytes.len > 8);
        const index = std.mem.readInt(u32, bytes[0..4], .big);
        const begin = std.mem.readInt(u32, bytes[4..8], .big);
        return PieceMessage{ .index = index, .begin = begin, .block = bytes[8..] };
    }
};
fn calculate_piece_block_total_count(piece_length: u32) u32 {
    const block_size: u32 = BLOCK_SIZE;
    var block_count: u32 = piece_length / block_size;
    if (piece_length % block_size > 0) {
        block_count += 1;
    }
    return block_count;
}
fn set_request_payload(piece_index: u32, index: u32, piece_length: u32, request_payload: []u8) void {
    const block_size: u32 = BLOCK_SIZE;
    var last_block_size = piece_length % block_size;
    var last_block_index: u32 = piece_length / block_size;
    if (last_block_size == 0) {
        last_block_size = block_size;
    } else {
        last_block_index += 1;
    }
    // std.debug.print("last_block_index={}\n", .{last_block_index});
    std.debug.assert(piece_index <= last_block_index);
    var length = block_size;
    if (index == last_block_index) {
        length = last_block_size;
    }
    const begin = block_size * piece_index;
    std.debug.print("piece_index={},begin={},length={},block_size={},piece_length={}\n", .{ piece_index, begin, length, block_size, piece_length });
    std.mem.writeInt(u32, request_payload[0..4], index, .big);
    std.mem.writeInt(u32, request_payload[4..8], begin, .big);
    std.mem.writeInt(u32, request_payload[8..12], length, .big);
}
fn download_piece(filename: []u8, tmp_filename: []u8, index: u32, allocator: std.mem.Allocator) !void {
    const torrent = parse_torrent(filename, allocator) catch |e| {
        try stdout.print("{s}\n", .{@errorName(e)});
        std.process.exit(1);
    };
    const infoElement = try torrent.queryDict("info");
    const lengthElement = try infoElement.queryDict("length");
    const total_length: u32 = @intCast(lengthElement.integer);
    const pieces_lengthElement = try infoElement.queryDict("piece length");
    const piece_length: u32 = @intCast(pieces_lengthElement.integer);
    const current_piece_length = blk: {
        if (index <= total_length / piece_length) {
            break :blk piece_length;
        }
        break :blk total_length % piece_length;
    };
    var rnd = RndGen.init(0);
    const random_index = rnd.random().int(usize) % 50 * 6;
    const peers_str = try get_peers_from_torrent(torrent, allocator);
    const peer_address = try get_address_from_peer(peers_str[random_index..], allocator);
    try stdout.print("PeerAddress={s}:{}\n", .{ peer_address.ip, peer_address.port });
    const peer = try net.Address.parseIp4(peer_address.ip, peer_address.port);
    const stream = try net.tcpConnectToAddress(peer);
    defer stream.close();
    const bt_header = [_]u8{19} ++ "BitTorrent protocol"; // 20
    const reverved_bytes: [8]u8 = [_]u8{0} ** 8; // 8
    const sha1 = try get_info_hash(torrent, allocator); // 20
    std.debug.assert(sha1.len == 20);
    const peer_id = "00112233445566778899"; //20
    var writer = stream.writer();
    _ = try writer.write(bt_header ++ reverved_bytes);
    _ = try writer.write(sha1);
    _ = try writer.write(peer_id);
    // var buf: [32768]u8 = undefined;
    var hand_shake_buf: [68]u8 = undefined;
    _ = try stream.read(&hand_shake_buf);
    // try stdout.print("resp_size:{}\n", .{resp_size});
    try stdout.print("Handshake Success\nPeer ID: {s}\n", .{bytes2hex(hand_shake_buf[48..])});
    var first_message_buf: [BLOCK_SIZE]u8 = undefined;
    const first_message = try read_message(stream, & first_message_buf);
    std.debug.assert(first_message.tag == .bitfield);
    std.debug.print("Get bitfield!\n", .{});

    const intersted_message = Message{ .tag = .interested, .payload = &[_]u8{} };
    try send_message(writer, intersted_message, allocator);
    var intersted_buf: [1024]u8 = undefined;
    const intersted_recv = try read_message(stream, &intersted_buf);
    std.debug.assert(intersted_recv.tag == .unchoke);
    std.debug.print("Get unchoke!\n", .{});

    var request_payload: [4 * 3]u8 = undefined;
    var piece_data = std.ArrayList(u8).init(allocator);
    defer piece_data.deinit();
    const block_count = calculate_piece_block_total_count(current_piece_length);
    var i: u32 = 0;
    while (i <= block_count) : (i += 1) {
        var block_buf:[BLOCK_SIZE]u8=undefined;
        set_request_payload(i, index, current_piece_length, &request_payload);
        const request_message = Message{ .tag = .request, .payload = &request_payload };
        try send_message(stream, request_message, allocator);

        const piece_message_bytes = try read_message(stream,&block_buf);
        std.debug.print("{s}\n", .{@tagName(piece_message_bytes.tag)});
        std.debug.assert(piece_message_bytes.tag == .piece);
        const piece_message = PieceMessage.load(piece_message_bytes.payload);
        // std.debug.print("index={}, begin={}, block_length={}\n", .{ piece_message.index, piece_message.begin, piece_message.block.len });
        try piece_data.appendSlice(piece_message.block);
    }

    std.debug.print("index={},Piece Hash={s}",.{index,bytes2hex(piece_data.items)});
    const file = try std.fs.createFileAbsolute(tmp_filename, .{ .read = true });
    defer file.close();

    try file.writeAll(piece_data.items);
    // std.debug.print("index={}, begin={}\n", .{ piece_data.index, piece_data.begin });
}
