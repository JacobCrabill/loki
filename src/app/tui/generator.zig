const std = @import("std");
const zz = @import("zigzag");

const CHAR_UPPER = "ABCDEFGHIJKLMNOPQRSTUVWXYZ";
const CHAR_LOWER = "abcdefghijklmnopqrstuvwxyz";
const CHAR_DIGITS = "0123456789";
const CHAR_SYMBOLS = "!@#$%^&*()-_=+[]{}|;:',.<>?/`~";

const MIN_LENGTH: u8 = 8;
const MAX_LENGTH: u8 = 128;
const DEFAULT_LENGTH: u8 = 20;

/// Which option row the cursor is on in the generator dialog.
const Row = enum { length, upper, lower, digits, symbols, preview, accept };
const ROW_COUNT = 7;

pub const Generator = struct {
    active: bool,
    length: u8,
    use_upper: bool,
    use_lower: bool,
    use_digits: bool,
    use_symbols: bool,
    preview: [MAX_LENGTH]u8,
    preview_len: usize,
    cursor_row: usize,
    /// Set to true when the user accepts. Caller reads the generated password via getPassword().
    accepted: bool,

    pub fn init() Generator {
        var g = Generator{
            .active = false,
            .length = DEFAULT_LENGTH,
            .use_upper = true,
            .use_lower = true,
            .use_digits = true,
            .use_symbols = false,
            .preview = undefined,
            .preview_len = 0,
            .cursor_row = @intFromEnum(Row.preview),
            .accepted = false,
        };
        g.regenerate();
        return g;
    }

    pub fn show(self: *Generator) void {
        self.active = true;
        self.accepted = false;
        self.regenerate();
    }

    pub fn hide(self: *Generator) void {
        self.active = false;
    }

    /// The currently generated password (valid until next regenerate() call).
    pub fn getPassword(self: *const Generator) []const u8 {
        return self.preview[0..self.preview_len];
    }

    pub fn regenerate(self: *Generator) void {
        // Build character pool.
        var pool: [256]u8 = undefined;
        var pool_len: usize = 0;
        if (self.use_upper) {
            @memcpy(pool[pool_len..][0..CHAR_UPPER.len], CHAR_UPPER);
            pool_len += CHAR_UPPER.len;
        }
        if (self.use_lower) {
            @memcpy(pool[pool_len..][0..CHAR_LOWER.len], CHAR_LOWER);
            pool_len += CHAR_LOWER.len;
        }
        if (self.use_digits) {
            @memcpy(pool[pool_len..][0..CHAR_DIGITS.len], CHAR_DIGITS);
            pool_len += CHAR_DIGITS.len;
        }
        if (self.use_symbols) {
            @memcpy(pool[pool_len..][0..CHAR_SYMBOLS.len], CHAR_SYMBOLS);
            pool_len += CHAR_SYMBOLS.len;
        }

        if (pool_len == 0) {
            // Fallback: at least lowercase letters.
            @memcpy(pool[0..CHAR_LOWER.len], CHAR_LOWER);
            pool_len = CHAR_LOWER.len;
        }

        const len = @min(@as(usize, self.length), MAX_LENGTH);
        var rng = std.Random.DefaultPrng.init(blk: {
            var seed: u64 = undefined;
            std.posix.getrandom(std.mem.asBytes(&seed)) catch {
                seed = @intCast(std.time.milliTimestamp());
            };
            break :blk seed;
        });
        const rand = rng.random();
        for (0..len) |i| {
            self.preview[i] = pool[rand.uintLessThan(usize, pool_len)];
        }
        self.preview_len = len;
    }

    pub fn handleKey(self: *Generator, key: zz.KeyEvent) void {
        switch (key.key) {
            .escape => self.hide(),
            .enter => {
                if (self.cursor_row == @intFromEnum(Row.accept)) {
                    self.accepted = true;
                    self.active = false;
                } else if (self.cursor_row == @intFromEnum(Row.preview)) {
                    self.regenerate();
                } else {
                    self.toggleOrAdjust();
                }
            },
            .char => |c| switch (c) {
                'j' => self.cursor_row = @min(self.cursor_row + 1, ROW_COUNT - 1),
                'k' => if (self.cursor_row > 0) {
                    self.cursor_row -= 1;
                },
                // +/- to adjust length when on the length row.
                '+', '=' => if (self.cursor_row == @intFromEnum(Row.length)) {
                    if (self.length < MAX_LENGTH) {
                        self.length += 1;
                        self.regenerate();
                    }
                },
                '-' => if (self.cursor_row == @intFromEnum(Row.length)) {
                    if (self.length > MIN_LENGTH) {
                        self.length -= 1;
                        self.regenerate();
                    }
                },
                ' ' => self.toggleOrAdjust(),
                'r' => self.regenerate(),
                else => {},
            },
            .down => self.cursor_row = @min(self.cursor_row + 1, ROW_COUNT - 1),
            .up => if (self.cursor_row > 0) {
                self.cursor_row -= 1;
            },
            .right => if (self.cursor_row == @intFromEnum(Row.length)) {
                if (self.length < MAX_LENGTH) {
                    self.length += 1;
                    self.regenerate();
                }
            },
            .left => if (self.cursor_row == @intFromEnum(Row.length)) {
                if (self.length > MIN_LENGTH) {
                    self.length -= 1;
                    self.regenerate();
                }
            },
            else => {},
        }
    }

    fn toggleOrAdjust(self: *Generator) void {
        switch (@as(Row, @enumFromInt(self.cursor_row))) {
            .upper => { self.use_upper = !self.use_upper; self.regenerate(); },
            .lower => { self.use_lower = !self.use_lower; self.regenerate(); },
            .digits => { self.use_digits = !self.use_digits; self.regenerate(); },
            .symbols => { self.use_symbols = !self.use_symbols; self.regenerate(); },
            .preview => self.regenerate(),
            else => {},
        }
    }

    pub fn getHints(self: *const Generator) []const u8 {
        _ = self;
        return "j/k: nav  Space/Enter: toggle  r: regen  Esc: cancel";
    }

    pub fn view(self: *const Generator, allocator: std.mem.Allocator) ![]const u8 {
        var buf: std.ArrayList(u8) = .{};
        defer buf.deinit(allocator);
        const w = buf.writer(allocator);

        var title_s = zz.Style{};
        title_s = title_s.bold(true);
        try w.writeAll(try title_s.render(allocator, "Generate Password"));
        try w.writeAll("\n\n");

        try writeRow(w, allocator, self.cursor_row == @intFromEnum(Row.length),
            try std.fmt.allocPrint(allocator, "Length: {d}  (←/→ or -/+ to adjust)", .{self.length}));
        try writeCheckRow(w, allocator, self.cursor_row == @intFromEnum(Row.upper), self.use_upper, "Uppercase (A-Z)");
        try writeCheckRow(w, allocator, self.cursor_row == @intFromEnum(Row.lower), self.use_lower, "Lowercase (a-z)");
        try writeCheckRow(w, allocator, self.cursor_row == @intFromEnum(Row.digits), self.use_digits, "Digits (0-9)");
        try writeCheckRow(w, allocator, self.cursor_row == @intFromEnum(Row.symbols), self.use_symbols, "Symbols (!@#…)");

        try w.writeByte('\n');

        // Preview row.
        const pw_sel = self.cursor_row == @intFromEnum(Row.preview);
        var pw_label_s = zz.Style{};
        if (pw_sel) { pw_label_s = pw_label_s.bold(true); pw_label_s = pw_label_s.fg(zz.Color.magenta()); }
        try w.writeAll(try pw_label_s.render(allocator, if (pw_sel) "> Preview:  " else "  Preview:  "));
        var pw_val_s = zz.Style{};
        pw_val_s = pw_val_s.fg(zz.Color.cyan());
        try w.writeAll(try pw_val_s.render(allocator, self.getPassword()));
        try w.writeByte('\n');

        // Accept row.
        try w.writeByte('\n');
        const accept_sel = self.cursor_row == @intFromEnum(Row.accept);
        var accept_s = zz.Style{};
        if (accept_sel) { accept_s = accept_s.bold(true); accept_s = accept_s.fg(zz.Color.green()); }
        try w.writeAll(try accept_s.render(allocator, if (accept_sel) "> [ Use this password ]" else "  [ Use this password ]"));
        try w.writeByte('\n');

        var box_s = zz.Style{};
        box_s = box_s.borderAll(zz.Border.rounded);
        box_s = box_s.paddingAll(1);
        return box_s.render(allocator, buf.items);
    }
};

fn writeRow(w: anytype, allocator: std.mem.Allocator, selected: bool, text: []const u8) !void {
    var s = zz.Style{};
    if (selected) { s = s.bold(true); s = s.fg(zz.Color.magenta()); }
    const prefix: []const u8 = if (selected) "> " else "  ";
    try w.writeAll(try s.render(allocator, try std.fmt.allocPrint(allocator, "{s}{s}", .{ prefix, text })));
    try w.writeByte('\n');
}

fn writeCheckRow(w: anytype, allocator: std.mem.Allocator, selected: bool, checked: bool, label: []const u8) !void {
    var s = zz.Style{};
    if (selected) { s = s.bold(true); s = s.fg(zz.Color.magenta()); }
    const prefix: []const u8 = if (selected) "> " else "  ";
    const check: []const u8 = if (checked) "[x] " else "[ ] ";
    try w.writeAll(try s.render(allocator, try std.fmt.allocPrint(allocator, "{s}{s}{s}", .{ prefix, check, label })));
    try w.writeByte('\n');
}
