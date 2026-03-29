const std = @import("std");
const loki = @import("loki");

const Database = loki.Database;

const Self = @This();

/// Path to the Loki database.
db_path: []const u8 = "",

/// The global Database instance
/// TODO: ?* ?
db: ?Database = null,

/// DEBUGGING
dbg_writer: *std.Io.Writer,

pub fn getDb(self: *Self) !*Database {
    return &(self.db orelse return error.DatabaseNotOpen);
}

/// Deinit the Context object
pub fn deinit(self: *Self) void {
    self.deinitDb();
}

/// Deinit and reset the Database instance
pub fn deinitDb(self: *Self) void {
    if (self.db) |*db| {
        db.deinit();
    }
    self.db = null;
}

/// DEBUGGING
pub fn log(self: *const Self, comptime fmt: []const u8, args: anytype) void {
    self.dbg_writer.print(fmt ++ "\n", args) catch {};
}
