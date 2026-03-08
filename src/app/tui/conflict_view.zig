const std = @import("std");
const zz = @import("zigzag");
const loki = @import("loki");

const Entry = loki.Entry;
const Database = loki.Database;
const ConflictEntry = loki.model.merge.ConflictEntry;

// ---------------------------------------------------------------------------
// Field helpers
// ---------------------------------------------------------------------------

const FIELD_COUNT = 7; // path, title, description, url, username, password, notes
const Fields = enum(u8) { path, title, description, url, username, password, notes };

fn fieldName(f: Fields) []const u8 {
    return switch (f) {
        .path => "Path",
        .title => "Title",
        .description => "Description",
        .url => "URL",
        .username => "Username",
        .password => "Password",
        .notes => "Notes",
    };
}

fn getField(e: Entry, f: Fields) []const u8 {
    return switch (f) {
        .path => e.path,
        .title => e.title,
        .description => e.description,
        .url => e.url,
        .username => e.username,
        .password => e.password,
        .notes => e.notes,
    };
}

// ---------------------------------------------------------------------------
// Per-field choice state
// ---------------------------------------------------------------------------

pub const FieldChoice = enum { local, remote, edited };

const FieldState = struct {
    choice: FieldChoice = .local,
    edited_value: ?[]u8 = null, // owned by ConflictView.allocator

    fn deinit(self: *FieldState, allocator: std.mem.Allocator) void {
        if (self.edited_value) |v| allocator.free(v);
        self.edited_value = null;
    }

    fn setEdited(self: *FieldState, allocator: std.mem.Allocator, value: []const u8) !void {
        if (self.edited_value) |old| allocator.free(old);
        self.edited_value = try allocator.dupe(u8, value);
        self.choice = .edited;
    }
};

// ---------------------------------------------------------------------------
// Public types
// ---------------------------------------------------------------------------

pub const Signal = enum { none, closed, all_resolved };

