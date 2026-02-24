const std = @import("std");
const entry_mod = @import("../model/entry.zig");
const object = @import("object.zig");
const index_mod = @import("index.zig");

pub const Entry = entry_mod.Entry;
pub const IndexEntry = index_mod.IndexEntry;

pub const Database = struct {
    allocator: std.mem.Allocator,
    dir: std.fs.Dir,
    objects_dir: std.fs.Dir,
    index: index_mod.Index,

    /// Open an existing database directory.
    pub fn open(allocator: std.mem.Allocator, base_dir: std.fs.Dir, name: []const u8) !Database {
        var dir = try base_dir.openDir(name, .{});
        errdefer dir.close();
        var objects_dir = try dir.openDir("objects", .{});
        errdefer objects_dir.close();
        const idx = try index_mod.Index.read(allocator, dir);
        return .{
            .allocator = allocator,
            .dir = dir,
            .objects_dir = objects_dir,
            .index = idx,
        };
    }

    /// Create a new database directory inside `base_dir`.
    pub fn create(allocator: std.mem.Allocator, base_dir: std.fs.Dir, name: []const u8) !Database {
        try base_dir.makeDir(name);
        var dir = try base_dir.openDir(name, .{});
        errdefer dir.close();
        try dir.makeDir("objects");
        var objects_dir = try dir.openDir("objects", .{});
        errdefer objects_dir.close();
        return .{
            .allocator = allocator,
            .dir = dir,
            .objects_dir = objects_dir,
            .index = index_mod.Index.init(allocator),
        };
    }

    pub fn deinit(self: *Database) void {
        self.index.deinit();
        self.objects_dir.close();
        self.dir.close();
    }

    /// Flush the index to disk.
    pub fn save(self: *Database) !void {
        try self.index.write(self.dir);
    }

    /// Return all index records. Slice is valid until the next mutation.
    pub fn listEntries(self: *const Database) []const IndexEntry {
        return self.index.entries.items;
    }

    /// Retrieve the current HEAD version of an entry.
    /// Caller must call `entry.deinit(allocator)` on the result.
    pub fn getEntry(self: *Database, entry_id: [20]u8) !Entry {
        const ie = self.index.find(entry_id) orelse return error.EntryNotFound;
        return self.getVersion(ie.head_hash);
    }

    /// Retrieve a specific version of an entry by its object hash.
    /// Caller must call `entry.deinit(allocator)` on the result.
    pub fn getVersion(self: *Database, h: [20]u8) !Entry {
        const blob = try object.read(self.allocator, self.objects_dir, h);
        defer self.allocator.free(blob);
        var stream = std.io.fixedBufferStream(blob);
        return Entry.deserialize(self.allocator, stream.reader());
    }

    /// Store a new entry (genesis version; `entry.parent_hash` must be null).
    /// Returns the entry_id, which is also the hash of this first version.
    pub fn createEntry(self: *Database, entry: Entry) ![20]u8 {
        if (entry.parent_hash != null) return error.ExpectedGenesisEntry;
        var buf: std.ArrayList(u8) = .{};
        defer buf.deinit(self.allocator);
        try entry.serialize(buf.writer(self.allocator));
        const h = try object.writeIfAbsent(self.objects_dir, buf.items);
        try self.index.addEntry(h, h, entry.title);
        return h;
    }

    /// Store a new version of an existing entry.
    /// `entry.parent_hash` must equal the current HEAD hash of `entry_id`.
    /// Returns the new HEAD hash.
    pub fn updateEntry(self: *Database, entry_id: [20]u8, entry: Entry) ![20]u8 {
        const ie = self.index.find(entry_id) orelse return error.EntryNotFound;
        const parent = entry.parent_hash orelse return error.MissingParentHash;
        if (!std.mem.eql(u8, &parent, &ie.head_hash)) return error.ParentHashMismatch;

        var buf: std.ArrayList(u8) = .{};
        defer buf.deinit(self.allocator);
        try entry.serialize(buf.writer(self.allocator));
        const new_hash = try object.writeIfAbsent(self.objects_dir, buf.items);
        try self.index.updateEntry(entry_id, new_hash, entry.title);
        return new_hash;
    }

    /// Remove an entry from the index. Objects are kept for history.
    pub fn deleteEntry(self: *Database, entry_id: [20]u8) !void {
        try self.index.removeEntry(entry_id);
    }
};

