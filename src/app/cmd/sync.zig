/// Sync a local database with a remote server (bidirectional)
const std = @import("std");
const loki = @import("loki");

const utils = @import("../utils.zig");

const net_sync = loki.sync.net;
const Role = net_sync.Role;
const ConflictEntry = loki.model.merge.ConflictEntry;

/// Connect to a server and sync.
pub fn syncNet(
    allocator: std.mem.Allocator,
    db_path: []const u8,
    host: []const u8,
    port: u16,
) !void {
    const stderr = std.fs.File.stderr();

    const password = if (utils.detectEncrypted(db_path))
        try utils.promptPassword(allocator)
    else
        return error.UnencryptedDatabase;
    defer allocator.free(password);

    var db = utils.openDb(allocator, db_path, password) catch |err| {
        if (err == error.WrongPassword) {
            try stderr.writeAll("Error: wrong password\n");
            return;
        }
        return err;
    };
    defer db.deinit();

    const addr_list = try std.net.getAddressList(allocator, host, port);
    defer addr_list.deinit();
    if (addr_list.addrs.len == 0) return error.UnknownHost;

    const stream = try std.net.tcpConnectToAddress(addr_list.addrs[0]);
    defer stream.close();

    var r = stream.reader(&.{});
    var w = stream.writer(&.{});
    const ri = r.interface();
    const wi = &w.interface;

    // Send the protocol discriminator before anything else.
    try wi.writeAll(&[_]u8{@intFromEnum(net_sync.Protocol.sync)});

    var conflicts: std.ArrayList(ConflictEntry) = .{};
    defer conflicts.deinit(allocator);

    const result = try net_sync.syncSession(allocator, &db, ri, wi, .client, &conflicts);

    var stdout = std.fs.File.stdout().writer(&.{});
    try utils.printMergeResult(allocator, &stdout.interface, result);
}
