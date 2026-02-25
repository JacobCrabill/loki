const std = @import("std");
const zz = @import("zigzag");
const Entry = @import("../model/entry.zig").Entry;
const Generator = @import("generator.zig").Generator;
const HistoryView = @import("history_view.zig").HistoryView;

// Field indices: 0=path, 1=title, 2=description, 3=url, 4=username, 5=password, 6=notes
// Field 7=parent is read-only.
const EDITABLE = 7;
const FIELD_COUNT = 8;

const Mode = enum { view, edit };

pub const Signal = enum { none, save, show_history };

pub const Viewer = struct {
    // Entry state
    entry: ?Entry,
    entry_id: ?[20]u8,
    head_hash: ?[20]u8,
    is_new: bool,

    // UI state
    db_allocator: std.mem.Allocator,
    field_cursor: usize,
    show_password: bool,
    mode: Mode,

    // Editable inputs (always alive from init to deinit)
    path_input: zz.TextInput,
    title_input: zz.TextInput,
    desc_input: zz.TextInput,
    url_input: zz.TextInput,
    user_input: zz.TextInput,
    pw_input: zz.TextInput,
    notes_area: zz.TextArea,

    // notes_modified is tracked separately (TextArea.getValue needs an allocator)
    notes_modified: bool,

    // Password generator dialog.
    generator: Generator,
    // Version history overlay.
    history: HistoryView,

    pub fn init(allocator: std.mem.Allocator) Viewer {
        return .{
            .entry = null,
            .entry_id = null,
            .head_hash = null,
            .is_new = false,
            .db_allocator = allocator,
            .field_cursor = 0,
            .show_password = false,
            .mode = .view,
            .path_input = zz.TextInput.init(allocator),
            .title_input = zz.TextInput.init(allocator),
            .desc_input = zz.TextInput.init(allocator),
            .url_input = zz.TextInput.init(allocator),
            .user_input = zz.TextInput.init(allocator),
            .pw_input = zz.TextInput.init(allocator),
            .notes_area = zz.TextArea.init(allocator),
            .notes_modified = false,
            .generator = Generator.init(),
            .history = HistoryView.init(allocator),
        };
    }

    pub fn deinit(self: *Viewer) void {
        if (self.entry) |e| e.deinit(self.db_allocator);
        self.path_input.deinit();
        self.title_input.deinit();
        self.desc_input.deinit();
        self.url_input.deinit();
        self.user_input.deinit();
        self.pw_input.deinit();
        self.notes_area.deinit();
        self.history.deinit();
    }

    /// Set entry for viewing/editing an existing entry.
    pub fn setEntry(self: *Viewer, entry_id: ?[20]u8, head_hash: ?[20]u8, new_entry: ?Entry) void {
        if (self.entry) |old| old.deinit(self.db_allocator);
        self.entry = new_entry;
        self.entry_id = entry_id;
        self.head_hash = head_hash;
        self.is_new = false;
        self.field_cursor = 0;
        self.show_password = false;
        self.mode = .view;
        self.notes_modified = false;
        self.syncInputs();
        self.blurAll();
    }

    /// Prepare viewer for creating a new entry (starts in edit mode at Title).
    /// `path` is pre-populated from the browser's current cursor location.
    pub fn setNewEntry(self: *Viewer, path: []const u8) void {
        if (self.entry) |old| old.deinit(self.db_allocator);
        self.entry = null;
        self.entry_id = null;
        self.head_hash = null;
        self.is_new = true;
        self.field_cursor = 1; // start at Title
        self.show_password = false;
        self.mode = .edit;
        self.notes_modified = false;
        self.path_input.setValue(path) catch {};
        self.title_input.setValue("") catch {};
        self.desc_input.setValue("") catch {};
        self.url_input.setValue("") catch {};
        self.user_input.setValue("") catch {};
        self.pw_input.setValue("") catch {};
        self.notes_area.setValue("") catch {};
        self.blurAll();
        self.focusCurrent();
    }

    /// Returns true if the viewer is currently in edit mode.
    pub fn isEditing(self: *const Viewer) bool {
        return self.mode == .edit;
    }

    /// Returns true if any field differs from the saved entry (or always true for new entries).
    pub fn isModified(self: *const Viewer) bool {
        if (self.is_new) return true;
        for (0..EDITABLE) |i| if (self.fieldModified(i)) return true;
        return false;
    }

    /// Gracefully exit edit mode (commits current field, stays in view mode).
    pub fn leaveEditMode(self: *Viewer) void {
        if (self.mode != .edit) return;
        if (self.field_cursor == 6) self.checkNotesModified();
        self.mode = .view;
        self.blurAll();
    }

    fn syncInputs(self: *Viewer) void {
        const e = self.entry orelse {
            self.path_input.setValue("") catch {};
            self.title_input.setValue("") catch {};
            self.desc_input.setValue("") catch {};
            self.url_input.setValue("") catch {};
            self.user_input.setValue("") catch {};
            self.pw_input.setValue("") catch {};
            self.notes_area.setValue("") catch {};
            return;
        };
        self.path_input.setValue(e.path) catch {};
        self.title_input.setValue(e.title) catch {};
        self.desc_input.setValue(e.description) catch {};
        self.url_input.setValue(e.url) catch {};
        self.user_input.setValue(e.username) catch {};
        self.pw_input.setValue(e.password) catch {};
        self.notes_area.setValue(e.notes) catch {};
    }

    fn blurAll(self: *Viewer) void {
        self.path_input.blur();
        self.title_input.blur();
        self.desc_input.blur();
        self.url_input.blur();
        self.user_input.blur();
        self.pw_input.blur();
        self.notes_area.blur();
    }

    fn focusCurrent(self: *Viewer) void {
        self.blurAll();
        switch (self.field_cursor) {
            0 => self.path_input.focus(),
            1 => self.title_input.focus(),
            2 => self.desc_input.focus(),
            3 => self.url_input.focus(),
            4 => self.user_input.focus(),
            5 => self.pw_input.focus(),
            6 => self.notes_area.focus(),
            else => {},
        }
    }

    fn inputFor(self: *Viewer, idx: usize) ?*zz.TextInput {
        return switch (idx) {
            0 => &self.path_input,
            1 => &self.title_input,
            2 => &self.desc_input,
            3 => &self.url_input,
            4 => &self.user_input,
            5 => &self.pw_input,
            else => null,
        };
    }

    fn fieldModified(self: *const Viewer, idx: usize) bool {
        if (self.is_new) return false;
        const e = self.entry orelse return false;
        return switch (idx) {
            0 => !std.mem.eql(u8, self.path_input.getValue(), e.path),
            1 => !std.mem.eql(u8, self.title_input.getValue(), e.title),
            2 => !std.mem.eql(u8, self.desc_input.getValue(), e.description),
            3 => !std.mem.eql(u8, self.url_input.getValue(), e.url),
            4 => !std.mem.eql(u8, self.user_input.getValue(), e.username),
            5 => !std.mem.eql(u8, self.pw_input.getValue(), e.password),
            6 => self.notes_modified,
            else => false,
        };
    }

    fn checkNotesModified(self: *Viewer) void {
        const orig = if (self.entry) |e| e.notes else "";
        if (self.notes_area.getValue(self.db_allocator)) |cur| {
            defer self.db_allocator.free(cur);
            self.notes_modified = !std.mem.eql(u8, cur, orig);
        } else |_| {
            self.notes_modified = true;
        }
    }

    pub fn handleKey(self: *Viewer, key: zz.KeyEvent, db: anytype) Signal {
        // History view intercepts all keys when active.
        if (self.history.active) {
            const sig = self.history.handleKey(key, db);
            if (sig == .restored) {
                // Reload the current entry after a restore.
                if (self.entry_id) |eid| {
                    const head_hash = findIndexHeadHash(db.listEntries(), eid);
                    const loaded = db.getEntry(eid) catch null;
                    self.setEntry(eid, head_hash, loaded);
                }
            }
            return .none;
        }
        // Generator intercepts all keys when active.
        if (self.generator.active) {
            self.generator.handleKey(key);
            if (self.generator.accepted) {
                const pw = self.generator.getPassword();
                self.pw_input.setValue(pw) catch {};
                self.mode = .view;
                self.blurAll();
            }
            return .none;
        }
        return switch (self.mode) {
            .view => self.viewKey(key),
            .edit => self.editKey(key),
        };
    }

    fn viewKey(self: *Viewer, key: zz.KeyEvent) Signal {
        switch (key.key) {
            .char => |c| switch (c) {
                'j' => self.field_cursor = @min(self.field_cursor + 1, FIELD_COUNT - 1),
                'k' => if (self.field_cursor > 0) {
                    self.field_cursor -= 1;
                },
                'h' => self.show_password = !self.show_password,
                'e' => if (self.field_cursor < EDITABLE) {
                    self.mode = .edit;
                    self.focusCurrent();
                },
                'g' => if (self.field_cursor == 5) {
                    // Open password generator when cursor is on Password field.
                    self.generator.show();
                },
                'H' => if (!self.is_new) return .show_history,
                'S' => return .save,
                else => {},
            },
            .down => self.field_cursor = @min(self.field_cursor + 1, FIELD_COUNT - 1),
            .up => if (self.field_cursor > 0) {
                self.field_cursor -= 1;
            },
            else => {},
        }
        return .none;
    }

    fn editKey(self: *Viewer, key: zz.KeyEvent) Signal {
        const idx = self.field_cursor;
        if (idx == 6) {
            // TextArea: Esc exits edit mode; everything else goes to the area.
            switch (key.key) {
                .escape => {
                    self.checkNotesModified();
                    self.mode = .view;
                    self.blurAll();
                },
                else => self.notes_area.handleKey(key),
            }
        } else if (idx < EDITABLE) {
            // TextInput: Esc or Enter exits edit mode.
            switch (key.key) {
                .escape, .enter => {
                    self.mode = .view;
                    self.blurAll();
                },
                else => if (self.inputFor(idx)) |inp| inp.handleKey(key),
            }
        }
        return .none;
    }

    /// Build an Entry from current inputs. Caller must call `entry.deinit(db_allocator)`.
    pub fn buildEntry(self: *Viewer) !Entry {
        const a = self.db_allocator;
        const notes = try self.notes_area.getValue(a);
        errdefer a.free(notes);
        return Entry{
            .parent_hash = self.head_hash,
            .path = try a.dupe(u8, self.path_input.getValue()),
            .title = try a.dupe(u8, self.title_input.getValue()),
            .description = try a.dupe(u8, self.desc_input.getValue()),
            .url = try a.dupe(u8, self.url_input.getValue()),
            .username = try a.dupe(u8, self.user_input.getValue()),
            .password = try a.dupe(u8, self.pw_input.getValue()),
            .notes = notes,
        };
    }

    pub fn view(
        self: *Viewer,
        allocator: std.mem.Allocator,
        pane_width: u16,
        pane_height: u16,
        focused: bool,
    ) ![]const u8 {
        // Dialog overlays take priority.  Return early before building viewer content.
        // We do NOT use zz.place.overlay because that function walks content
        // byte-by-byte and cannot handle ANSI escape sequences (it counts colour-code
        // bytes as visible columns, producing garbled output).
        if (self.generator.active) {
            const gen_view = try self.generator.view(allocator);
            return zz.place.place(allocator, pane_width, pane_height, .center, .middle, gen_view);
        }
        if (self.history.active) {
            const hist_view = try self.history.view(allocator);
            return zz.place.place(allocator, pane_width, pane_height, .center, .middle, hist_view);
        }

        // Size TextArea to fit inside the pane (content width = pane_width - 3 overhead,
        // minus a few more for the "Notes: " label prefix area).
        const notes_w: u16 = if (pane_width > 12) pane_width - 12 else 20;
        self.notes_area.setSize(notes_w, 4);

        var buf: std.ArrayList(u8) = .{};
        defer buf.deinit(allocator);
        const w = buf.writer(allocator);

        if (self.entry != null or self.is_new) {
            const editing = self.mode == .edit;

            try renderField(w, allocator, self.inputFor(0).?, 0, "Path",
                self.path_input.getValue(), self.field_cursor, editing, self.fieldModified(0));
            try renderField(w, allocator, self.inputFor(1).?, 1, "Title",
                self.title_input.getValue(), self.field_cursor, editing, self.fieldModified(1));
            try renderField(w, allocator, self.inputFor(2).?, 2, "Description",
                self.desc_input.getValue(), self.field_cursor, editing, self.fieldModified(2));
            try renderField(w, allocator, self.inputFor(3).?, 3, "URL",
                self.url_input.getValue(), self.field_cursor, editing, self.fieldModified(3));
            try renderField(w, allocator, self.inputFor(4).?, 4, "Username",
                self.user_input.getValue(), self.field_cursor, editing, self.fieldModified(4));

            // Password: masked in view mode unless show_password is set.
            const pw_raw = self.pw_input.getValue();
            const pw_display: []const u8 = if (self.show_password or (editing and self.field_cursor == 5))
                pw_raw
            else blk: {
                const m = try allocator.alloc(u8, pw_raw.len);
                @memset(m, '*');
                break :blk m;
            };
            try renderField(w, allocator, self.inputFor(5).?, 5, "Password",
                pw_display, self.field_cursor, editing, self.fieldModified(5));

            // Notes: TextArea in edit mode, plain text in view mode.
            const notes_selected = self.field_cursor == 6;
            const notes_mod = self.fieldModified(6);
            const mod_star: []const u8 = if (notes_mod) "*" else "";
            const notes_label = try std.fmt.allocPrint(allocator, "Notes{s}: ", .{mod_star});
            try w.writeAll(try labelStyle(notes_selected, notes_mod).render(allocator, notes_label));
            if (editing and notes_selected) {
                try w.writeByte('\n');
                try w.writeAll(try self.notes_area.view(allocator));
            } else {
                const notes_val = try self.notes_area.getValue(allocator);
                var vs = zz.Style{};
                if (notes_selected) vs = vs.fg(zz.Color.cyan());
                try w.writeAll(try vs.render(allocator, notes_val));
            }
            try w.writeByte('\n');

            // Parent hash (read-only, italic/dim).
            if (!self.is_new) {
                if (self.entry) |ee| {
                    var hex_buf: [40]u8 = undefined;
                    const parent_str: []const u8 = if (ee.parent_hash) |h| blk: {
                        hex_buf = std.fmt.bytesToHex(h, .lower);
                        break :blk &hex_buf;
                    } else "(genesis)";
                    const sel = self.field_cursor == 7;
                    try w.writeAll(try labelStyle(sel, false).render(allocator, "Parent: "));
                    var vs = zz.Style{};
                    vs = vs.italic(true);
                    vs = vs.dim(true);
                    try w.writeAll(try vs.render(allocator, parent_str));
                    try w.writeByte('\n');
                }
            }

            // Help bar.
            try w.writeByte('\n');
            var hint_s = zz.Style{};
            hint_s = hint_s.dim(true);
            const hints: []const u8 = if (editing)
                "Enter/Esc: stop editing   S: save"
            else if (self.isModified())
                "j/k: nav  e: edit  S: save  h: toggle pw  g: gen pw  H: history"
            else
                "j/k: nav  e: edit  h: pw  g: gen  H: history  Tab: switch  q: quit";
            try w.writeAll(try hint_s.render(allocator, hints));
        } else {
            try w.writeAll("No entry selected.\n\n");
            var dim_s = zz.Style{};
            dim_s = dim_s.dim(true);
            try w.writeAll(try dim_s.render(allocator,
                "Select an entry in the browser pane.\nTab: switch pane  n: new entry  q: quit"));
        }

        const content_w: u16 = pane_width -| 3; // 1 left-pad + 2 borders
        const content_h: u16 = pane_height -| 2; // 2 borders (top + bottom)

        var box_s = zz.Style{};
        box_s = box_s.borderAll(zz.Border.rounded);
        if (focused) box_s = box_s.borderForeground(zz.Color.cyan());
        box_s = box_s.paddingLeft(1);
        box_s = box_s.width(content_w);
        box_s = box_s.height(content_h);
        return box_s.render(allocator, buf.items);
    }
};

