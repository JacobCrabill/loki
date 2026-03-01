const std = @import("std");
const app = @import("tui.zig").tui.app;
const sync_cmd = @import("sync_cmd.zig");
const tcp_sync_cmd = @import("tcp_sync_cmd.zig");
const known_folders = @import("known-folders");

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    const args = try std.process.argsAlloc(allocator);
    defer std.process.argsFree(allocator, args);

    // Resolve default database path (~/.loki).
    const default_db_path: ?[]const u8 = blk: {
        const home = try known_folders.getPath(allocator, .home) orelse break :blk null;
        defer allocator.free(home);
        break :blk try std.fmt.allocPrint(allocator, "{s}/.loki", .{home});
    };
    defer if (default_db_path) |p| allocator.free(p);

    // loki -h / --help
    if (args.len >= 2 and
        (std.mem.eql(u8, args[1], "-h") or std.mem.eql(u8, args[1], "--help")))
    {
        try printHelp(args[0]);
        std.process.exit(0);
    }

    // loki sync <remote>  →  sync default db with remote
    if (args.len == 3 and std.mem.eql(u8, args[1], "sync")) {
        const local = default_db_path orelse {
            std.debug.print("Error: cannot determine home directory\n", .{});
            std.process.exit(1);
        };
        try sync_cmd.run(allocator, local, args[2]);
        std.process.exit(0);
    }

    // loki <db_path> sync <remote>  →  sync explicit local db with remote
    if (args.len == 4 and std.mem.eql(u8, args[2], "sync")) {
        try sync_cmd.run(allocator, args[1], args[3]);
        std.process.exit(0);
    }

    // loki serve [port] [db_path]  →  serve default or explicit db
    if (args.len >= 2 and std.mem.eql(u8, args[1], "serve")) {
        const db_path = if (args.len >= 4) args[3] else (default_db_path orelse {
            std.debug.print("Error: cannot determine home directory\n", .{});
            std.process.exit(1);
        });
        const port: u16 = if (args.len >= 3)
            std.fmt.parseInt(u16, args[2], 10) catch tcp_sync_cmd.default_port
        else
            tcp_sync_cmd.default_port;
        try tcp_sync_cmd.serve(allocator, db_path, port);
        std.process.exit(0);
    }

    // loki connect <host:port> [db_path]  →  connect and sync
    if (args.len >= 3 and std.mem.eql(u8, args[1], "connect")) {
        const db_path = if (args.len >= 4) args[3] else (default_db_path orelse {
            std.debug.print("Error: cannot determine home directory\n", .{});
            std.process.exit(1);
        });
        const hp = tcp_sync_cmd.parseHostPort(args[2]);
        try tcp_sync_cmd.connect(allocator, db_path, hp.host, hp.port);
        std.process.exit(0);
    }

    // loki <db_path>  →  open TUI on specified db
    if (args.len >= 2) {
        try app.run(allocator, args[1]);
        std.process.exit(0);
    }

    // loki  →  open TUI on default db
    if (default_db_path) |db_path| {
        try app.run(allocator, db_path);
    } else {
        std.debug.print("Error: cannot determine home directory\n", .{});
        std.process.exit(1);
    }
}

fn printHelp(exe: []const u8) !void {
    const stderr = std.fs.File.stderr();
    const msg = try std.fmt.allocPrint(
        std.heap.page_allocator,
        \\Loki - simple TUI password manager
        \\
        \\Usage:
        \\  {s}                             open ~/.loki in the TUI
        \\  {s} <db_path>                  open <db_path> in the TUI
        \\  {s} sync <remote>              sync ~/.loki with <remote>
        \\  {s} <db_path> sync <remote>    sync <db_path> with <remote>
        \\  {s} serve [port] [db_path]     listen for a TCP sync (default port: 7777)
        \\  {s} connect <host[:port]> [db] sync with a TCP server
        \\
        \\<remote> (for sync) is a local path or an SSH path (user@host:/path).
        \\
    ,
        .{ exe, exe, exe, exe, exe, exe },
    );
    defer std.heap.page_allocator.free(msg);
    try stderr.writeAll(msg);
}
