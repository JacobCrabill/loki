const std = @import("std");
const loki = @import("loki");
const utils = @import("utils.zig");

const tcp_sync = loki.store.tcp_sync;
const Role = tcp_sync.Role;
const ConflictEntry = tcp_sync.ConflictEntry;

pub const default_port: u16 = 7777;

// ---------------------------------------------------------------------------
// serve
// ---------------------------------------------------------------------------

/// Listen for a single incoming connection, sync, then exit.
pub fn serve(
    allocator: std.mem.Allocator,
    db_path: []const u8,
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

    const addr = try std.net.Address.parseIp("0.0.0.0", port);
    var server = try addr.listen(.{ .reuse_address = true });
    defer server.deinit();

    const port_str = try std.fmt.allocPrint(allocator, "Listening on port {d}...\n", .{port});
    defer allocator.free(port_str);
    try stderr.writeAll(port_str);

    const conn = try server.accept();
    defer conn.stream.close();

    var r = conn.stream.reader(&.{});
    var w = conn.stream.writer(&.{});
    var conflicts: std.ArrayList(ConflictEntry) = .{};
    defer conflicts.deinit(allocator);

    const result = try tcp_sync.syncSession(allocator, &db, r.interface(), &w.interface, .server, &conflicts);
    try printResult(allocator, result);
}

// ---------------------------------------------------------------------------
// connect
// ---------------------------------------------------------------------------

/// Connect to a server and sync.
pub fn connect(
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
    var conflicts: std.ArrayList(ConflictEntry) = .{};
    defer conflicts.deinit(allocator);

    const result = try tcp_sync.syncSession(allocator, &db, r.interface(), &w.interface, .client, &conflicts);
    try printResult(allocator, result);
}

// ---------------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------------

fn printResult(allocator: std.mem.Allocator, result: tcp_sync.SyncResult) !void {
    const out = std.fs.File.stdout();
    const lines = try std.fmt.allocPrint(allocator,
        \\Sync complete.
        \\  Objects:       {d} pulled, {d} pushed
        \\  Fast-forwards: {d} local, {d} remote
        \\  New entries:   {d} to local, {d} to remote
        \\  Conflicts:     {d}
        \\
    , .{
        result.objects_pulled,
        result.objects_pushed,
        result.fast_forwarded,
        result.remote_advanced,
        result.new_to_local,
        result.new_to_remote,
        result.conflicts,
    });
    defer allocator.free(lines);
    try out.writeAll(lines);
    if (result.conflicts > 0) {
        try out.writeAll("Open the TUI to resolve conflicts.\n");
    }
}

/// Parse "host:port" into its components. Port defaults to `default_port`.
pub fn parseHostPort(addr: []const u8) struct { host: []const u8, port: u16 } {
    if (std.mem.lastIndexOfScalar(u8, addr, ':')) |colon| {
        const port = std.fmt.parseInt(u16, addr[colon + 1 ..], 10) catch return .{
            .host = addr,
            .port = default_port,
        };
        return .{ .host = addr[0..colon], .port = port };
    }
    return .{ .host = addr, .port = default_port };
}
