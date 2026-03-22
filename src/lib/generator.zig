const std = @import("std");

pub const CHAR_UPPER = "ABCDEFGHIJKLMNOPQRSTUVWXYZ";
pub const CHAR_LOWER = "abcdefghijklmnopqrstuvwxyz";
pub const CHAR_DIGITS = "0123456789";
pub const CHAR_SYMBOLS = "!@#$%^&*()-_=+[]{}|;:',.<>?/`~";

pub const MIN_LENGTH: u8 = 8;
pub const MAX_LENGTH: u8 = 128;
pub const DEFAULT_LENGTH: u8 = 20;

/// Options controlling which character sets are included in generated passwords.
pub const Options = struct {
    length: u8 = DEFAULT_LENGTH,
    use_upper: bool = true,
    use_lower: bool = true,
    use_digits: bool = true,
    use_symbols: bool = false,
};

/// Generate a password into `buf` according to `opts`.
/// Returns the slice of `buf` that was filled (length is `@min(opts.length, buf.len)`).
pub fn generate(opts: Options, buf: []u8) []const u8 {
    // Build character pool.
    var pool: [CHAR_UPPER.len + CHAR_LOWER.len + CHAR_DIGITS.len + CHAR_SYMBOLS.len]u8 = undefined;
    var pool_len: usize = 0;
    if (opts.use_upper) {
        @memcpy(pool[pool_len..][0..CHAR_UPPER.len], CHAR_UPPER);
        pool_len += CHAR_UPPER.len;
    }
    if (opts.use_lower) {
        @memcpy(pool[pool_len..][0..CHAR_LOWER.len], CHAR_LOWER);
        pool_len += CHAR_LOWER.len;
    }
    if (opts.use_digits) {
        @memcpy(pool[pool_len..][0..CHAR_DIGITS.len], CHAR_DIGITS);
        pool_len += CHAR_DIGITS.len;
    }
    if (opts.use_symbols) {
        @memcpy(pool[pool_len..][0..CHAR_SYMBOLS.len], CHAR_SYMBOLS);
        pool_len += CHAR_SYMBOLS.len;
    }

    if (pool_len == 0) {
        // Fallback: at least lowercase letters.
        @memcpy(pool[0..CHAR_LOWER.len], CHAR_LOWER);
        pool_len = CHAR_LOWER.len;
    }

    const len = @min(@as(usize, opts.length), buf.len);
    var rng = std.Random.DefaultPrng.init(blk: {
        var seed: u64 = undefined;
        std.posix.getrandom(std.mem.asBytes(&seed)) catch {
            seed = @intCast(std.time.milliTimestamp());
        };
        break :blk seed;
    });
    const rand = rng.random();
    for (0..len) |i| {
        buf[i] = pool[rand.uintLessThan(usize, pool_len)];
    }
    return buf[0..len];
}

test "generate produces correct length" {
    var buf: [MAX_LENGTH]u8 = undefined;
    const opts = Options{ .length = 32 };
    const pw = generate(opts, &buf);
    try std.testing.expectEqual(@as(usize, 32), pw.len);
}

test "generate respects buffer size limit" {
    var buf: [10]u8 = undefined;
    const opts = Options{ .length = 50 };
    const pw = generate(opts, &buf);
    try std.testing.expectEqual(@as(usize, 10), pw.len);
}

test "generate with no charsets falls back to lowercase" {
    var buf: [MAX_LENGTH]u8 = undefined;
    const opts = Options{
        .length = 20,
        .use_upper = false,
        .use_lower = false,
        .use_digits = false,
        .use_symbols = false,
    };
    const pw = generate(opts, &buf);
    try std.testing.expectEqual(@as(usize, 20), pw.len);
    // All characters should be lowercase letters.
    for (pw) |c| {
        try std.testing.expect(c >= 'a' and c <= 'z');
    }
}
