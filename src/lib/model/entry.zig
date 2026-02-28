const std = @import("std");

const SHA1_SIZE = 20;

/// A single version of a password entry.
///
/// `Entry` values returned from `deserialize` own their string fields and must
/// be freed with `deinit`. `Entry` values constructed by hand (e.g. from string
/// literals) must NOT be passed to `deinit`.
pub const Entry = struct {
    /// SHA-1 hash of the previous version, or null for the genesis version.
    parent_hash: ?[SHA1_SIZE]u8,
    /// SHA-1 hash of the other branch merged into this version (conflict
    /// resolution commits only). Enables `isAncestor` to follow both branches
    /// so the next sync fast-forwards the remote rather than re-conflicting.
    merge_parent_hash: ?[SHA1_SIZE]u8 = null,
    /// Forward-slash-separated folder path, e.g. "Work/Acme-Inc". Empty string
    /// means the entry lives at the root.
    path: []const u8,
    title: []const u8,
    description: []const u8,
    url: []const u8,
    username: []const u8,
    password: []const u8,
    notes: []const u8,

    /// Serialize the entry into the given writer in Loki binary format.
    ///
    /// Flags byte layout (bit 0 = has parent_hash, bit 1 = has merge_parent_hash).
    /// Old objects used raw 0/1 for this byte; bit 1 was always 0, so they
    /// deserialize correctly with merge_parent_hash = null.
    pub fn serialize(self: Entry, writer: anytype) !void {
        const flags: u8 = (if (self.parent_hash != null) @as(u8, 1) else 0) |
            (if (self.merge_parent_hash != null) @as(u8, 2) else 0);
        try writer.writeByte(flags);
        if (self.parent_hash) |h| try writer.writeAll(&h);
        if (self.merge_parent_hash) |h| try writer.writeAll(&h);
        try writeString(writer, self.path);
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
        const flags = try reader.readByte();
        const parent_hash: ?[SHA1_SIZE]u8 = if (flags & 1 != 0) blk: {
            var h: [SHA1_SIZE]u8 = undefined;
            try reader.readNoEof(&h);
            break :blk h;
        } else null;
        const merge_parent_hash: ?[SHA1_SIZE]u8 = if (flags & 2 != 0) blk: {
            var h: [SHA1_SIZE]u8 = undefined;
            try reader.readNoEof(&h);
            break :blk h;
        } else null;

        const path = try readString(allocator, reader);
        errdefer allocator.free(path);
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
            .merge_parent_hash = merge_parent_hash,
            .path = path,
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
        allocator.free(self.path);
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

test "roundtrip with merge_parent_hash" {
    const allocator = std.testing.allocator;
    var parent: [20]u8 = undefined;
    @memset(&parent, 0xcc);
    var merge_parent: [20]u8 = undefined;
    @memset(&merge_parent, 0xdd);

    const original = Entry{
        .parent_hash = parent,
        .merge_parent_hash = merge_parent,
        .path = "Work",
        .title = "Merged",
        .description = "",
        .url = "",
        .username = "u",
        .password = "p",
        .notes = "",
    };

    var buf: std.ArrayList(u8) = .{};
    defer buf.deinit(allocator);
    try original.serialize(buf.writer(allocator));

    var stream = std.io.fixedBufferStream(buf.items);
    const loaded = try Entry.deserialize(allocator, stream.reader());
    defer loaded.deinit(allocator);

    try std.testing.expectEqual(parent, loaded.parent_hash.?);
    try std.testing.expectEqual(merge_parent, loaded.merge_parent_hash.?);
    try std.testing.expectEqualStrings("Merged", loaded.title);
}

test "roundtrip without parent hash" {
    const allocator = std.testing.allocator;
    const original = Entry{
        .parent_hash = null,
        .path = "Work/Acme-Inc",
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
    try std.testing.expectEqualStrings(original.path, loaded.path);
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
        .path = "Personal",
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
    try std.testing.expectEqualStrings("Personal", loaded.path);
    try std.testing.expectEqualStrings("Updated", loaded.title);
    try std.testing.expectEqualStrings("newpass", loaded.password);
}

test "empty string fields" {
    const allocator = std.testing.allocator;
    const original = Entry{
        .parent_hash = null,
        .path = "",
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

    try std.testing.expectEqualStrings("", loaded.path);
    try std.testing.expectEqualStrings("", loaded.title);
    try std.testing.expectEqualStrings("", loaded.password);
}

test "nested path roundtrip" {
    const allocator = std.testing.allocator;
    const original = Entry{
        .parent_hash = null,
        .path = "Work/Acme-Inc/Engineering",
        .title = "CI Server",
        .description = "",
        .url = "https://ci.acme.example",
        .username = "admin",
        .password = "ci_pass",
        .notes = "",
    };

    var buf: std.ArrayList(u8) = .{};
    defer buf.deinit(allocator);
    try original.serialize(buf.writer(allocator));

    var stream = std.io.fixedBufferStream(buf.items);
    const loaded = try Entry.deserialize(allocator, stream.reader());
    defer loaded.deinit(allocator);

    try std.testing.expectEqualStrings("Work/Acme-Inc/Engineering", loaded.path);
    try std.testing.expectEqualStrings("CI Server", loaded.title);
}
