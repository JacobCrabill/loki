/// Fetch a database from an remote server
const std = @import("std");
const loki = @import("loki");

const utils = @import("../utils.zig");

const sync = loki.sync;
const Role = sync.Role;
const ConflictEntry = loki.model.merge.ConflictEntry;

/// Connect to a server and download its database, creating it locally at
/// `db_path`. Prompts for the database password interactively.
pub fn fetch(
    allocator: std.mem.Allocator,
    db_path: []const u8,
    host: []const u8,
    port: u16,
) !void {
    const stderr = std.fs.File.stderr();

    const password = try utils.promptPassword(allocator);
    defer allocator.free(password);

    const addr_list = try std.net.getAddressList(allocator, host, port);
    defer addr_list.deinit();
    if (addr_list.addrs.len == 0) return error.UnknownHost;

    const stream = try std.net.tcpConnectToAddress(addr_list.addrs[0]);
    defer stream.close();

    var r = stream.reader(&.{});
    var w = stream.writer(&.{});
    const ri = r.interface();
    const wi = &w.interface;

    // Announce the fetch protocol.
    try wi.writeAll(&[_]u8{sync.net.protocol_fetch});

    // TODO: default to ~/.loki
    const dirname = std.fs.path.dirname(db_path) orelse ".";
    const basename = std.fs.path.basename(db_path);
    var base_dir = try std.fs.cwd().openDir(dirname, .{});
    defer base_dir.close();

    sync.net.fetchClient(allocator, password, base_dir, basename, ri, wi) catch |err| {
        if (err == error.WrongPassword) {
            try stderr.writeAll("Error: wrong password\n");
            return;
        }
        if (err == error.PathAlreadyExists) {
            try stderr.writeAll("Error: database already exists at that path\n");
            return;
        }
        return err;
    };

    const msg = try std.fmt.allocPrint(allocator, "Fetch complete. Database created at '{s}'.\n", .{db_path});
    defer allocator.free(msg);
    try std.fs.File.stdout().writeAll(msg);
}
