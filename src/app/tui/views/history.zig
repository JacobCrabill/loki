const std = @import("std");
const zz = @import("zigzag");
const loki = @import("loki");

const Entry = loki.Entry;
const Database = loki.Database;

/// A single entry in the history list.
const HistoryItem = struct {
    hash: [20]u8,
    /// Short hex label shown in the list.
    label: [12]u8,
};

pub const Signal = enum { none, restored, closed };

/// Left-pane widget: shows the version history of one entry.
/// Caller is responsible for deiniting with the same allocator.
pub const HistoryView = struct {
    active: bool,
    allocator: std.mem.Allocator,
    entry_id: [20]u8,
    items: std.ArrayList(HistoryItem) = .{},
    cursor: usize,
    scroll: usize,
    /// Loaded preview of the selected version (null if none loaded or error).
    preview: ?Entry,

    pub fn init(allocator: std.mem.Allocator) HistoryView {
        return .{
            .active = false,
            .allocator = allocator,
            .entry_id = undefined,
            .cursor = 0,
            .scroll = 0,
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
        self.scroll = 0;
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

    /// Deactivate history mode, freeing the loaded preview.
    pub fn hide(self: *HistoryView) void {
        if (self.preview) |p| p.deinit(self.allocator);
        self.preview = null;
        self.active = false;
    }

    /// Take ownership of the current preview, leaving self.preview null.
    /// Returns null if no preview is loaded (e.g. no items or after hide).
    pub fn takePreview(self: *HistoryView) ?Entry {
        const p = self.preview;
        self.preview = null;
        return p;
    }

    /// The hash at the current cursor position, or null if items is empty.
    pub fn selectedHash(self: *const HistoryView) ?[20]u8 {
        if (self.cursor >= self.items.items.len) return null;
        return self.items.items[self.cursor].hash;
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
                'r' => return self.restore(db),
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

    pub fn getHints(self: *const HistoryView) []const u8 {
        _ = self;
        return "j/k: nav  r: restore  Esc: close";
    }

    /// Render the history pane into a styled box of `pane_width` × `pane_height`.
    pub fn view(
        self: *HistoryView,
        allocator: std.mem.Allocator,
        pane_width: u16,
        pane_height: u16,
        focused: bool,
    ) ![]const u8 {
        const content_w: u16 = pane_width -| 3; // 1 left-pad + 2 borders
        const content_h: u16 = pane_height -| 2; // top + bottom borders
        // Title consumes 1 line.
        const visible: usize = if (content_h > 1) @as(usize, content_h) - 1 else 1;

        // Scroll to keep cursor in view.
        if (self.cursor < self.scroll) {
            self.scroll = self.cursor;
        } else if (self.items.items.len > 0 and self.cursor >= self.scroll + visible) {
            self.scroll = self.cursor - visible + 1;
        }

        var buf: std.Io.Writer.Allocating = .init(allocator);
        defer buf.deinit();
        const w = &buf.writer;

        if (self.items.items.len == 0) {
            try w.writeAll("No history.");
        } else {
            const end = @min(self.scroll + visible, self.items.items.len);
            for (self.scroll..end) |i| {
                if (i > self.scroll) try w.writeByte('\n');
                const item = self.items.items[i];
                const selected = i == self.cursor;

                var s = zz.Style{};
                s = s.inline_style(true);
                if (selected) {
                    s = s.bold(true);
                    s = s.fg(zz.Color.cyan());
                }

                const label = try std.fmt.allocPrint(
                    allocator,
                    "{s}  {s}",
                    .{ if (i == 0) "HEAD" else "    ", &item.label },
                );
                try w.writeAll(try s.render(allocator, label));
            }
        }

        // Prepend the styled title row.
        var title_s = zz.Style{};
        title_s = title_s.bold(true);
        title_s = title_s.inline_style(true);
        const title_line = try title_s.render(allocator, "History");
        const content = try std.fmt.allocPrint(allocator, "{s}\n{s}", .{ title_line, buf.written() });

        // Pad content to exactly content_h rows so the bottom border always
        // reaches the bottom of the pane.  zz.Style.height() is silently
        // ignored by the renderer, so we pad the content directly instead.
        const content_padded = try zz.placeVertical(allocator, content_h, .top, content);

        var box_s = zz.Style{};
        if (focused) {
            box_s = box_s.borderAll(zz.Border.double).borderForeground(zz.Color.cyan());
        } else {
            box_s = box_s.borderAll(zz.Border.rounded);
        }
        box_s = box_s.paddingLeft(1);
        box_s = box_s.width(content_w);
        return box_s.render(allocator, content_padded);
    }
};
