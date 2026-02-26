const std = @import("std");
const argon2 = std.crypto.pwhash.argon2;
const cipher = @import("cipher.zig");

/// Argon2id parameters stored in the database header.
pub const Params = argon2.Params;

/// Default parameters: OWASP recommendation (t=2, m=19MiB, p=1).
/// Balances security and interactive unlock latency.
pub const default_params: Params = Params.owasp_2id;

/// Fast parameters for unit tests only — never use in production.
pub const test_params: Params = .{ .t = 1, .m = 8, .p = 1 };

/// Known plaintext used to verify the derived key. Must be exactly 16 bytes.
const verify_plaintext = "LOKI_HDR_VERIFY!";
comptime {
    std.debug.assert(verify_plaintext.len == 16);
}

const verify_blob_len = cipher.overhead + verify_plaintext.len; // 28 + 16 = 44

/// Contents of the `header` file written at database creation time.
pub const Header = struct {
    params: Params,
    salt: [32]u8,
    /// Encrypted blob of `verify_plaintext`: [nonce(12) | tag(16) | ct(16)].
    verify_blob: [verify_blob_len]u8,
};

/// Binary header layout (96 bytes total):
///   8  bytes  magic
///   4  bytes  argon2 t (u32 LE)
///   4  bytes  argon2 m (u32 LE)
///   4  bytes  argon2 p (u32 LE, value fits in u24)
///  32  bytes  salt
///  44  bytes  verify_blob
const MAGIC = "LOKIDB\x00\x01";
const header_size = 8 + 4 + 4 + 4 + 32 + verify_blob_len; // 96

/// Derive a 32-byte encryption key from `password` using Argon2id.
pub fn deriveKey(
    allocator: std.mem.Allocator,
    password: []const u8,
    salt: [32]u8,
    params: Params,
) ![cipher.key_length]u8 {
    var key: [cipher.key_length]u8 = undefined;
    try argon2.kdf(allocator, &key, password, &salt, params, .argon2id);
    return key;
}

/// Generate a fresh header and derive the encryption key.
/// The salt is randomly generated; params control KDF hardness.
pub fn createHeader(
    allocator: std.mem.Allocator,
    password: []const u8,
    params: Params,
) !struct { header: Header, key: [cipher.key_length]u8 } {
    var salt: [32]u8 = undefined;
    std.crypto.random.bytes(&salt);

    const key = try deriveKey(allocator, password, salt, params);

    const vblob = try cipher.encrypt(allocator, key, verify_plaintext);
    defer allocator.free(vblob);

    var header = Header{
        .params = params,
        .salt = salt,
        .verify_blob = undefined,
    };
    @memcpy(&header.verify_blob, vblob);

    return .{ .header = header, .key = key };
}

/// Attempt to verify `password` against a stored `header`.
/// Returns the derived key on success, or `null` if the password is wrong.
pub fn verifyPassword(
    allocator: std.mem.Allocator,
    password: []const u8,
    header: Header,
) !?[cipher.key_length]u8 {
    const key = try deriveKey(allocator, password, header.salt, header.params);

    const pt = cipher.decrypt(allocator, key, &header.verify_blob) catch |err| {
        if (err == error.AuthenticationFailed) return null;
        return err;
    };
    defer allocator.free(pt);

    if (!std.mem.eql(u8, pt, verify_plaintext)) return null;
    return key;
}

/// Write `header` to `dir/header`.
pub fn writeHeader(header: Header, dir: std.fs.Dir) !void {
    var buf: [header_size]u8 = undefined;
    var stream = std.io.fixedBufferStream(&buf);
    const w = stream.writer();

    try w.writeAll(MAGIC);
    try w.writeInt(u32, header.params.t, .little);
    try w.writeInt(u32, header.params.m, .little);
    try w.writeInt(u32, @as(u32, header.params.p), .little);
    try w.writeAll(&header.salt);
    try w.writeAll(&header.verify_blob);

    const file = try dir.createFile("header", .{});
    defer file.close();
    try file.writeAll(&buf);
}

/// Read and parse `dir/header`.
pub fn readHeader(dir: std.fs.Dir) !Header {
    const file = try dir.openFile("header", .{});
    defer file.close();

    var buf: [header_size]u8 = undefined;
    const n = try file.readAll(&buf);
    if (n != header_size) return error.InvalidHeader;

    var stream = std.io.fixedBufferStream(&buf);
    const r = stream.reader();

    var magic: [8]u8 = undefined;
    try r.readNoEof(&magic);
    if (!std.mem.eql(u8, &magic, MAGIC)) return error.InvalidHeader;

    const t = try r.readInt(u32, .little);
    const m = try r.readInt(u32, .little);
    const p: u24 = @intCast(try r.readInt(u32, .little));

    var salt: [32]u8 = undefined;
    try r.readNoEof(&salt);

    var verify_blob: [verify_blob_len]u8 = undefined;
    try r.readNoEof(&verify_blob);

    return Header{
        .params = .{ .t = t, .m = m, .p = p },
        .salt = salt,
        .verify_blob = verify_blob,
    };
}

test "derive key is deterministic" {
    const allocator = std.testing.allocator;
    var salt: [32]u8 = undefined;
    @memset(&salt, 0x42);

    const k1 = try deriveKey(allocator, "password", salt, test_params);
    const k2 = try deriveKey(allocator, "password", salt, test_params);
    try std.testing.expectEqual(k1, k2);
}

test "different passwords produce different keys" {
    const allocator = std.testing.allocator;
    var salt: [32]u8 = undefined;
    @memset(&salt, 0x42);

    const k1 = try deriveKey(allocator, "password", salt, test_params);
    const k2 = try deriveKey(allocator, "passw0rd", salt, test_params);
    try std.testing.expect(!std.mem.eql(u8, &k1, &k2));
}

test "createHeader and verifyPassword roundtrip" {
    const allocator = std.testing.allocator;
    const result = try createHeader(allocator, "hunter2", test_params);
    const key = (try verifyPassword(allocator, "hunter2", result.header)).?;
    try std.testing.expectEqual(result.key, key);
}

test "verifyPassword returns null for wrong password" {
    const allocator = std.testing.allocator;
    const result = try createHeader(allocator, "correct", test_params);
    const key = try verifyPassword(allocator, "incorrect", result.header);
    try std.testing.expect(key == null);
}

test "writeHeader and readHeader roundtrip" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const result = try createHeader(allocator, "roundtrip", test_params);
    try writeHeader(result.header, tmp.dir);

    const loaded = try readHeader(tmp.dir);
    try std.testing.expectEqual(result.header.params.t, loaded.params.t);
    try std.testing.expectEqual(result.header.params.m, loaded.params.m);
    try std.testing.expectEqual(result.header.params.p, loaded.params.p);
    try std.testing.expectEqual(result.header.salt, loaded.salt);
    try std.testing.expectEqual(result.header.verify_blob, loaded.verify_blob);

    // Key must still verify after a header roundtrip.
    const key = (try verifyPassword(allocator, "roundtrip", loaded)).?;
    try std.testing.expectEqual(result.key, key);
}
