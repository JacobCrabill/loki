const std = @import("std");
const entry_mod = @import("../model/entry.zig");
const object = @import("object.zig");
const index_mod = @import("index.zig");
const cipher = @import("../crypto/cipher.zig");
const kdf = @import("../crypto/kdf.zig");
const sync_mod = @import("sync.zig");

pub const Entry = entry_mod.Entry;
pub const IndexEntry = index_mod.IndexEntry;
pub const ConflictEntry = sync_mod.ConflictEntry;

pub const Database = struct {
    allocator: std.mem.Allocator,
    dir: std.fs.Dir,
    objects_dir: std.fs.Dir,
    index: index_mod.Index,
    /// Derived encryption key, or null for unencrypted databases.
    key: ?[cipher.key_length]u8,

    // -------------------------------------------------------------------------
    // Open / create
    // -------------------------------------------------------------------------

    /// Open an existing database. Pass `password` to unlock an encrypted
    /// database, or `null` for a plaintext one. Returns `error.WrongPassword`
    /// if the password does not match the stored header.
    pub fn open(
        allocator: std.mem.Allocator,
        base_dir: std.fs.Dir,
        name: []const u8,
        password: ?[]const u8,
    ) !Database {
        var dir = try base_dir.openDir(name, .{});
        errdefer dir.close();
        var objects_dir = try dir.openDir("objects", .{});
        errdefer objects_dir.close();

        const derived_key: ?[cipher.key_length]u8 = if (password) |pw| blk: {
            const header = try kdf.readHeader(dir);
            const k = try kdf.verifyPassword(allocator, pw, header) orelse
                return error.WrongPassword;
            break :blk k;
        } else null;

        var db = Database{
            .allocator = allocator,
            .dir = dir,
            .objects_dir = objects_dir,
            .index = undefined,
            .key = derived_key,
        };
        db.index = try db.loadIndex();
        return db;
    }

    /// Create a new database directory inside `base_dir`. Pass `password` to
    /// create an encrypted database, or `null` for a plaintext one.
    pub fn create(
        allocator: std.mem.Allocator,
        base_dir: std.fs.Dir,
        name: []const u8,
        password: ?[]const u8,
    ) !Database {
        try base_dir.makeDir(name);
        var dir = try base_dir.openDir(name, .{});
        errdefer dir.close();
        try dir.makeDir("objects");
        var objects_dir = try dir.openDir("objects", .{});
        errdefer objects_dir.close();

        const derived_key: ?[cipher.key_length]u8 = if (password) |pw| blk: {
            const result = try kdf.createHeader(allocator, pw, kdf.default_params);
            try kdf.writeHeader(result.header, dir);
            break :blk result.key;
        } else null;

        return Database{
            .allocator = allocator,
            .dir = dir,
            .objects_dir = objects_dir,
            .index = index_mod.Index.init(allocator),
            .key = derived_key,
        };
    }

    pub fn deinit(self: *Database) void {
        self.index.deinit();
        self.objects_dir.close();
        self.dir.close();
    }

    // -------------------------------------------------------------------------
    // Persistence
    // -------------------------------------------------------------------------

    /// Flush the index to disk, encrypting it if the database has a key.
    pub fn save(self: *Database) !void {
        var buf: std.ArrayList(u8) = .{};
        defer buf.deinit(self.allocator);
        try self.index.writeTo(buf.writer(self.allocator));

        const file = try self.dir.createFile("index", .{});
        defer file.close();

        if (self.key) |k| {
            const blob = try cipher.encrypt(self.allocator, k, buf.items);
            defer self.allocator.free(blob);
            try file.writeAll(blob);
        } else {
            try file.writeAll(buf.items);
        }
    }

    // -------------------------------------------------------------------------
    // Queries
    // -------------------------------------------------------------------------

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

    /// Retrieve a specific version by its object hash.
    /// Caller must call `entry.deinit(allocator)` on the result.
    pub fn getVersion(self: *Database, h: [20]u8) !Entry {
        const plaintext = try self.readObject(h);
        defer self.allocator.free(plaintext);
        var stream = std.io.fixedBufferStream(plaintext);
        return entry_mod.Entry.deserialize(self.allocator, stream.reader());
    }

    // -------------------------------------------------------------------------
    // Mutations
    // -------------------------------------------------------------------------

    /// Store a new entry (genesis version; `entry.parent_hash` must be null).
    /// Returns the entry_id (= hash of the genesis object).
    pub fn createEntry(self: *Database, entry: Entry) ![20]u8 {
        if (entry.parent_hash != null) return error.ExpectedGenesisEntry;
        var buf: std.ArrayList(u8) = .{};
        defer buf.deinit(self.allocator);
        try entry.serialize(buf.writer(self.allocator));
        const h = try self.writeObject(buf.items);
        try self.index.addEntry(h, h, entry.title, entry.path);
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
        const new_hash = try self.writeObject(buf.items);
        try self.index.updateEntry(entry_id, new_hash, entry.title, entry.path);
        return new_hash;
    }

    /// Remove an entry from the index. Objects are retained for history.
    pub fn deleteEntry(self: *Database, entry_id: [20]u8) !void {
        try self.index.removeEntry(entry_id);
    }

    /// Update just the index HEAD pointer for `entry_id` without creating a new
    /// object.  Used by conflict resolution to fast-forward or set a resolved
    /// merge HEAD.  Unlike `updateEntry` this does NOT validate parent_hash.
    pub fn setHead(
        self: *Database,
        entry_id: [20]u8,
        head_hash: [20]u8,
        title: []const u8,
        path: []const u8,
    ) !void {
        try self.index.updateEntry(entry_id, head_hash, title, path);
    }

    // -------------------------------------------------------------------------
    // Conflict persistence
    // -------------------------------------------------------------------------

    /// Write pending conflicts to `db_dir/conflicts`.
    /// Format: u32 count (little-endian) + N × 60 bytes
    ///   (entry_id[20] + local_hash[20] + remote_hash[20]).
    /// Hashes are not encrypted — they are non-secret identifiers.
    pub fn saveConflicts(self: *Database, conflicts: []const ConflictEntry) !void {
        // Serialise into a buffer then write atomically.
        var buf: std.ArrayList(u8) = .{};
        defer buf.deinit(self.allocator);
        const w = buf.writer(self.allocator);
        try w.writeInt(u32, @intCast(conflicts.len), .little);
        for (conflicts) |c| {
            try w.writeAll(&c.entry_id);
            try w.writeAll(&c.local_hash);
            try w.writeAll(&c.remote_hash);
        }
        const file = try self.dir.createFile("conflicts", .{});
        defer file.close();
        try file.writeAll(buf.items);
    }

    /// Load pending conflicts from `db_dir/conflicts`.
    /// Returns an empty slice when the file does not exist.
    /// Caller must free the returned slice with `allocator.free(slice)`.
    pub fn loadConflicts(self: *Database, allocator: std.mem.Allocator) ![]ConflictEntry {
        const raw = self.dir.readFileAlloc(allocator, "conflicts", 64 * 1024) catch |err| {
            if (err == error.FileNotFound) return &.{};
            return err;
        };
        defer allocator.free(raw);
        if (raw.len < 4) return &.{};
        const count = std.mem.readInt(u32, raw[0..4], .little);
        if (raw.len < 4 + @as(usize, count) * 60) return &.{};
        const list = try allocator.alloc(ConflictEntry, count);
        for (list, 0..) |*c, i| {
            const base = 4 + i * 60;
            @memcpy(&c.entry_id, raw[base..][0..20]);
            @memcpy(&c.local_hash, raw[base + 20 ..][0..20]);
            @memcpy(&c.remote_hash, raw[base + 40 ..][0..20]);
        }
        return list;
    }

    /// Delete `db_dir/conflicts`.  No-op when the file does not exist.
    pub fn clearConflicts(self: *Database) void {
        self.dir.deleteFile("conflicts") catch {};
    }

    // -------------------------------------------------------------------------
    // Private helpers
    // -------------------------------------------------------------------------

    /// Write a plaintext blob to the object store, encrypting it when the
    /// database has a key. The object filename is SHA-1(plaintext) regardless
    /// of whether the stored bytes are encrypted. Idempotent.
    fn writeObject(self: *Database, plaintext: []const u8) ![20]u8 {
        const h = object.hash(plaintext);
        const hex = object.hashToHex(h);

        if (self.key) |k| {
            const blob = try cipher.encrypt(self.allocator, k, plaintext);
            defer self.allocator.free(blob);
            const file = self.objects_dir.createFile(&hex, .{ .exclusive = true }) catch |err| {
                if (err == error.PathAlreadyExists) return h;
                return err;
            };
            defer file.close();
            try file.writeAll(blob);
        } else {
            _ = try object.writeIfAbsent(self.objects_dir, plaintext);
        }
        return h;
    }

    /// Read an object by hash, decrypting it when the database has a key.
    /// Caller must free the returned slice.
    fn readObject(self: *Database, h: [20]u8) ![]u8 {
        const raw = try object.read(self.allocator, self.objects_dir, h);
        if (self.key) |k| {
            defer self.allocator.free(raw);
            return cipher.decrypt(self.allocator, k, raw);
        }
        return raw;
    }

    /// Load the index file, decrypting if needed. Called once during open/create.
    fn loadIndex(self: *Database) !index_mod.Index {
        const file = self.dir.openFile("index", .{}) catch |err| {
            if (err == error.FileNotFound) return index_mod.Index.init(self.allocator);
            return err;
        };
        defer file.close();

        const raw = try file.readToEndAlloc(self.allocator, 64 * 1024 * 1024);
        defer self.allocator.free(raw);

        if (self.key) |k| {
            const plaintext = try cipher.decrypt(self.allocator, k, raw);
            defer self.allocator.free(plaintext);
            return index_mod.Index.fromBytes(self.allocator, plaintext);
        }
        return index_mod.Index.fromBytes(self.allocator, raw);
    }
};

