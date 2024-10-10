const std = @import("std");
const stdout = std.io.getStdOut().writer();
const torrent = @import("torrent_file.zig");
const bencode = @import("bencode.zig");
const http = std.http;
const net = std.net;
const handshake = @import("handshake.zig");
const Sha1 = std.crypto.hash.Sha1;
const bytes2hex = std.fmt.fmtSliceHexLower;
// const RndGen = std.rand.DefaultPrng;
const client =@import("client.zig");

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
        var context = bencode.BEContext{ .allocator = arena_alloc, .content = encodedStr };
        const ele = context.decode();
        const msg = try ele.toString(arena_alloc);
        try stdout.print("{s}\n", .{msg});
        // try cmd_decode(encodedStr, arena_alloc);
    } else if (std.mem.eql(u8, command, "info")) {
        const filename = args[2];
        const file_content = try std.fs.cwd().readFileAlloc(arena_alloc, filename, 65536);
        const bt_torrent = try torrent.TorrentFile.parseTorrentFile(arena_alloc, file_content);
        try stdout.print("Tracker URL: {s}\n", .{bt_torrent.announce});
        try stdout.print("Length: {d}\n", .{bt_torrent.info.length});
        try stdout.print("Info hash: {s}\n", .{bytes2hex(bt_torrent.info_hash)});
        try stdout.print("Piece Length: {d}\n", .{bt_torrent.info.piece_length});
        try stdout.print("Piece Hashes:\n", .{});
        for (bt_torrent.piece_hashes) |piece_hash| {
            try stdout.print("{s}\n", .{bytes2hex(piece_hash)});
        }
    } else if (std.mem.eql(u8, command, "peers")) {
        const filename = args[2];
        const file_content = try std.fs.cwd().readFileAlloc(arena_alloc, filename, 65536);
        var bt_torrent = try torrent.TorrentFile.parseTorrentFile(arena_alloc, file_content);
        const peer_addresses = bt_torrent.getPeerAddressesAlloc(arena_alloc);

        for (peer_addresses) |peer_address| {
            try peer_address.format("", .{}, stdout);
            try stdout.writeByte('\n');
        }
    } else if (std.mem.eql(u8, command, "handshake")) {
        const filename = args[2];
        const file_content = try std.fs.cwd().readFileAlloc(arena_alloc, filename, 65536);
        const bt_torrent = try torrent.TorrentFile.parseTorrentFile(arena_alloc, file_content);
        const address_str = args[3];
        var iter = std.mem.splitSequence(u8, address_str, ":");
        const ip_str = iter.next().?;
        const port_str = iter.next().?;
        const port = try std.fmt.parseInt(u16, port_str, 10);
        const address = net.Address.parseIp4(ip_str, port) catch unreachable;

        const stream = try net.tcpConnectToAddress(address);
        defer stream.close();
        try handshake.handshake(stream, bt_torrent);
    } else if (std.mem.eql(u8, command, "download_piece")) {
        if (!std.mem.eql(u8, args[2], "-o")) {
            try stdout.print("Wrong Argument in download_piece\n", .{});
            std.process.exit(1);
        }
        const temp_file = args[3];
        const bt_filename = args[4];
        const piece_index:u32 = try std.fmt.parseInt(u32,args[5],10);
        try client.download_piece(arena_alloc,bt_filename,temp_file,piece_index);
        // const index = try std.fmt.parseInt(u32, args[5], 10);
        // try download_piece(filename, temp_dir, index, arena_alloc);
    } else {
        try stdout.print("Unsupport command: {s}\n", .{command});
    }
}