pub const ConflictView = struct {
    active: bool,
    allocator: std.mem.Allocator,

    // Current conflict being shown.
    current: ConflictEntry,
    local_entry: ?Entry,
    remote_entry: ?Entry,

    // Per-field choices for the current conflict.
    field_choices: [FIELD_COUNT]FieldState,
    field_cursor: u8,
    show_password: bool,

    // Edit mode: one TextArea reused for all fields.
    edit_mode: bool,
    edit_area: zz.TextArea,
    editing_field: u8,

    // Remaining conflicts (including current as first element when active).
    pending: std.ArrayList(ConflictEntry),

    // ---------------------------------------------------------------------------
    // Lifecycle
    // ---------------------------------------------------------------------------

    pub fn init(allocator: std.mem.Allocator) ConflictView {
        return .{
            .active = false,
            .allocator = allocator,
            .current = undefined,
            .local_entry = null,
            .remote_entry = null,
            .field_choices = [_]FieldState{.{}} ** FIELD_COUNT,
            .field_cursor = 0,
            .show_password = false,
            .edit_mode = false,
            .edit_area = zz.TextArea.init(allocator),
            .editing_field = 0,
            .pending = .{},
        };
    }

    pub fn deinit(self: *ConflictView) void {
        self.freeEntries();
        self.freeChoices();
        self.edit_area.deinit();
        self.pending.deinit(self.allocator);
    }

    fn freeEntries(self: *ConflictView) void {
        if (self.local_entry) |e| e.deinit(self.allocator);
        self.local_entry = null;
        if (self.remote_entry) |e| e.deinit(self.allocator);
        self.remote_entry = null;
    }

    fn freeChoices(self: *ConflictView) void {
        for (&self.field_choices) |*fs| fs.deinit(self.allocator);
    }

    // ---------------------------------------------------------------------------
    // Activation
    // ---------------------------------------------------------------------------

    /// Load a slice of conflicts and show the first one.
    /// Takes ownership of `conflicts` (frees with `self.allocator`).
    pub fn load(self: *ConflictView, db: *Database, conflicts: []const ConflictEntry) void {
        self.freeEntries();
        self.freeChoices();
        self.pending.clearRetainingCapacity();
        self.edit_mode = false;
        self.show_password = false;

        if (conflicts.len == 0) {
            self.active = false;
            return;
        }

        // Copy all conflicts into the pending queue.
        self.pending.appendSlice(self.allocator, conflicts) catch {
            self.active = false;
            return;
        };

        self.active = true;
        self.showCurrent(db);
    }

    /// Show the conflict at pending[0].
    fn showCurrent(self: *ConflictView, db: *Database) void {
        if (self.pending.items.len == 0) {
            self.active = false;
            return;
        }
        self.current = self.pending.items[0];
        self.freeEntries();
        self.freeChoices();
        self.field_choices = [_]FieldState{.{}} ** FIELD_COUNT;
        self.field_cursor = 0;
        self.edit_mode = false;

        self.local_entry = db.getVersion(self.current.local_hash) catch null;
        self.remote_entry = db.getVersion(self.current.remote_hash) catch null;

        // Advance cursor to the first differing field.
        self.skipToNextDiff(true);
    }

    /// Advance cursor to the next field where local != remote.
    /// `from_start`: if true, start scanning from field 0.
    fn skipToNextDiff(self: *ConflictView, from_start: bool) void {
        if (from_start) self.field_cursor = 0;
        const start = self.field_cursor;
        var i: u8 = start;
        while (i < FIELD_COUNT) : (i += 1) {
            if (self.fieldDiffers(i)) {
                self.field_cursor = i;
                return;
            }
        }
        // No differing field found; stay where we are (or wrap to 0).
        self.field_cursor = start;
    }

    fn fieldDiffers(self: *const ConflictView, idx: u8) bool {
        const l = self.local_entry orelse return false;
        const r = self.remote_entry orelse return false;
        const f: Fields = @enumFromInt(idx);
        return !std.mem.eql(u8, getField(l, f), getField(r, f));
    }

    // ---------------------------------------------------------------------------
    // Key handling
    // ---------------------------------------------------------------------------

    pub fn handleKey(self: *ConflictView, key: zz.KeyEvent, db: *Database) Signal {
        if (self.edit_mode) return self.editKey(key);
        return self.viewKey(key, db);
    }

    fn viewKey(self: *ConflictView, key: zz.KeyEvent, db: *Database) Signal {
        switch (key.key) {
            .escape => {
                self.edit_mode = false;
                self.active = false;
                return .closed;
            },
            .char => |c| switch (c) {
                'j' => self.moveCursorDown(),
                'k' => self.moveCursorUp(),
                'l', 'L' => self.setChoice(.local),
                'r', 'R' => self.setChoice(.remote),
                'e' => self.enterEditMode(),
                'h' => self.show_password = !self.show_password,
                's' => return self.saveResolution(db),
                'n' => return self.skipConflict(db),
                else => {},
            },
            .down => self.moveCursorDown(),
            .up => self.moveCursorUp(),
            else => {},
        }
        return .none;
    }

    fn editKey(self: *ConflictView, key: zz.KeyEvent) Signal {
        switch (key.key) {
            .escape => {
                // Confirm edit: save TextArea value to field choice.
                const val = self.edit_area.getValue(self.allocator) catch {
                    self.edit_mode = false;
                    return .none;
                };
                defer self.allocator.free(val);
                self.field_choices[self.editing_field].setEdited(self.allocator, val) catch {};
                self.edit_mode = false;
            },
            else => self.edit_area.handleKey(key),
        }
        return .none;
    }

    fn moveCursorDown(self: *ConflictView) void {
        var i = self.field_cursor + 1;
        while (i < FIELD_COUNT) : (i += 1) {
            if (self.fieldDiffers(i)) {
                self.field_cursor = i;
                return;
            }
        }
        // No next differing field; wrap to first differing.
        i = 0;
        while (i <= self.field_cursor) : (i += 1) {
            if (self.fieldDiffers(i)) {
                self.field_cursor = i;
                return;
            }
        }
    }

    fn moveCursorUp(self: *ConflictView) void {
        if (self.field_cursor == 0) return;
        var i = self.field_cursor;
        while (i > 0) {
            i -= 1;
            if (self.fieldDiffers(i)) {
                self.field_cursor = i;
                return;
            }
        }
    }

    fn setChoice(self: *ConflictView, choice: FieldChoice) void {
        if (!self.fieldDiffers(self.field_cursor)) return;
        self.field_choices[self.field_cursor].choice = choice;
        // Clear any previously edited value when switching back to L/R.
        if (self.field_choices[self.field_cursor].edited_value) |v| {
            self.allocator.free(v);
            self.field_choices[self.field_cursor].edited_value = null;
        }
    }

    fn enterEditMode(self: *ConflictView) void {
        if (!self.fieldDiffers(self.field_cursor)) return;
        const l = self.local_entry orelse return;
        const r = self.remote_entry orelse return;
        const f: Fields = @enumFromInt(self.field_cursor);
        const lv = getField(l, f);
        const rv = getField(r, f);

        // Pre-fill TextArea with Git-style conflict markers.
        const marker_text = std.fmt.allocPrint(
            self.allocator,
            "<<<<<<< local\n{s}\n=======\n{s}\n>>>>>>> remote",
            .{ lv, rv },
        ) catch return;
        defer self.allocator.free(marker_text);

        self.edit_area.setValue(marker_text) catch return;
        self.editing_field = self.field_cursor;
        self.edit_mode = true;
    }

    fn saveResolution(self: *ConflictView, db: *Database) Signal {
        const l = self.local_entry orelse return .none;
        const r = self.remote_entry orelse return .none;

        // Ensure the entry still exists in the index before writing.
        if (db.index.find(self.current.entry_id) == null) return .none;

        // Build merged entry.
        const merged = self.buildMergedEntry(l, r) catch return .none;
        defer merged.deinit(self.allocator);

        // Persist: create a new version whose parent = local HEAD,
        // merge_parent = remote HEAD.  This lets the next sync fast-forward remote.
        _ = db.updateEntry(self.current.entry_id, merged) catch return .none;
        db.save() catch {};

        return self.advanceToNext(db);
    }

    fn skipConflict(self: *ConflictView, db: *Database) Signal {
        // Leave current conflict in the file; move to next.
        return self.advanceToNext(db);
    }

    fn advanceToNext(self: *ConflictView, db: *Database) Signal {
        // Remove the front of the queue (current conflict).
        if (self.pending.items.len > 0) {
            _ = self.pending.orderedRemove(0);
        }

        if (self.pending.items.len == 0) {
            // All conflicts resolved (or all skipped but caller tracks which).
            self.freeEntries();
            self.active = false;
            return .all_resolved;
        }

        // Show next conflict.
        self.showCurrent(db);
        return .none;
    }

    fn buildMergedEntry(self: *ConflictView, l: Entry, r: Entry) !Entry {
        const a = self.allocator;

        // Helper to resolve a single field.
        const resolve = struct {
            fn f(
                choices: []const FieldState,
                idx: u8,
                local_val: []const u8,
                remote_val: []const u8,
                alloc: std.mem.Allocator,
            ) ![]u8 {
                return switch (choices[idx].choice) {
                    .local => try alloc.dupe(u8, local_val),
                    .remote => try alloc.dupe(u8, remote_val),
                    .edited => try alloc.dupe(u8, choices[idx].edited_value orelse local_val),
                };
            }
        }.f;

        const path = try resolve(&self.field_choices, @intFromEnum(Fields.path), l.path, r.path, a);
        errdefer a.free(path);
        const title = try resolve(&self.field_choices, @intFromEnum(Fields.title), l.title, r.title, a);
        errdefer a.free(title);
        const description = try resolve(&self.field_choices, @intFromEnum(Fields.description), l.description, r.description, a);
        errdefer a.free(description);
        const url = try resolve(&self.field_choices, @intFromEnum(Fields.url), l.url, r.url, a);
        errdefer a.free(url);
        const username = try resolve(&self.field_choices, @intFromEnum(Fields.username), l.username, r.username, a);
        errdefer a.free(username);
        const password = try resolve(&self.field_choices, @intFromEnum(Fields.password), l.password, r.password, a);
        errdefer a.free(password);
        const notes = try resolve(&self.field_choices, @intFromEnum(Fields.notes), l.notes, r.notes, a);
        errdefer a.free(notes);

        return Entry{
            .parent_hash = self.current.local_hash,
            .merge_parent_hash = self.current.remote_hash,
            .path = path,
            .title = title,
            .description = description,
            .url = url,
            .username = username,
            .password = password,
            .notes = notes,
        };
    }

    // ---------------------------------------------------------------------------
    // Hints
    // ---------------------------------------------------------------------------

    pub fn getHints(self: *const ConflictView) []const u8 {
        if (self.edit_mode) return "Esc: confirm edit";
        return "j/k: nav  L: local  R: remote  e: edit  h: pw  s: save  n: skip  Esc: close";
    }

    // ---------------------------------------------------------------------------
    // Render
    // ---------------------------------------------------------------------------

    /// Render the full conflict resolution view into a box of `width` × `height`.
    pub fn view(
        self: *ConflictView,
        allocator: std.mem.Allocator,
        width: u16,
        height: u16,
    ) ![]const u8 {
        const content_w: u16 = width -| 4; // 2 borders + 1 left-pad + 1 slack
        const content_h: u16 = height -| 2; // top + bottom borders

        var buf: std.Io.Writer.Allocating = .init(allocator);
        defer buf.deinit();
        const w = &buf.writer;

        const l = self.local_entry;
        const r = self.remote_entry;

        // Header row: title of the conflicted entry and progress.
        const title_str: []const u8 = if (l) |le| le.title else "(unknown)";
        const total_pending = self.pending.items.len;
        var hdr_s = zz.Style{};
        hdr_s = hdr_s.bold(true);
        const hdr_text = try std.fmt.allocPrint(
            allocator,
            "Conflict {d}: \"{s}\"",
            .{ total_pending, title_str },
        );
        defer allocator.free(hdr_text);
        try w.writeAll(try hdr_s.render(allocator, hdr_text));
        try w.writeByte('\n');

        // Column layout: fixed label, local value, selector, remote value.
        // Row format uses 23 + 2*half cols; col header uses 24 + 2*half cols.
        // Both must fit in inner_width = content_w, so half = (content_w - 24) / 2.
        const half: u16 = (content_w -| 24) / 2;

        // Column header.
        var col_s = zz.Style{};
        col_s = col_s.bold(true);
        col_s = col_s.dim(true);
        const local_hdr = try padRight(allocator, "LOCAL", half);
        defer allocator.free(local_hdr);
        const remote_hdr = try padRight(allocator, "REMOTE", half);
        defer allocator.free(remote_hdr);
        const col_hdr = try std.fmt.allocPrint(
            allocator,
            "  {s:<12}  {s}  {s:<4}  {s}",
            .{ "Field", local_hdr, "sel", remote_hdr },
        );
        defer allocator.free(col_hdr);
        try w.writeAll(try col_s.render(allocator, col_hdr));
        try w.writeByte('\n');

        // Field rows.
        for (0..FIELD_COUNT) |i| {
            const fi: Fields = @enumFromInt(i);
            const selected = (self.field_cursor == i);
            const differs = self.fieldDiffers(@intCast(i));
            const fs = &self.field_choices[i];

            const local_val: []const u8 = if (l) |le| getField(le, fi) else "";
            const remote_val: []const u8 = if (r) |re| getField(re, fi) else "";

            // Selector badge.
            const badge: []const u8 = if (!differs)
                "[=]"
            else switch (fs.choice) {
                .local => "[L]",
                .remote => "[R]",
                .edited => "[e]",
            };

            // Mask passwords unless show_password is set.
            const is_pw = (fi == .password);
            const lv_display = if (is_pw and !self.show_password)
                try maskStr(allocator, local_val)
            else
                try allocator.dupe(u8, local_val);
            defer allocator.free(lv_display);
            const rv_display = if (is_pw and !self.show_password)
                try maskStr(allocator, remote_val)
            else
                try allocator.dupe(u8, remote_val);
            defer allocator.free(rv_display);

            // Truncate long values to fit the column.
            const lv_trunc = try truncateStr(allocator, firstLine(lv_display), half);
            defer allocator.free(lv_trunc);
            const rv_trunc = try truncateStr(allocator, firstLine(rv_display), half);
            defer allocator.free(rv_trunc);

            // Choose row style.
            var row_s = zz.Style{};
            row_s = row_s.inline_style(true);
            if (selected) {
                row_s = row_s.bold(true);
                row_s = row_s.fg(zz.Color.cyan());
            } else if (!differs) {
                row_s = row_s.dim(true);
            } else {
                row_s = row_s.fg(zz.Color.yellow());
            }

            const cursor_ch: []const u8 = if (selected) "▶" else " ";

            // If this is the field currently being edited, show the TextArea instead.
            if (self.edit_mode and self.editing_field == i) {
                const field_w: u16 = if (content_w > 16) content_w -| 16 else 20;
                self.edit_area.setSize(field_w, 6);
                const area_str = try self.edit_area.view(allocator);
                const prefix = try std.fmt.allocPrint(
                    allocator,
                    "{s} {s:<12}  (editing)\n",
                    .{ cursor_ch, fieldName(fi) },
                );
                defer allocator.free(prefix);
                try w.writeAll(try row_s.render(allocator, prefix));
                try w.writeAll(area_str);
                try w.writeByte('\n');
            } else {
                const lv_padded = try padRight(allocator, lv_trunc, half);
                defer allocator.free(lv_padded);
                const rv_padded = try padRight(allocator, rv_trunc, half);
                defer allocator.free(rv_padded);
                const row_text = try std.fmt.allocPrint(
                    allocator,
                    "{s} {s:<12}  {s}  {s}  {s}",
                    .{ cursor_ch, fieldName(fi), lv_padded, badge, rv_padded },
                );
                defer allocator.free(row_text);
                try w.writeAll(try row_s.render(allocator, row_text));
                try w.writeByte('\n');
            }
        }

        // Box.
        var box_s = zz.Style{};
        box_s = box_s.borderAll(zz.Border.thick);
        box_s = box_s.borderForeground(zz.Color.yellow());
        box_s = box_s.paddingLeft(1);
        box_s = box_s.width(content_w);
        box_s = box_s.height(content_h);
        return box_s.render(allocator, buf.written());
    }
};