// =============================================================================
// Tests
// =============================================================================

test "plaintext: create, add entry, save, reopen" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const entry_id = blk: {
        var db = try Database.create(allocator, tmp.dir, "mydb", null);
        defer db.deinit();
        const id = try db.createEntry(.{
            .parent_hash = null,
            .path = "",
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

    var db2 = try Database.open(allocator, tmp.dir, "mydb", null);
    defer db2.deinit();

    const entries = db2.listEntries();
    try std.testing.expectEqual(@as(usize, 1), entries.len);
    try std.testing.expectEqual(entry_id, entries[0].entry_id);
    try std.testing.expectEqualStrings("GitHub", entries[0].title);

    const loaded = try db2.getEntry(entry_id);
    defer loaded.deinit(allocator);
    try std.testing.expectEqualStrings("octocat", loaded.username);
    try std.testing.expectEqualStrings("hunter2", loaded.password);
    try std.testing.expect(loaded.parent_hash == null);
}

test "plaintext: update entry creates version chain" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var db = try Database.create(allocator, tmp.dir, "vdb", null);
    defer db.deinit();

    const entry_id = try db.createEntry(.{
        .parent_hash = null,
        .path = "",
        .title = "MyService",
        .description = "",
        .url = "",
        .username = "user",
        .password = "pass1",
        .notes = "",
    });
    const v1_hash = db.listEntries()[0].head_hash;

    _ = try db.updateEntry(entry_id, .{
        .parent_hash = v1_hash,
        .path = "",
        .title = "MyService",
        .description = "",
        .url = "",
        .username = "user",
        .password = "pass2",
        .notes = "",
    });

    const current = try db.getEntry(entry_id);
    defer current.deinit(allocator);
    try std.testing.expectEqualStrings("pass2", current.password);
    try std.testing.expectEqual(v1_hash, current.parent_hash.?);

    const v1 = try db.getVersion(v1_hash);
    defer v1.deinit(allocator);
    try std.testing.expectEqualStrings("pass1", v1.password);
}

test "plaintext: updateEntry rejects wrong parent hash" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var db = try Database.create(allocator, tmp.dir, "rdb", null);
    defer db.deinit();

    const entry_id = try db.createEntry(.{
        .parent_hash = null,
        .path = "",
        .title = "Entry",
        .description = "",
        .url = "",
        .username = "",
        .password = "original",
        .notes = "",
    });
    var bad: [20]u8 = undefined;
    @memset(&bad, 0xff);
    try std.testing.expectError(error.ParentHashMismatch, db.updateEntry(entry_id, .{
        .parent_hash = bad,
        .path = "",
        .title = "Entry",
        .description = "",
        .url = "",
        .username = "",
        .password = "modified",
        .notes = "",
    }));
}

