const std = @import("std");
const loki = @import("loki");
const zz = @import("zigzag");

const IndexEntry = loki.store.index.IndexEntry;

/// ASCII-art banner rendered on login.
pub const loki_art =
    \\ __         _____      __  __     ______
    \\/\ \       /\  __`\   /\ \/\ \   /\__  _\
    \\\ \ \      \ \ \/\ \  \ \ \/'/'  \/_/\ \/
    \\ \ \ \      \ \ \ \ \  \ \ , <      \ \ \
    \\  \ \ \____  \ \ \_\ \  \ \ \\`\     \_\ \__
    \\   \ \_____\  \ \_____\  \ \_\ \_\   /\_____\
    \\    \/_____/   \/_____/   \/_/\/_/   \/_____/
;
pub const loki_art_len: usize = 45;

/// Create a new database
pub fn createDb(pa: std.mem.Allocator, db_path: []const u8, password: ?[]const u8) !loki.Database {
    const dirname = std.fs.path.dirname(db_path) orelse ".";
    const basename = std.fs.path.basename(db_path);
    var base_dir = try std.fs.cwd().openDir(dirname, .{});
    defer base_dir.close();
    return loki.Database.create(pa, base_dir, basename, password);
}

/// Open an existing database
pub fn openDb(pa: std.mem.Allocator, db_path: []const u8, password: ?[]const u8) !loki.Database {
    const dirname = std.fs.path.dirname(db_path) orelse ".";
    const basename = std.fs.path.basename(db_path);
    var base_dir = try std.fs.cwd().openDir(dirname, .{});
    defer base_dir.close();
    return loki.Database.open(pa, base_dir, basename, password);
}

pub const DbState = enum { not_found, plaintext, encrypted };

/// Determine the state of the given database
pub fn detectDbState(db_path: []const u8) DbState {
    var dir = std.fs.cwd().openDir(db_path, .{}) catch return .not_found;
    defer dir.close();
    const f = dir.openFile("header", .{}) catch |err| {
        if (err == error.FileNotFound) return .plaintext;
        return .plaintext;
    };
    f.close();
    return .encrypted;
}

pub fn findHeadHash(entries: []const IndexEntry, entry_id: [20]u8) ?[20]u8 {
    for (entries) |ie| {
        if (std.mem.eql(u8, &ie.entry_id, &entry_id)) return ie.head_hash;
    }
    return null;
}

/// Command to change to the specified view
pub const ViewCmd = union(enum) {
    create,
    unlock: ?[]const u8,
    main,
    password,
    history,
};

// TODO: Msg enum/union type?
// e.g. one screen returns an Event on handleKey to transition to a new screen.
pub const Msg = union(enum) {
    key: zz.KeyEvent,
    set_view: ViewCmd,
};

pub const Cmd = zz.Cmd(Msg);
