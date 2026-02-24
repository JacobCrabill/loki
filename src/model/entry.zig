const std = @import("std");

/// A single version of a password entry.
///
/// `Entry` values returned from `deserialize` own their string fields and must
/// be freed with `deinit`. `Entry` values constructed by hand (e.g. from string
/// literals) must NOT be passed to `deinit`.
pub const Entry = struct {
    /// SHA-1 hash of the previous version, or null for the genesis version.
    parent_hash: ?[20]u8,
    title: []const u8,
    description: []const u8,
    url: []const u8,
    username: []const u8,
    password: []const u8,
    notes: []const u8,

    /// Serialize the entry into the given writer in PazzMan binary format.
    pub fn serialize(self: Entry, writer: anytype) !void {
        if (self.parent_hash) |h| {
            try writer.writeByte(1);
            try writer.writeAll(&h);
        } else {
            try writer.writeByte(0);
        }
        try writeString(writer, self.title);
        try writeString(writer, self.description);
        try writeString(writer, self.url);
        try writeString(writer, self.username);
        try writeString(writer, self.password);
        try writeString(writer, self.notes);
    }

    /// Deserialize an entry from the given reader.
    /// All string fields are allocated with `allocator`; free with `deinit`.
    pub fn deserialize(allocator: std.mem.Allocator, reader: anytype) !Entry {
        const has_parent = try reader.readByte();
        const parent_hash: ?[20]u8 = if (has_parent == 1) blk: {
            var h: [20]u8 = undefined;
            try reader.readNoEof(&h);
            break :blk h;
        } else null;

        const title = try readString(allocator, reader);
        errdefer allocator.free(title);
        const description = try readString(allocator, reader);
        errdefer allocator.free(description);
        const url = try readString(allocator, reader);
        errdefer allocator.free(url);
        const username = try readString(allocator, reader);
        errdefer allocator.free(username);
        const password = try readString(allocator, reader);
        errdefer allocator.free(password);
        const notes = try readString(allocator, reader);
        errdefer allocator.free(notes);

        return Entry{
            .parent_hash = parent_hash,
            .title = title,
            .description = description,
            .url = url,
            .username = username,
            .password = password,
            .notes = notes,
        };
    }

    /// Free all string fields. Only call on entries from `deserialize`.
    pub fn deinit(self: Entry, allocator: std.mem.Allocator) void {
        allocator.free(self.title);
        allocator.free(self.description);
        allocator.free(self.url);
        allocator.free(self.username);
        allocator.free(self.password);
        allocator.free(self.notes);
    }
};

fn writeString(writer: anytype, s: []const u8) !void {
    try writer.writeInt(u32, @intCast(s.len), .little);
    try writer.writeAll(s);
}

fn readString(allocator: std.mem.Allocator, reader: anytype) ![]u8 {
    const len = try reader.readInt(u32, .little);
    const buf = try allocator.alloc(u8, len);
    errdefer allocator.free(buf);
    try reader.readNoEof(buf);
    return buf;
}

test "roundtrip without parent hash" {
    const allocator = std.testing.allocator;
    const original = Entry{
        .parent_hash = null,
        .title = "GitHub",
        .description = "My GitHub account",
        .url = "https://github.com",
        .username = "octocat",
        .password = "hunter2",
        .notes = "2FA enabled",
    };

    var buf: std.ArrayList(u8) = .{};
    defer buf.deinit(allocator);
    try original.serialize(buf.writer(allocator));

    var stream = std.io.fixedBufferStream(buf.items);
    const loaded = try Entry.deserialize(allocator, stream.reader());
    defer loaded.deinit(allocator);

    try std.testing.expect(loaded.parent_hash == null);
    try std.testing.expectEqualStrings(original.title, loaded.title);
    try std.testing.expectEqualStrings(original.description, loaded.description);
    try std.testing.expectEqualStrings(original.url, loaded.url);
    try std.testing.expectEqualStrings(original.username, loaded.username);
    try std.testing.expectEqualStrings(original.password, loaded.password);
    try std.testing.expectEqualStrings(original.notes, loaded.notes);
}

test "roundtrip with parent hash" {
    const allocator = std.testing.allocator;
    var parent: [20]u8 = undefined;
    @memset(&parent, 0xab);

    const original = Entry{
        .parent_hash = parent,
        .title = "Updated",
        .description = "",
        .url = "",
        .username = "",
        .password = "newpass",
        .notes = "",
    };

    var buf: std.ArrayList(u8) = .{};
    defer buf.deinit(allocator);
    try original.serialize(buf.writer(allocator));

    var stream = std.io.fixedBufferStream(buf.items);
    const loaded = try Entry.deserialize(allocator, stream.reader());
    defer loaded.deinit(allocator);

    try std.testing.expectEqual(parent, loaded.parent_hash.?);
    try std.testing.expectEqualStrings("Updated", loaded.title);
    try std.testing.expectEqualStrings("newpass", loaded.password);
}

test "empty string fields" {
    const allocator = std.testing.allocator;
    const original = Entry{
        .parent_hash = null,
        .title = "",
        .description = "",
        .url = "",
        .username = "",
        .password = "",
        .notes = "",
    };

    var buf: std.ArrayList(u8) = .{};
    defer buf.deinit(allocator);
    try original.serialize(buf.writer(allocator));

    var stream = std.io.fixedBufferStream(buf.items);
    const loaded = try Entry.deserialize(allocator, stream.reader());
    defer loaded.deinit(allocator);

    try std.testing.expectEqualStrings("", loaded.title);
    try std.testing.expectEqualStrings("", loaded.password);
}