fn findIndexHeadHash(entries: anytype, entry_id: [20]u8) ?[20]u8 {
    for (entries) |ie| {
        if (std.mem.eql(u8, &ie.entry_id, &entry_id)) return ie.head_hash;
    }
    return null;
}

fn labelStyle(selected: bool, modified: bool) zz.Style {
    var s = zz.Style{};
    if (selected) {
        s = s.bold(true);
        s = s.fg(zz.Color.magenta());
    }
    if (modified) s = s.fg(zz.Color.yellow());
    return s;
}

fn renderField(
    w: anytype,
    allocator: std.mem.Allocator,
    input: *zz.TextInput,
    idx: usize,
    name: []const u8,
    display_val: []const u8,
    cursor: usize,
    editing: bool,
    modified: bool,
) !void {
    const selected = cursor == idx;
    const editing_this = editing and selected;
    const mod_star: []const u8 = if (modified) "*" else "";
    const label = try std.fmt.allocPrint(allocator, "{s}{s}: ", .{ name, mod_star });
    try w.writeAll(try labelStyle(selected, modified).render(allocator, label));
    if (editing_this) {
        try w.writeAll(try input.view(allocator));
    } else {
        var vs = zz.Style{};
        if (selected) vs = vs.fg(zz.Color.cyan());
        try w.writeAll(try vs.render(allocator, display_val));
    }
    try w.writeByte('\n');
}
