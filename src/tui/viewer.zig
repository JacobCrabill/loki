const std = @import("std");
const zz = @import("zigzag");
const Entry = @import("../model/entry.zig").Entry;

// Fields the cursor can move across (indices 0–6).
const FIELD_COUNT = 7;

/// Right pane: read-only view of a single entry.
pub const Viewer = struct {
    /// Currently displayed entry (owned by this Viewer).
    entry: ?Entry,
    /// Allocator that was used when the entry strings were allocated.
    db_allocator: std.mem.Allocator,
    /// Which field is highlighted (0 = title, …, 5 = notes, 6 = parent).
    field_cursor: usize,
    /// Whether to show the password in cleartext.
    show_password: bool,

    pub fn init(db_allocator: std.mem.Allocator) Viewer {
        return .{
            .entry = null,
            .db_allocator = db_allocator,
            .field_cursor = 0,
            .show_password = false,
        };
    }

    pub fn deinit(self: *Viewer) void {
        if (self.entry) |e| e.deinit(self.db_allocator);
    }

    /// Replace the displayed entry (deinits the previous one).
    pub fn setEntry(self: *Viewer, new_entry: ?Entry) void {
        if (self.entry) |old| old.deinit(self.db_allocator);
        self.entry = new_entry;
        self.field_cursor = 0;
        self.show_password = false;
    }

    pub fn handleKey(self: *Viewer, key: zz.KeyEvent) void {
        switch (key.key) {
            .char => |c| switch (c) {
                'j' => self.field_cursor = @min(self.field_cursor + 1, FIELD_COUNT - 1),
                'k' => if (self.field_cursor > 0) {
                    self.field_cursor -= 1;
                },
                'h' => self.show_password = !self.show_password,
                else => {},
            },
            .down => self.field_cursor = @min(self.field_cursor + 1, FIELD_COUNT - 1),
            .up => if (self.field_cursor > 0) {
                self.field_cursor -= 1;
            },
            else => {},
        }
    }

    pub fn view(
        self: *const Viewer,
        allocator: std.mem.Allocator,
        pane_width: u16,
        pane_height: u16,
    ) ![]const u8 {
        var buf: std.ArrayList(u8) = .{};
        defer buf.deinit(allocator);
        const w = buf.writer(allocator);

        if (self.entry) |e| {
            try writeField(w, allocator, "Title", e.title, self.field_cursor == 0, false, false);
            try writeField(w, allocator, "Description", e.description, self.field_cursor == 1, false, false);
            try writeField(w, allocator, "URL", e.url, self.field_cursor == 2, false, false);
            try writeField(w, allocator, "Username", e.username, self.field_cursor == 3, false, false);
            // Password: mask unless show_password
            const pw_value: []const u8 = if (self.show_password) e.password else blk: {
                const m = try allocator.alloc(u8, e.password.len);
                @memset(m, '*');
                break :blk m;
            };
            try writeField(w, allocator, "Password", pw_value, self.field_cursor == 4, false, false);
            try writeField(w, allocator, "Notes", e.notes, self.field_cursor == 5, false, false);

            // Parent hash (italic, dimmed)
            var hex_buf: [40]u8 = undefined;
            const parent_str: []const u8 = if (e.parent_hash) |h| blk: {
                hex_buf = std.fmt.bytesToHex(h, .lower);
                break :blk &hex_buf;
            } else "(genesis)";
            try writeField(w, allocator, "Parent", parent_str, self.field_cursor == 6, true, false);

            // Help bar
            try w.writeByte('\n');
            var hint_s = zz.Style{};
            hint_s = hint_s.dim(true);
            const hints = "j/k: navigate  h: toggle password  Tab: switch pane  q: quit";
            try w.writeAll(try hint_s.render(allocator, hints));
        } else {
            try w.writeAll("No entry selected.\n\n");
            var dim_s = zz.Style{};
            dim_s = dim_s.dim(true);
            try w.writeAll(try dim_s.render(allocator, "Select an entry in the browser pane (Tab to switch)."));
        }

        var box_s = zz.Style{};
        box_s = box_s.borderAll(zz.Border.rounded);
        box_s = box_s.paddingLeft(1);
        box_s = box_s.width(pane_width);
        box_s = box_s.height(pane_height);
        return box_s.render(allocator, buf.items);
    }
};

fn writeField(
    w: anytype,
    allocator: std.mem.Allocator,
    name: []const u8,
    value: []const u8,
    selected: bool,
    italic: bool,
    _: bool, // reserved
) !void {
    var label_s = zz.Style{};
    var val_s = zz.Style{};
    if (selected) {
        label_s = label_s.bold(true);
        label_s = label_s.fg(zz.Color.magenta());
        val_s = val_s.fg(zz.Color.cyan());
    }
    if (italic) {
        val_s = val_s.italic(true);
        val_s = val_s.dim(true);
    }
    const label = try std.fmt.allocPrint(allocator, "{s}: ", .{name});
    try w.writeAll(try label_s.render(allocator, label));
    try w.writeAll(try val_s.render(allocator, value));
    try w.writeByte('\n');
}