// ---------------------------------------------------------------------------
// Render helpers
// ---------------------------------------------------------------------------

fn maskStr(allocator: std.mem.Allocator, s: []const u8) ![]u8 {
    const out = try allocator.alloc(u8, s.len);
    @memset(out, '*');
    return out;
}

fn firstLine(s: []const u8) []const u8 {
    const nl = std.mem.indexOfScalar(u8, s, '\n') orelse return s;
    return s[0..nl];
}

fn truncateStr(allocator: std.mem.Allocator, s: []const u8, max_cols: u16) ![]u8 {
    if (zz.measure.width(s) <= max_cols) return allocator.dupe(u8, s);
    const t = try zz.measure.truncate(allocator, s, max_cols);
    defer allocator.free(t);
    return allocator.dupe(u8, t);
}

/// Left-pad `s` with spaces to exactly `width` visual columns.
/// If `s` is already wider, returns a copy unchanged.
fn padRight(allocator: std.mem.Allocator, s: []const u8, width: u16) ![]u8 {
    const w = zz.measure.width(s);
    if (w >= width) return allocator.dupe(u8, s);
    const pad = @as(usize, width) - w;
    var out = try allocator.alloc(u8, s.len + pad);
    @memcpy(out[0..s.len], s);
    @memset(out[s.len..], ' ');
    return out;
}
