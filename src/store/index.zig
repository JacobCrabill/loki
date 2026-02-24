const std = @import("std");

/// Magic bytes + version identifying PazzMan index files.
const MAGIC = "PZMIDX\x00\x01";

/// A single record in the index mapping a stable entry ID to its current HEAD.
pub const IndexEntry = struct {
    /// The SHA-1 hash of the genesis version; stable identifier for the entry.
    entry_id: [20]u8,
    /// The SHA-1 hash of the most recent version.
    head_hash: [20]u8,
    /// Cached title for fast listing without decrypting objects.
    title: []const u8,
};

/// Binary index file format:
///   8 bytes  magic + version
///   4 bytes  entry count (u32 LE)
///   per entry:
///     20 bytes  entry_id
///     20 bytes  head_hash
///      2 bytes  title length (u16 LE)
///      N bytes  title (UTF-8)
pub const Index = struct {
    allocator: std.mem.Allocator,
    entries: std.ArrayList(IndexEntry),

    pub fn init(allocator: std.mem.Allocator) Index {
        return .{ .allocator = allocator, .entries = .{} };
    }

    pub fn deinit(self: *Index) void {
        for (self.entries.items) |e| self.allocator.free(e.title);
        self.entries.deinit(self.allocator);
    }

    /// Read the index from `dir`. Returns an empty index if the file is absent.
    pub fn read(allocator: std.mem.Allocator, dir: std.fs.Dir) !Index {
        var idx = Index.init(allocator);
        errdefer idx.deinit();

        const file = dir.openFile("index", .{}) catch |err| {
            if (err == error.FileNotFound) return idx;
            return err;
        };
        defer file.close();

        const content = try file.readToEndAlloc(allocator, 16 * 1024 * 1024);
        defer allocator.free(content);

        var stream = std.io.fixedBufferStream(content);
        const r = stream.reader();

        var magic: [8]u8 = undefined;
        try r.readNoEof(&magic);
        if (!std.mem.eql(u8, &magic, MAGIC)) return error.InvalidIndexFormat;

        const count = try r.readInt(u32, .little);
        try idx.entries.ensureTotalCapacity(allocator, count);

        for (0..count) |_| {
            var entry_id: [20]u8 = undefined;
            try r.readNoEof(&entry_id);

            var head_hash: [20]u8 = undefined;
            try r.readNoEof(&head_hash);

            const title_len = try r.readInt(u16, .little);
            const title = try allocator.alloc(u8, title_len);
            errdefer allocator.free(title);
            try r.readNoEof(title);

            idx.entries.appendAssumeCapacity(.{
                .entry_id = entry_id,
                .head_hash = head_hash,
                .title = title,
            });
        }

        return idx;
    }

    /// Write the index to `dir`, overwriting any existing file.
    pub fn write(self: *const Index, dir: std.fs.Dir) !void {
        var buf: std.ArrayList(u8) = .{};
        defer buf.deinit(self.allocator);

        const w = buf.writer(self.allocator);
        try w.writeAll(MAGIC);
        try w.writeInt(u32, @intCast(self.entries.items.len), .little);

        for (self.entries.items) |e| {
            try w.writeAll(&e.entry_id);
            try w.writeAll(&e.head_hash);
            try w.writeInt(u16, @intCast(e.title.len), .little);
            try w.writeAll(e.title);
        }

        const file = try dir.createFile("index", .{});
        defer file.close();
        try file.writeAll(buf.items);
    }

    /// Look up an entry by ID. Returns a mutable pointer into the entries slice.
    pub fn find(self: *Index, entry_id: [20]u8) ?*IndexEntry {
        for (self.entries.items) |*e| {
            if (std.mem.eql(u8, &e.entry_id, &entry_id)) return e;
        }
        return null;
    }

    /// Add a new entry record. Dupes `title` into the index allocator.
    pub fn addEntry(self: *Index, entry_id: [20]u8, head_hash: [20]u8, title: []const u8) !void {
        const title_copy = try self.allocator.dupe(u8, title);
        errdefer self.allocator.free(title_copy);
        try self.entries.append(self.allocator, .{
            .entry_id = entry_id,
            .head_hash = head_hash,
            .title = title_copy,
        });
    }

    /// Update the HEAD and title for an existing entry.
    pub fn updateEntry(self: *Index, entry_id: [20]u8, head_hash: [20]u8, title: []const u8) !void {
        const e = self.find(entry_id) orelse return error.EntryNotFound;
        e.head_hash = head_hash;
        self.allocator.free(e.title);
        e.title = try self.allocator.dupe(u8, title);
    }

    /// Remove an entry record. The underlying objects are not deleted.
    pub fn removeEntry(self: *Index, entry_id: [20]u8) !void {
        for (self.entries.items, 0..) |e, i| {
            if (std.mem.eql(u8, &e.entry_id, &entry_id)) {
                self.allocator.free(e.title);
                _ = self.entries.swapRemove(i);
                return;
            }
        }
        return error.EntryNotFound;
    }
};

