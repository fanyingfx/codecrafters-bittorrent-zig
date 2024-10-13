const std = @import("std");
const torrent = @import("torrent_file.zig");
const net = std.net;
const handshake = @import("handshake.zig");
const message = @import("message.zig");
const Message = message.Message;
const assert = std.debug.assert;
const Thread = std.Thread;
const WaitGroup = Thread.WaitGroup;
const Sha1 = std.crypto.hash.Sha1;
const bytes2hex = std.fmt.fmtSliceHexLower;
const queue = @import("queue.zig");

pub fn download_piece_to_file(allocator: std.mem.Allocator, bt_filename: []const u8, tmp_filename: []u8, piece_index: u32) !void {
    const bt_torrent_file = try std.fs.cwd().readFileAlloc(allocator, bt_filename, 65535);
    defer allocator.free(bt_torrent_file);
    var bt_torrent = try torrent.TorrentFile.parseTorrentFile(allocator, bt_torrent_file);
    defer bt_torrent.deinit();
    const peer_addresses = bt_torrent.getPeerAddressesAlloc(allocator);
    defer allocator.free(peer_addresses);
    const stream = try net.tcpConnectToAddress(peer_addresses[0]);
    defer stream.close();
    // handshake
    const handshake_msg = try handshake.handshake(stream, bt_torrent.info_hash, allocator);
    defer allocator.free(handshake_msg);

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
        try message.sendRequest(allocator, stream, current_piece_length, piece_index, begin_index);

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
const PieceQueue = queue.Queue(u32);
const AddressQueue = queue.Queue(net.Address);
pub fn downloadFile(arena_alloctor: std.mem.Allocator, tmp_filename: []const u8, bt_filename: []const u8) !void {
    const bt_torrent_file = try std.fs.cwd().readFileAlloc(arena_alloctor, bt_filename, 65535);
    defer arena_alloctor.free(bt_torrent_file);
    var bt_torrent = try torrent.TorrentFile.parseTorrentFile(arena_alloctor, bt_torrent_file);
    defer bt_torrent.deinit();
    std.debug.print("Total file size:{}\n",.{bt_torrent.info.length});
    const peer_addresses = bt_torrent.getPeerAddressesAlloc(arena_alloctor);
    // const peer_address = peer_addresses[0];
    defer arena_alloctor.free(peer_addresses);

    var piece_queue = PieceQueue.init();
    // var address_queue = AddressQueue.init();

    const piece_count = bt_torrent.piece_hashes.len;
    for (0..piece_count) |piece_index| {
        piece_queue.append(try piece_queue.createNode(arena_alloctor, @intCast(piece_index)));
    }
    // for(peer_addresses)|peer_addr|{
    //     address_queue.append(try AddressQueue.createNode(arena_alloctor,peer_addr));
    // }

    const piece_list: [][]u8 = try arena_alloctor.alloc([]u8, piece_count);
    for (0..piece_count) |piece_idx| {
        piece_list[piece_idx]= try arena_alloctor.alloc(u8,bt_torrent.current_piece_length(@intCast(piece_idx)));
        // const buf_data = try arena_alloctor.create(BufData);
        // buf_data.* = BufData.init(arena_alloctor);
        // piece_list[piece_idx] = buf_data;
    }
    // const thread_list=try allocator.alloc(Thread,)
    const thread_list = try arena_alloctor.alloc(Thread, peer_addresses.len);


    // while(piece_queue.popOrNull())
    // var pool: Thread.Pool = undefined;
    // try Thread.Pool.init(&pool, .{ .allocator = allocator, .n_jobs = peer_addresses.len });
    // var wg = WaitGroup{};
    // wg.reset();
    for (peer_addresses,0..) |peer_addr,idx| {
        const thread = try Thread.spawn(.{},thread_download,.{&piece_queue,peer_addr,piece_list,bt_torrent});
        thread_list[idx]=thread;
    }
    for(thread_list)|thread|{
        thread.join();
    }

    const file = try std.fs.createFileAbsolute(tmp_filename, .{ .read = true });
    defer file.close();
    for (piece_list) |piece_data| {
        try file.writeAll(piece_data);
    }

    // try file.writeAll(file_data.items);
}
const PieceInfo = struct {
    index: u32,
    length: u32,
    hash: []u8,
};
const BufData = std.ArrayList(u8);
pub fn thread_download(piece_queue: *PieceQueue, peer_address: net.Address, piece_list: [][]u8, bt_torrent: torrent.TorrentFile) void {
    while (piece_queue.popOrNull()) |piece_index| {
        const piece_length = bt_torrent.current_piece_length(piece_index.data);
        const info_hash = bt_torrent.info_hash;
        const piece_info = PieceInfo{
            .hash = bt_torrent.piece_hashes[piece_index.data],
            .index = piece_index.data,
            .length = piece_length,
        };
        _download_piece(peer_address, piece_list[piece_index.data], info_hash, piece_info) catch |err| {
            piece_queue.append(piece_index);
            switch (err) {
                error.ConnectionRefused => return,
                else => {},
            }
        };
    }
}
pub fn download_piece(peer_address: net.Address, file_data: []u8, info_hash: []u8, piece_info: PieceInfo) void {
    _download_piece(peer_address, file_data, info_hash, piece_info) catch unreachable;
}
fn _download_piece(peer_address: net.Address, piece_data: []u8, info_hash: []u8, piece_info: PieceInfo) !void {
    // std.debug.print("Start downloading piece-{d} ...\n", .{piece_info.index});
    // std.debug.print("piece_index={}, address={}\n", .{ piece_info.index, peer_address });
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const arena_alloc = arena.allocator();
    const stream = try net.tcpConnectToAddress(peer_address);
    defer stream.close();

    // var piece_data_buf = try std.ArrayList(u8).initCapacity(arena_alloc, piece_info.length);
    // handshake, just ignore the response message
    _ = try handshake.handshake(stream, info_hash, arena_alloc);
    // std.debug.print("finished the handshake!\n", .{});
    // defer arena_alloc.free(handshake_msg);

    // read bitfield
    const bitfield_msg_length = message.readLength(stream);
    const msg_buf = try arena_alloc.alloc(u8, bitfield_msg_length);
    // defer arena_alloc.free(msg_buf);
    const msg = try message.readBody(stream, msg_buf);
    assert(msg.ID == .bitfield);

    // send interested
    const interested = Message{ .ID = .interested };
    try interested.send(arena_alloc, stream);
    // receive unchoke
    const unchoke_length = message.readLength(stream);
    const unchoke_msg_buf = try arena_alloc.alloc(u8, unchoke_length);
    // defer arena_alloc.free(unchoke_msg_buf);
    const unchoke_msg = try message.readBody(stream, unchoke_msg_buf);
    assert(unchoke_msg.ID == .unchoke);
    assert(unchoke_msg.payload.len == 0);
    var begin_index: u32 = 0;
    while (begin_index * torrent.BLOCK_SIZE < piece_info.length) {
        try message.sendRequest(arena_alloc, stream, piece_info.length, piece_info.index, begin_index);
        // std.debug.print("request the begin_index={}\n", .{begin_index});

        // receive piece message
        const piece_length = message.readLength(stream);
        const piece_msg_buf = try arena_alloc.alloc(u8, piece_length);
        defer arena_alloc.free(piece_msg_buf);
        const piece_msg = try message.readBody(stream, piece_msg_buf);
        const piece_payload = message.readPiece(piece_msg);

        std.debug.assert(piece_payload.begin == begin_index * torrent.BLOCK_SIZE);
        std.debug.assert(piece_payload.index == piece_info.index);
        // std.debug.print("finish the begin_index={}\n", .{begin_index});
        // try piece_data_buf.appendSlice(piece_payload.block);
        const piece_start=begin_index*torrent.BLOCK_SIZE;
        const piece_end=piece_start + piece_payload.block.len;
        @memcpy(piece_data[piece_start..piece_end],piece_payload.block);
        begin_index += 1;
    }
    var sha1_buf: [20]u8 = undefined;
    Sha1.hash(piece_data, &sha1_buf, .{});
    std.debug.assert(std.mem.eql(u8, &sha1_buf, piece_info.hash));
    // try piece_data.appendSlice(piece_data_buf.items);
    // @memcpy(piece_data, piece_data_buf.items);
    // std.debug.print("Piece-{d} completed.\n", .{piece_info.index});
}
// const WorkQueue = struct{
//     std.
// }
pub fn main() !void {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const arena_alloc = arena.allocator();
    const filename = "/tmp/test-data.txt";
    const bt_filename = "sample.torrent";
    try downloadFile(arena_alloc, filename, bt_filename);
}
fn run_download_piece() !void {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const arena_alloc = arena.allocator();
    const bt_filename = "sample.torrent";
    // std.Thread.Pool.init()

    const bt_torrent_file = try std.fs.cwd().readFileAlloc(arena_alloc, bt_filename, 65535);
    defer arena_alloc.free(bt_torrent_file);
    var bt_torrent = try torrent.TorrentFile.parseTorrentFile(arena_alloc, bt_torrent_file);
    defer bt_torrent.deinit();
    const peer_addresses = bt_torrent.getPeerAddressesAlloc(arena_alloc);
    const address = peer_addresses[0];
    var piece_data: BufData = std.ArrayList(u8).init(arena_alloc);
    const piece_index = 0;
    const piece_length = bt_torrent.current_piece_length(piece_index);

    const piece_info = PieceInfo{
        .hash = bt_torrent.piece_hashes[piece_index],
        .index = piece_index,
        .length = piece_length,
    };

    try download_piece(address, &piece_data, bt_torrent.info_hash, piece_info);
    const file = try std.fs.cwd().createFile("test-data.txt", .{ .read = true });
    defer file.close();

    try file.writeAll(piece_data.items);
}
