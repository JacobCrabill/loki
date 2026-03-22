/// Run a server responding to 'fetch' or 'sync' requests
const std = @import("std");
const loki = @import("loki");

const utils = @import("../utils.zig");

const net_sync = loki.sync.net;
const Role = loki.sync.net.Role;
const ConflictEntry = loki.model.merge.ConflictEntry;

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

    // We'll first ensure we can open the database before we start the server.
    // However, because a user could interact with the database while the server
    // is running, we want to only open and read it when we need to, then close
    // it again.
    {
        var db = utils.openDb(allocator, db_path, password) catch |err| {
            if (err == error.WrongPassword) {
                try stderr.writeAll("Error: wrong password\n");
                return;
            }
            return err;
        };
        defer db.deinit();
    }

    const addr = try std.net.Address.parseIp("0.0.0.0", port);
    var server = try addr.listen(.{ .reuse_address = true });
    defer server.deinit();

    const port_str = try std.fmt.allocPrint(allocator, "Listening on port {d}...\n", .{port});
    defer allocator.free(port_str);
    try stderr.writeAll(port_str);

    while (true) {
        const conn = try server.accept();
        defer conn.stream.close();

        var r = conn.stream.reader(&.{});
        var w = conn.stream.writer(&.{});
        const ri = r.interface();
        const wi = &w.interface;

        // Open the database now that we're ready to read and make edits
        var db = utils.openDb(allocator, db_path, password) catch |err| {
            if (err == error.WrongPassword) {
                try stderr.writeAll("Error: wrong password\n");
                return;
            }
            return err;
        };
        defer db.deinit();

        // Read the one-byte protocol discriminator to decide which protocol to run.
        var disc: [1]u8 = undefined;
        try ri.readSliceAll(&disc);
        const proto: net_sync.Protocol = @enumFromInt(disc[0]);

        switch (proto) {
            .sync => {
                var conflicts: std.ArrayList(ConflictEntry) = .{};
                defer conflicts.deinit(allocator);
                const result = try net_sync.syncSession(allocator, &db, ri, wi, .server, &conflicts);
                var stdout = std.fs.File.stdout().writer(&.{});
                try utils.printMergeResult(allocator, &stdout.interface, result);
            },
            .fetch => {
                try net_sync.fetchServe(allocator, &db, ri, wi);
                try stderr.writeAll("Fetch served successfully.\n");
            },
            else => {
                std.debug.print("error: UnknownProtocol\n", .{});
                continue;
            },
        }
    }
}