test "empty index writes and reads back" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var idx = Index.init(allocator);
    defer idx.deinit();
    try idx.write(tmp.dir);

    var loaded = try Index.read(allocator, tmp.dir);
    defer loaded.deinit();
    try std.testing.expectEqual(@as(usize, 0), loaded.entries.items.len);
}

test "missing index file returns empty index" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var loaded = try Index.read(allocator, tmp.dir);
    defer loaded.deinit();
    try std.testing.expectEqual(@as(usize, 0), loaded.entries.items.len);
}

test "roundtrip with multiple entries" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var id1: [20]u8 = undefined;
    @memset(&id1, 0x11);
    var h1: [20]u8 = undefined;
    @memset(&h1, 0x22);

    var id2: [20]u8 = undefined;
    @memset(&id2, 0x33);
    var h2: [20]u8 = undefined;
    @memset(&h2, 0x44);

    var idx = Index.init(allocator);
    defer idx.deinit();
    try idx.addEntry(id1, h1, "First Entry");
    try idx.addEntry(id2, h2, "Second Entry");
    try idx.write(tmp.dir);

    var loaded = try Index.read(allocator, tmp.dir);
    defer loaded.deinit();

    try std.testing.expectEqual(@as(usize, 2), loaded.entries.items.len);
    try std.testing.expectEqual(id1, loaded.entries.items[0].entry_id);
    try std.testing.expectEqual(h1, loaded.entries.items[0].head_hash);
    try std.testing.expectEqualStrings("First Entry", loaded.entries.items[0].title);
    try std.testing.expectEqual(id2, loaded.entries.items[1].entry_id);
    try std.testing.expectEqualStrings("Second Entry", loaded.entries.items[1].title);
}

test "updateEntry" {
    const allocator = std.testing.allocator;
    var id: [20]u8 = undefined;
    @memset(&id, 0x01);
    var h1: [20]u8 = undefined;
    @memset(&h1, 0x02);
    var h2: [20]u8 = undefined;
    @memset(&h2, 0x03);

    var idx = Index.init(allocator);
    defer idx.deinit();
    try idx.addEntry(id, h1, "Original Title");
    try idx.updateEntry(id, h2, "New Title");

    try std.testing.expectEqual(h2, idx.entries.items[0].head_hash);
    try std.testing.expectEqualStrings("New Title", idx.entries.items[0].title);
}

test "removeEntry" {
    const allocator = std.testing.allocator;
    var id: [20]u8 = undefined;
    @memset(&id, 0x01);
    var h: [20]u8 = undefined;
    @memset(&h, 0x02);

    var idx = Index.init(allocator);
    defer idx.deinit();
    try idx.addEntry(id, h, "To Remove");
    try idx.removeEntry(id);
    try std.testing.expectEqual(@as(usize, 0), idx.entries.items.len);
}
