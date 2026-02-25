const std = @import("std");
const zz = @import("zigzag");
const Entry = @import("../model/entry.zig").Entry;
const Database = @import("../store/database.zig").Database;

/// A single entry in the history list.
const HistoryItem = struct {
    hash: [20]u8,
    /// Short hex label shown in the list.
    label: [12]u8,
};

pub const Signal = enum { none, restored, closed };

/// Overlay widget: shows the version history of one entry.
/// Caller is responsible for deiniting items with the same allocator.
pub const HistoryView = struct {
    active: bool,
    allocator: std.mem.Allocator,
    entry_id: [20]u8,
    items: std.ArrayList(HistoryItem) = .{},
    cursor: usize,
    /// Loaded preview of the selected version (null if none loaded or error).
    preview: ?Entry,

    pub fn init(allocator: std.mem.Allocator) HistoryView {
        return .{
            .active = false,
            .allocator = allocator,
            .entry_id = undefined,
            .cursor = 0,
            .preview = null,
        };
    }

    pub fn deinit(self: *HistoryView) void {
        if (self.preview) |p| p.deinit(self.allocator);
        self.items.deinit(self.allocator);
    }

    /// Load history for `entry_id` starting from `head_hash`.
    pub fn show(self: *HistoryView, db: *Database, entry_id: [20]u8, head_hash: [20]u8) !void {
        // Clear previous state.
        if (self.preview) |p| p.deinit(self.allocator);
        self.preview = null;
        self.items.clearRetainingCapacity();
        self.cursor = 0;
        self.entry_id = entry_id;
        self.active = true;

        // Walk the parent_hash chain (up to 200 versions).
        var current_hash: [20]u8 = head_hash;
        var count: usize = 0;
        while (count < 200) : (count += 1) {
            const full_hex = std.fmt.bytesToHex(current_hash, .lower);
            var label: [12]u8 = undefined;
            @memcpy(&label, full_hex[0..12]);

            try self.items.append(self.allocator, .{
                .hash = current_hash,
                .label = label,
            });

            // Load the version to follow its parent_hash.
            const version = db.getVersion(current_hash) catch break;
            const parent = version.parent_hash;
            version.deinit(self.allocator);
            if (parent) |ph| {
                current_hash = ph;
            } else {
                break; // reached genesis
            }
        }

        // Load preview for the first item (HEAD).
        if (self.items.items.len > 0) {
            self.loadPreview(db);
        }
    }

    pub fn hide(self: *HistoryView) void {
        self.active = false;
    }

    fn loadPreview(self: *HistoryView, db: *Database) void {
        if (self.preview) |p| p.deinit(self.allocator);
        self.preview = null;
        if (self.cursor >= self.items.items.len) return;
        const h = self.items.items[self.cursor].hash;
        self.preview = db.getVersion(h) catch null;
    }

    pub fn handleKey(self: *HistoryView, key: zz.KeyEvent, db: *Database) Signal {
        switch (key.key) {
            .escape => {
                self.hide();
                return .closed;
            },
            .char => |c| switch (c) {
                'j' => {
                    if (self.cursor + 1 < self.items.items.len) {
                        self.cursor += 1;
                        self.loadPreview(db);
                    }
                },
                'k' => {
                    if (self.cursor > 0) {
                        self.cursor -= 1;
                        self.loadPreview(db);
                    }
                },
                'r' => {
                    // Restore: update the entry's HEAD to point to the selected version's hash,
                    // reusing the selected version's content but with parent = current HEAD.
                    return self.restore(db);
                },
                else => {},
            },
            .down => {
                if (self.cursor + 1 < self.items.items.len) {
                    self.cursor += 1;
                    self.loadPreview(db);
                }
            },
            .up => {
                if (self.cursor > 0) {
                    self.cursor -= 1;
                    self.loadPreview(db);
                }
            },
            else => {},
        }
        return .none;
    }

    fn restore(self: *HistoryView, db: *Database) Signal {
        const selected_hash = self.items.items[self.cursor].hash;
        // Get the current HEAD hash (first item = HEAD).
        const head_hash = self.items.items[0].hash;
        if (std.mem.eql(u8, &selected_hash, &head_hash)) return .none; // already at HEAD

        // Load the selected version's content.
        const old_version = db.getVersion(selected_hash) catch return .none;
        defer old_version.deinit(self.allocator);

        // Build a new entry that is a copy of the old content, with parent = current HEAD.
        var restored = Entry{
            .parent_hash = head_hash,
            .path = self.allocator.dupe(u8, old_version.path) catch return .none,
            .title = self.allocator.dupe(u8, old_version.title) catch return .none,
            .description = self.allocator.dupe(u8, old_version.description) catch return .none,
            .url = self.allocator.dupe(u8, old_version.url) catch return .none,
            .username = self.allocator.dupe(u8, old_version.username) catch return .none,
            .password = self.allocator.dupe(u8, old_version.password) catch return .none,
            .notes = self.allocator.dupe(u8, old_version.notes) catch return .none,
        };
        defer restored.deinit(self.allocator);

        _ = db.updateEntry(self.entry_id, restored) catch return .none;
        db.save() catch {};
        self.hide();
        return .restored;
    }

    pub fn view(self: *const HistoryView, allocator: std.mem.Allocator) ![]const u8 {
        var buf: std.ArrayList(u8) = .{};
        defer buf.deinit(allocator);
        const w = buf.writer(allocator);

        var title_s = zz.Style{};
        title_s = title_s.bold(true);
        try w.writeAll(try title_s.render(allocator, "Version History"));
        try w.writeAll("\n\n");

        // List of versions.
        if (self.items.items.len == 0) {
            try w.writeAll("No history found.\n");
        } else {
            for (self.items.items, 0..) |item, i| {
                const selected = i == self.cursor;
                var s = zz.Style{};
                if (selected) { s = s.bold(true); s = s.fg(zz.Color.cyan()); }
                const prefix: []const u8 = if (i == 0) " HEAD" else if (selected) "     " else "     ";
                const line = try std.fmt.allocPrint(allocator, "{s}{s}  {s}", .{
                    if (selected) ">" else " ",
                    prefix,
                    &item.label,
                });
                try w.writeAll(try s.render(allocator, line));
                try w.writeByte('\n');
            }
        }

        // Preview of selected version.
        if (self.preview) |p| {
            try w.writeByte('\n');
            var sep_s = zz.Style{};
            sep_s = sep_s.dim(true);
            try w.writeAll(try sep_s.render(allocator, "─── Preview ───────────────────"));
            try w.writeByte('\n');
            try w.writeAll(try std.fmt.allocPrint(allocator, "Title:    {s}\n", .{p.title}));
            try w.writeAll(try std.fmt.allocPrint(allocator, "Username: {s}\n", .{p.username}));
            try w.writeAll(try std.fmt.allocPrint(allocator, "URL:      {s}\n", .{p.url}));
        }

        // Help bar.
        try w.writeByte('\n');
        var hint_s = zz.Style{};
        hint_s = hint_s.dim(true);
        try w.writeAll(try hint_s.render(allocator, "j/k: navigate  r: restore this version  Esc: close"));

        var box_s = zz.Style{};
        box_s = box_s.borderAll(zz.Border.rounded);
        box_s = box_s.paddingAll(1);
        return box_s.render(allocator, buf.items);
    }
};