test "create, add entry, save, reopen" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const entry_id = blk: {
        var db = try Database.create(allocator, tmp.dir, "mydb");
        defer db.deinit();

        const id = try db.createEntry(.{
            .parent_hash = null,
            .title = "GitHub",
            .description = "My GitHub account",
            .url = "https://github.com",
            .username = "octocat",
            .password = "hunter2",
            .notes = "2FA enabled",
        });
        try db.save();
        break :blk id;
    };

    var db2 = try Database.open(allocator, tmp.dir, "mydb");
    defer db2.deinit();

    const entries = db2.listEntries();
    try std.testing.expectEqual(@as(usize, 1), entries.len);
    try std.testing.expectEqual(entry_id, entries[0].entry_id);
    try std.testing.expectEqualStrings("GitHub", entries[0].title);

    const loaded = try db2.getEntry(entry_id);
    defer loaded.deinit(allocator);
    try std.testing.expectEqualStrings("GitHub", loaded.title);
    try std.testing.expectEqualStrings("octocat", loaded.username);
    try std.testing.expectEqualStrings("hunter2", loaded.password);
    try std.testing.expect(loaded.parent_hash == null);
}

test "update entry creates version chain" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var db = try Database.create(allocator, tmp.dir, "versiondb");
    defer db.deinit();

    const entry_id = try db.createEntry(.{
        .parent_hash = null,
        .title = "MyService",
        .description = "",
        .url = "",
        .username = "user",
        .password = "pass1",
        .notes = "",
    });

    const v1_hash = db.listEntries()[0].head_hash;

    const v2_hash = try db.updateEntry(entry_id, .{
        .parent_hash = v1_hash,
        .title = "MyService",
        .description = "",
        .url = "",
        .username = "user",
        .password = "pass2",
        .notes = "",
    });

    // HEAD now points to v2
    const current = try db.getEntry(entry_id);
    defer current.deinit(allocator);
    try std.testing.expectEqualStrings("pass2", current.password);
    try std.testing.expectEqual(v1_hash, current.parent_hash.?);

    // v1 is still readable by hash
    const v1 = try db.getVersion(v1_hash);
    defer v1.deinit(allocator);
    try std.testing.expectEqualStrings("pass1", v1.password);
    try std.testing.expect(v1.parent_hash == null);

    _ = v2_hash;
}

test "updateEntry rejects wrong parent hash" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var db = try Database.create(allocator, tmp.dir, "rejectdb");
    defer db.deinit();

    const entry_id = try db.createEntry(.{
        .parent_hash = null,
        .title = "Entry",
        .description = "",
        .url = "",
        .username = "",
        .password = "original",
        .notes = "",
    });

    var bad_parent: [20]u8 = undefined;
    @memset(&bad_parent, 0xff);

    try std.testing.expectError(error.ParentHashMismatch, db.updateEntry(entry_id, .{
        .parent_hash = bad_parent,
        .title = "Entry",
        .description = "",
        .url = "",
        .username = "",
        .password = "modified",
        .notes = "",
    }));
}

test "deleteEntry removes from index but not objects" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var db = try Database.create(allocator, tmp.dir, "deletedb");
    defer db.deinit();

    const entry_id = try db.createEntry(.{
        .parent_hash = null,
        .title = "Temp",
        .description = "",
        .url = "",
        .username = "",
        .password = "",
        .notes = "",
    });
    const head = db.listEntries()[0].head_hash;

    try db.deleteEntry(entry_id);
    try std.testing.expectEqual(@as(usize, 0), db.listEntries().len);

    // Object is still readable by hash
    const blob = try db.getVersion(head);
    defer blob.deinit(allocator);
    try std.testing.expectEqualStrings("Temp", blob.title);
}