test "plaintext: deleteEntry removes from index but not objects" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var db = try Database.create(allocator, tmp.dir, "ddb", null);
    defer db.deinit();

    const entry_id = try db.createEntry(.{
        .parent_hash = null,
        .path = "",
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

    const blob = try db.getVersion(head);
    defer blob.deinit(allocator);
    try std.testing.expectEqualStrings("Temp", blob.title);
}

test "encrypted: create, add entry, save, reopen with correct password" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const entry_id = blk: {
        var db = try Database.create(allocator, tmp.dir, "edb", "s3cr3t");
        defer db.deinit();
        const id = try db.createEntry(.{
            .parent_hash = null,
            .path = "",
            .title = "Twitter",
            .description = "",
            .url = "https://twitter.com",
            .username = "bird",
            .password = "chirp123",
            .notes = "",
        });
        try db.save();
        break :blk id;
    };

    var db2 = try Database.open(allocator, tmp.dir, "edb", "s3cr3t");
    defer db2.deinit();

    const entries = db2.listEntries();
    try std.testing.expectEqual(@as(usize, 1), entries.len);
    try std.testing.expectEqualStrings("Twitter", entries[0].title);
    try std.testing.expectEqual(entry_id, entries[0].entry_id);

    const loaded = try db2.getEntry(entry_id);
    defer loaded.deinit(allocator);
    try std.testing.expectEqualStrings("chirp123", loaded.password);
}

test "encrypted: wrong password returns WrongPassword" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    {
        var db = try Database.create(allocator, tmp.dir, "wdb", "correct");
        defer db.deinit();
        try db.save();
    }

    try std.testing.expectError(
        error.WrongPassword,
        Database.open(allocator, tmp.dir, "wdb", "incorrect"),
    );
}

test "encrypted: objects are not readable as plaintext" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var db = try Database.create(allocator, tmp.dir, "opaquedb", "pw");
    defer db.deinit();

    const entry_id = try db.createEntry(.{
        .parent_hash = null,
        .path = "",
        .title = "Secret",
        .description = "",
        .url = "",
        .username = "",
        .password = "topsecret",
        .notes = "",
    });
    const head = db.listEntries()[0].head_hash;
    _ = entry_id;

    // Reading the raw object bytes should NOT decode as a valid entry.
    const raw = try object.read(allocator, db.objects_dir, head);
    defer allocator.free(raw);
    var stream = std.io.fixedBufferStream(raw);
    try std.testing.expectError(
        error.EndOfStream,
        entry_mod.Entry.deserialize(allocator, stream.reader()),
    );
}
