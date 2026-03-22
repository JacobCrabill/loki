const std = @import("std");
const argon2 = std.crypto.pwhash.argon2;
const cipher = @import("cipher.zig");
const AEAD = std.crypto.aead.chacha_poly.ChaCha20Poly1305;

/// Argon2id parameters stored in the database header.
pub const Params = argon2.Params;

/// Default parameters: OWASP recommendation (t=2, m=19MiB, p=1).
/// Balances security and interactive unlock latency.
pub const default_params: Params = Params.owasp_2id;

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
    /// The AEAD additional data binds magic, params, and salt to this blob,
    /// preventing parameter downgrade attacks.
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

/// AEAD additional data: the non-verify_blob portion of the header (52 bytes).
/// Binding these fields to the verify_blob prevents parameter downgrade attacks.
const ad_size = 8 + 4 + 4 + 4 + 32;

fn buildAd(params: Params, salt: [32]u8) [ad_size]u8 {
    var ad: [ad_size]u8 = undefined;
    @memcpy(ad[0..8], MAGIC);
    std.mem.writeInt(u32, ad[8..12], params.t, .little);
    std.mem.writeInt(u32, ad[12..16], params.m, .little);
    std.mem.writeInt(u32, ad[16..20], @as(u32, params.p), .little);
    @memcpy(ad[20..52], &salt);
    return ad;
}

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

    const ad = buildAd(params, salt);
    var vblob: [verify_blob_len]u8 = undefined;
    var nonce: [AEAD.nonce_length]u8 = undefined;
    std.crypto.random.bytes(&nonce);
    @memcpy(vblob[0..AEAD.nonce_length], &nonce);
    var tag: [AEAD.tag_length]u8 = undefined;
    AEAD.encrypt(vblob[cipher.overhead..], &tag, verify_plaintext, &ad, nonce, key);
    @memcpy(vblob[AEAD.nonce_length..cipher.overhead], &tag);

    return .{ .header = .{ .params = params, .salt = salt, .verify_blob = vblob }, .key = key };
}

/// Attempt to verify `password` against a stored `header`.
/// Returns the derived key on success, or `null` if the password is wrong.
pub fn verifyPassword(
    allocator: std.mem.Allocator,
    password: []const u8,
    header: Header,
) !?[cipher.key_length]u8 {
    const key = try deriveKey(allocator, password, header.salt, header.params);

    const ad = buildAd(header.params, header.salt);
    const vblob = &header.verify_blob;
    var nonce: [AEAD.nonce_length]u8 = undefined;
    @memcpy(&nonce, vblob[0..AEAD.nonce_length]);
    var tag: [AEAD.tag_length]u8 = undefined;
    @memcpy(&tag, vblob[AEAD.nonce_length..cipher.overhead]);
    var pt: [verify_plaintext.len]u8 = undefined;
    AEAD.decrypt(&pt, vblob[cipher.overhead..], tag, &ad, nonce, key) catch |err| {
        if (err == error.AuthenticationFailed) return null;
        return err;
    };
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

/// Minimum and maximum accepted Argon2id parameter values.
/// These guard against DoS via extreme memory/iteration counts in a crafted header.
pub const params_min: Params = .{ .t = 1, .m = 8, .p = 1 };
pub const params_max: Params = .{ .t = 65535, .m = 4 * 1024 * 1024, .p = 255 };

/// Read and parse `dir/header`.
pub fn readHeader(dir: std.fs.Dir) !Header {
    const file = try dir.openFile("header", .{});
    defer file.close();

    var buf: [header_size]u8 = undefined;
    const n = try file.readAll(&buf);
    if (n != header_size) return error.InvalidHeader;

    var r = std.Io.Reader.fixed(&buf);

    var magic: [8]u8 = undefined;
    try r.readSliceAll(&magic);
    if (!std.mem.eql(u8, &magic, MAGIC)) return error.InvalidHeader;

    const t = try r.takeInt(u32, .little);
    const m = try r.takeInt(u32, .little);
    const p: u24 = @intCast(try r.takeInt(u32, .little));

    // Reject parameters outside safe operational bounds before running the KDF.
    // An extremely large `m` would exhaust memory; `t = 0` or `p = 0` violates
    // the Argon2 spec and may cause undefined behaviour in the underlying library.
    if (t < params_min.t or t > params_max.t) return error.InvalidHeader;
    if (m < params_min.m or m > params_max.m) return error.InvalidHeader;
    if (p < params_min.p or p > params_max.p) return error.InvalidHeader;

    var salt: [32]u8 = undefined;
    try r.readSliceAll(&salt);

    var verify_blob: [verify_blob_len]u8 = undefined;
    try r.readSliceAll(&verify_blob);

    return Header{
        .params = .{ .t = t, .m = m, .p = p },
        .salt = salt,
        .verify_blob = verify_blob,
    };
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

/// Fast parameters for unit tests only — never use in production.
const test_params: Params = .{ .t = 1, .m = 8, .p = 1 };

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

test "tampered params fail verification" {
    const allocator = std.testing.allocator;
    const result = try createHeader(allocator, "password", test_params);
    var header = result.header;
    header.params.t += 1; // simulate downgrade/tampering
    const key = try verifyPassword(allocator, "password", header);
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

test "readHeader rejects out-of-bounds params" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    // Build a valid header binary, then patch individual fields to be out of bounds.
    const result = try createHeader(std.testing.allocator, "pw", test_params);
    try writeHeader(result.header, tmp.dir);

    // Helper: read the raw header bytes, patch them, write back, expect InvalidHeader.
    const raw_orig = try tmp.dir.readFileAlloc(std.testing.allocator, "header", 256);
    defer std.testing.allocator.free(raw_orig);

    // t = 0  (bytes 8..12)
    {
        var raw = try std.testing.allocator.dupe(u8, raw_orig);
        defer std.testing.allocator.free(raw);
        std.mem.writeInt(u32, raw[8..12], 0, .little);
        const f = try tmp.dir.createFile("header", .{});
        defer f.close();
        try f.writeAll(raw);
        try std.testing.expectError(error.InvalidHeader, readHeader(tmp.dir));
    }

    // m = 0  (bytes 12..16)
    {
        var raw = try std.testing.allocator.dupe(u8, raw_orig);
        defer std.testing.allocator.free(raw);
        std.mem.writeInt(u32, raw[12..16], 0, .little);
        const f = try tmp.dir.createFile("header", .{});
        defer f.close();
        try f.writeAll(raw);
        try std.testing.expectError(error.InvalidHeader, readHeader(tmp.dir));
    }

    // m = 0xFFFFFFFF  (would allocate ~4 TiB)  (bytes 12..16)
    {
        var raw = try std.testing.allocator.dupe(u8, raw_orig);
        defer std.testing.allocator.free(raw);
        std.mem.writeInt(u32, raw[12..16], 0xFFFFFFFF, .little);
        const f = try tmp.dir.createFile("header", .{});
        defer f.close();
        try f.writeAll(raw);
        try std.testing.expectError(error.InvalidHeader, readHeader(tmp.dir));
    }

    // p = 0  (bytes 16..20)
    {
        var raw = try std.testing.allocator.dupe(u8, raw_orig);
        defer std.testing.allocator.free(raw);
        std.mem.writeInt(u32, raw[16..20], 0, .little);
        const f = try tmp.dir.createFile("header", .{});
        defer f.close();
        try f.writeAll(raw);
        try std.testing.expectError(error.InvalidHeader, readHeader(tmp.dir));
    }
}
