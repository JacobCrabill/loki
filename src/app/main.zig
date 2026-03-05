const std = @import("std");
const app = @import("tui.zig").tui.app;
const sync_cmd = @import("sync_cmd.zig");
const tcp_sync_cmd = @import("tcp_sync_cmd.zig");
const known_folders = @import("known-folders");
const flags = @import("flags");

// ---------------------------------------------------------------------------
// CLI structure
// ---------------------------------------------------------------------------

/// Top-level flags struct for the `loki` command.
///
/// If no subcommand is given, loki opens the TUI on [db_path].
/// If a subcommand is given, an optional [db_path] positional *before* the
/// subcommand keyword selects the database (e.g. `loki mydb sync remote`).
const Loki = struct {
    positional: struct {
        db_path: ?[]const u8 = null,

        pub const descriptions = .{
            .db_path = "Database to open in the TUI (default: ~/.loki)",
        };
    },

    command: ?union(enum) {
        /// loki [db_path] sync <remote>
        sync: struct {
            positional: struct {
                remote: []const u8,

                pub const descriptions = .{
                    .remote = "Remote database: local path or user@host:/path",
                };
            },

            pub const description = "Sync the database with a remote copy";
        },

        /// loki serve [-p PORT] [db_path]
        serve: struct {
            port: u16 = tcp_sync_cmd.default_port,

            positional: struct {
                db_path: ?[]const u8 = null,

                pub const descriptions = .{
                    .db_path = "Database to serve (default: ~/.loki)",
                };
            },

            pub const description = "Listen for incoming TCP sync/fetch connections";
            pub const switches = .{ .port = 'p' };
            pub const descriptions = .{ .port = "Port to listen on" };
        },

        /// loki connect <addr> [db_path]
        connect: struct {
            positional: struct {
                addr: []const u8,
                db_path: ?[]const u8 = null,

                pub const descriptions = .{
                    .addr = "Server address: host or host:port",
                    .db_path = "Local database to sync (default: ~/.loki)",
                };
            },

            pub const description = "Connect to a TCP server and sync";
        },

        /// loki fetch <addr> [db_path]
        fetch: struct {
            positional: struct {
                addr: []const u8,
                db_path: ?[]const u8 = null,

                pub const descriptions = .{
                    .addr = "Server address: host or host:port",
                    .db_path = "Where to create the local database (default: ~/.loki)",
                };
            },

            pub const description = "Download a database from a TCP server";
        },

        pub const descriptions = .{
            .sync = "Sync with a remote (SSH or local path)",
            .serve = "Listen for TCP sync/fetch connections",
            .connect = "Sync with a TCP server",
            .fetch = "Download a database from a TCP server",
        };
    } = null,

    pub const description = "Loki - simple TUI password manager";
};

// ---------------------------------------------------------------------------
// Entry point
// ---------------------------------------------------------------------------

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    const raw_args = try std.process.argsAlloc(allocator);
    defer std.process.argsFree(allocator, raw_args);

    const cmd = flags.parse(raw_args, "loki", Loki, .{});

    // Resolve the default database path (~/.loki).
    const default_db_path: ?[]const u8 = blk: {
        const home = try known_folders.getPath(allocator, .home) orelse break :blk null;
        defer allocator.free(home);
        break :blk try std.fmt.allocPrint(allocator, "{s}/.loki", .{home});
    };
    defer if (default_db_path) |p| allocator.free(p);

    if (cmd.command) |subcmd| {
        switch (subcmd) {
            .sync => |s| {
                const db_path = cmd.positional.db_path orelse default_db_path orelse
                    fatal("cannot determine home directory");
                try sync_cmd.run(allocator, db_path, s.positional.remote);
            },
            .serve => |s| {
                const db_path = s.positional.db_path orelse default_db_path orelse
                    fatal("cannot determine home directory");
                try tcp_sync_cmd.serve(allocator, db_path, s.port);
            },
            .connect => |s| {
                const db_path = s.positional.db_path orelse default_db_path orelse
                    fatal("cannot determine home directory");
                const hp = tcp_sync_cmd.parseHostPort(s.positional.addr);
                try tcp_sync_cmd.connect(allocator, db_path, hp.host, hp.port);
            },
            .fetch => |s| {
                const db_path = s.positional.db_path orelse default_db_path orelse
                    fatal("cannot determine home directory");
                const hp = tcp_sync_cmd.parseHostPort(s.positional.addr);
                try tcp_sync_cmd.fetch(allocator, db_path, hp.host, hp.port);
            },
        }
    } else {
        const db_path = cmd.positional.db_path orelse default_db_path orelse
            fatal("cannot determine home directory");
        try app.run(allocator, db_path);
    }
}

fn fatal(msg: []const u8) noreturn {
    std.debug.print("Error: {s}\n", .{msg});
    std.process.exit(1);
}
