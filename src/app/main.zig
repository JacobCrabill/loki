const std = @import("std");
const known_folders = @import("known-folders");
const flags = @import("flags");

const app = @import("tui.zig").tui.app;
const utils = @import("utils.zig");
const cmds = @import("cmds.zig");

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
        merge: struct {
            remote: []const u8,
            local: ?[]const u8,
            pub const descriptions = .{};
        },

        /// loki serve [-p PORT] [db_path]
        serve: struct {
            port: u16 = utils.default_port,

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

        sync: struct {
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
            .fetch = "Download a database from a TCP server",
            .merge = "Locally merge two databases",
            .serve = "Listen for TCP sync/fetch connections",
            .sync = "Sync with a remote server over the network",
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

    const stdout = std.fs.File.stdout();
    var out = stdout.writer(&.{});

    if (cmd.command) |subcmd| {
        switch (subcmd) {
            .merge => |m| {
                const local_db = m.local orelse default_db_path orelse
                    fatal("cannot determine home directory");
                try cmds.merge.merge(allocator, &out.interface, local_db, m.remote);
            },
            .serve => |s| {
                const db_path = s.positional.db_path orelse default_db_path orelse
                    fatal("cannot determine home directory");
                try cmds.serve.serve(allocator, db_path, s.port);
            },
            .sync => |s| {
                const db_path = s.positional.db_path orelse default_db_path orelse
                    fatal("cannot determine home directory");
                const hp = utils.parseHostPort(s.positional.addr);
                try cmds.sync.syncNet(allocator, db_path, hp.host, hp.port);
            },
            .fetch => |s| {
                const db_path = s.positional.db_path orelse default_db_path orelse
                    fatal("cannot determine home directory");
                const hp = utils.parseHostPort(s.positional.addr);
                try cmds.fetch.fetch(allocator, db_path, hp.host, hp.port);
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
