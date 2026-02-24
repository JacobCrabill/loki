const std = @import("std");

/// Compute the SHA-1 hash of the given data.
pub fn hash(data: []const u8) [20]u8 {
    var h = std.crypto.hash.Sha1.init(.{});
    h.update(data);
    var out: [20]u8 = undefined;
    h.final(&out);
    return out;
}

/// Encode a 20-byte hash as a 40-character lowercase hex string.
pub fn hashToHex(h: [20]u8) [40]u8 {
    return std.fmt.bytesToHex(h, .lower);
}

/// Decode a 40-character hex string into a 20-byte hash.
pub fn hexToHash(hex: []const u8) ![20]u8 {
    if (hex.len != 40) return error.InvalidHashLength;
    var out: [20]u8 = undefined;
    _ = try std.fmt.hexToBytes(&out, hex);
    return out;
}

/// Write a blob to `objects_dir` under its SHA-1 hex name.
/// Fails with `error.PathAlreadyExists` if an object with that hash is already present.
/// Returns the SHA-1 hash of the data.
pub fn write(objects_dir: std.fs.Dir, data: []const u8) ![20]u8 {
    const h = hash(data);
    const hex = hashToHex(h);
    const file = try objects_dir.createFile(&hex, .{ .exclusive = true });
    defer file.close();
    try file.writeAll(data);
    return h;
}

/// Write a blob only if an object with that hash does not already exist.
/// Returns the SHA-1 hash of the data.
pub fn writeIfAbsent(objects_dir: std.fs.Dir, data: []const u8) ![20]u8 {
    const h = hash(data);
    const hex = hashToHex(h);
    const file = objects_dir.createFile(&hex, .{ .exclusive = true }) catch |err| {
        if (err == error.PathAlreadyExists) return h;
        return err;
    };
    defer file.close();
    try file.writeAll(data);
    return h;
}

/// Read the blob for the given hash. Caller owns the returned slice.
pub fn read(allocator: std.mem.Allocator, objects_dir: std.fs.Dir, h: [20]u8) ![]u8 {
    const hex = hashToHex(h);
    const file = try objects_dir.openFile(&hex, .{});
    defer file.close();
    return file.readToEndAlloc(allocator, 64 * 1024 * 1024);
}

/// Returns true if an object with the given hash is present in the store.
pub fn exists(objects_dir: std.fs.Dir, h: [20]u8) bool {
    const hex = hashToHex(h);
    const file = objects_dir.openFile(&hex, .{}) catch return false;
    file.close();
    return true;
}

test "hash is deterministic" {
    const h1 = hash("hello");
    const h2 = hash("hello");
    try std.testing.expectEqual(h1, h2);
}

test "different data produces different hashes" {
    const h1 = hash("hello");
    const h2 = hash("world");
    try std.testing.expect(!std.mem.eql(u8, &h1, &h2));
}

test "hashToHex / hexToHash roundtrip" {
    const h = hash("roundtrip test");
    const hex = hashToHex(h);
    const back = try hexToHash(&hex);
    try std.testing.expectEqual(h, back);
}

test "write and read" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const data = "hello, object store";
    const h = try write(tmp.dir, data);
    const loaded = try read(std.testing.allocator, tmp.dir, h);
    defer std.testing.allocator.free(loaded);
    try std.testing.expectEqualStrings(data, loaded);
}

test "write duplicate returns PathAlreadyExists" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    _ = try write(tmp.dir, "some data");
    try std.testing.expectError(error.PathAlreadyExists, write(tmp.dir, "some data"));
}

test "writeIfAbsent is idempotent" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const h1 = try writeIfAbsent(tmp.dir, "idempotent");
    const h2 = try writeIfAbsent(tmp.dir, "idempotent");
    try std.testing.expectEqual(h1, h2);
}

test "exists" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const data = "existence check";
    const h = hash(data);
    try std.testing.expect(!exists(tmp.dir, h));
    _ = try write(tmp.dir, data);
    try std.testing.expect(exists(tmp.dir, h));
}
