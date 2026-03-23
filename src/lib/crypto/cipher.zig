//! Authenticated Encryption with Associated Data (AEAD)
//!
//! Encryption and Decryption of data using Authenticated Encryption
//! keys created via Key Derivation Functions (KDFs).
//!
//! We use the populer ChaCha20-Poly1305 algorithm.
const std = @import("std");

const AEAD = std.crypto.aead.chacha_poly.ChaCha20Poly1305;

pub const key_length: usize = AEAD.key_length; // 32
pub const nonce_length: usize = AEAD.nonce_length; // 12
pub const tag_length: usize = AEAD.tag_length; // 16

/// Extra bytes added to every encrypted blob: [nonce(12) | tag(16)].
pub const overhead: usize = nonce_length + tag_length; // 28

/// Encrypt `plaintext` with `key`.
///
/// Returns an owned slice of the form `[nonce(12) | tag(16) | ciphertext(N)]`.
/// Caller must free the result.
pub fn encrypt(
    allocator: std.mem.Allocator,
    key: [key_length]u8,
    plaintext: []const u8,
) ![]u8 {
    const blob = try allocator.alloc(u8, overhead + plaintext.len);
    errdefer allocator.free(blob);

    // Pick a random nonce and write it into the first 12 bytes.
    var nonce: [nonce_length]u8 = undefined;
    std.crypto.random.bytes(&nonce);
    @memcpy(blob[0..nonce_length], &nonce);

    // Encrypt in-place into the ciphertext region; receive the auth tag.
    var tag: [tag_length]u8 = undefined;
    AEAD.encrypt(blob[overhead..], &tag, plaintext, "", nonce, key);
    @memcpy(blob[nonce_length..overhead], &tag);

    return blob;
}

/// Decrypt `blob` (produced by `encrypt`) with `key`.
///
/// Returns an owned plaintext slice. Caller must free the result.
/// Returns `error.AuthenticationFailed` if the key is wrong or the blob is
/// tampered with, and `error.InvalidCiphertext` if the blob is too short.
pub fn decrypt(
    allocator: std.mem.Allocator,
    key: [key_length]u8,
    blob: []const u8,
) ![]u8 {
    if (blob.len < overhead) return error.InvalidCiphertext;

    var nonce: [nonce_length]u8 = undefined;
    @memcpy(&nonce, blob[0..nonce_length]);

    var tag: [tag_length]u8 = undefined;
    @memcpy(&tag, blob[nonce_length..overhead]);

    const ciphertext = blob[overhead..];
    const plaintext = try allocator.alloc(u8, ciphertext.len);
    errdefer allocator.free(plaintext);

    try AEAD.decrypt(plaintext, ciphertext, tag, "", nonce, key);
    return plaintext;
}

test "encrypt/decrypt roundtrip" {
    const allocator = std.testing.allocator;
    var key: [key_length]u8 = undefined;
    std.crypto.random.bytes(&key);

    const blob = try encrypt(allocator, key, "hello, cipher!");
    defer allocator.free(blob);

    const pt = try decrypt(allocator, key, blob);
    defer allocator.free(pt);

    try std.testing.expectEqualStrings("hello, cipher!", pt);
}

test "encrypt produces different nonces each call" {
    const allocator = std.testing.allocator;
    var key: [key_length]u8 = undefined;
    std.crypto.random.bytes(&key);

    const b1 = try encrypt(allocator, key, "data");
    defer allocator.free(b1);
    const b2 = try encrypt(allocator, key, "data");
    defer allocator.free(b2);

    // Nonces (first 12 bytes) should differ between calls.
    try std.testing.expect(!std.mem.eql(u8, b1[0..nonce_length], b2[0..nonce_length]));
}

test "decrypt with wrong key returns AuthenticationFailed" {
    const allocator = std.testing.allocator;
    var key: [key_length]u8 = undefined;
    std.crypto.random.bytes(&key);

    const blob = try encrypt(allocator, key, "secret");
    defer allocator.free(blob);

    var bad_key: [key_length]u8 = undefined;
    std.crypto.random.bytes(&bad_key);

    try std.testing.expectError(
        error.AuthenticationFailed,
        decrypt(allocator, bad_key, blob),
    );
}

test "decrypt with truncated blob returns InvalidCiphertext" {
    const allocator = std.testing.allocator;
    var key: [key_length]u8 = undefined;
    std.crypto.random.bytes(&key);

    try std.testing.expectError(
        error.InvalidCiphertext,
        decrypt(allocator, key, "short"),
    );
}

test "encrypt empty plaintext" {
    const allocator = std.testing.allocator;
    var key: [key_length]u8 = undefined;
    std.crypto.random.bytes(&key);

    const blob = try encrypt(allocator, key, "");
    defer allocator.free(blob);
    try std.testing.expectEqual(overhead, blob.len);

    const pt = try decrypt(allocator, key, blob);
    defer allocator.free(pt);
    try std.testing.expectEqualStrings("", pt);
}
