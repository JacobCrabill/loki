const std = @import("std");
const zz = @import("zigzag");
const loki = @import("loki");

const Entry = loki.Entry;
const Generator = @import("generator.zig").Generator;

// Field indices: 0=path, 1=title, 2=description, 3=url, 4=username, 5=password, 6=notes
// Field 7=parent is read-only.
const EDITABLE = 7;
const FIELD_COUNT = 8;

const Mode = enum { view, edit };

pub const Signal = enum { none, save, show_history, quit };

const Fields = enum(u8) {
    path,
    title,
    description,
    url,
    username,
    password,
    notes,
    parent,
    field_max,
    _, // We leave the enum open to allow casting from integers
};

fn getFieldName(field: Fields) []const u8 {
    return switch (field) {
        .path => "Path",
        .title => "Title",
        .description => "Description",
        .url => "URL",
        .username => "Username",
        .password => "Password",
        .notes => "Notes",
        .parent => "Parent",
        else => "<Invalid>",
    };
}

/// Text edit Components used for data entry
const TextEdit = union(enum) {
    input: *zz.TextInput,
    area: *zz.TextArea,

    pub fn view(self: *const TextEdit, allocator: std.mem.Allocator) ![]const u8 {
        return switch (self.*) {
            inline else => |e| try e.view(allocator),
        };
    }

    pub fn handleKey(self: *const TextEdit, key: zz.KeyEvent) void {
        switch (self.*) {
            inline else => |*e| e.*.handleKey(key),
        }
    }
};

pub const Viewer = struct {
    // Entry state
    entry: ?Entry,
    entry_id: ?[20]u8,
    head_hash: ?[20]u8,
    is_new: bool,

    // UI state
    db_allocator: std.mem.Allocator,
    field_cursor: Fields = .path,
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

    pub fn init(allocator: std.mem.Allocator) Viewer {
        return .{
            .entry = null,
            .entry_id = null,
            .head_hash = null,
            .is_new = false,
            .db_allocator = allocator,
            .field_cursor = .path,
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
    }

    /// Set entry for viewing/editing an existing entry.
    pub fn setEntry(self: *Viewer, entry_id: ?[20]u8, head_hash: ?[20]u8, new_entry: ?Entry) void {
        if (self.entry) |old| old.deinit(self.db_allocator);
        self.entry = new_entry;
        self.entry_id = entry_id;
        self.head_hash = head_hash;
        self.is_new = false;
        self.field_cursor = .path;
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
        self.field_cursor = .title;
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
        for (0..@intFromEnum(Fields.parent)) |i| if (self.fieldModified(@enumFromInt(i))) return true;
        return false;
    }

    /// Gracefully exit edit mode (commits current field, stays in view mode).
    pub fn leaveEditMode(self: *Viewer) void {
        if (self.mode != .edit) return;
        if (self.field_cursor == .notes) self.checkNotesModified();
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
            .path => self.path_input.focus(),
            .title => self.title_input.focus(),
            .description => self.desc_input.focus(),
            .url => self.url_input.focus(),
            .username => self.user_input.focus(),
            .password => self.pw_input.focus(),
            .notes => self.notes_area.focus(),
            else => {},
        }
    }

    fn inputFor(self: *Viewer, field: Fields) ?TextEdit {
        return switch (field) {
            .path => .{ .input = &self.path_input },
            .title => .{ .input = &self.title_input },
            .description => .{ .input = &self.desc_input },
            .url => .{ .input = &self.url_input },
            .username => .{ .input = &self.user_input },
            .password => .{ .input = &self.pw_input },
            .notes => .{ .area = &self.notes_area },
            else => null,
        };
    }

    fn fieldModified(self: *const Viewer, field: Fields) bool {
        if (self.is_new) return false;
        const e = self.entry orelse return false;
        return switch (field) {
            .path => !std.mem.eql(u8, self.path_input.getValue(), e.path),
            .title => !std.mem.eql(u8, self.title_input.getValue(), e.title),
            .description => !std.mem.eql(u8, self.desc_input.getValue(), e.description),
            .url => !std.mem.eql(u8, self.url_input.getValue(), e.url),
            .username => !std.mem.eql(u8, self.user_input.getValue(), e.username),
            .password => !std.mem.eql(u8, self.pw_input.getValue(), e.password),
            .notes => self.notes_modified,
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

    pub fn handleKey(self: *Viewer, key: zz.KeyEvent, _db: anytype) Signal {
        _ = _db;
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
                'j' => self.incrementFieldCursor(),
                'k' => self.decrementFieldCursor(),
                'h' => self.show_password = !self.show_password,
                'e' => if (@intFromEnum(self.field_cursor) < @intFromEnum(Fields.parent)) {
                    self.mode = .edit;
                    self.focusCurrent();
                },
                'g' => if (self.field_cursor == .password) {
                    // Open password generator when cursor is on Password field.
                    self.generator.show();
                },
                'y' => switch (self.field_cursor) {
                    .url => copyToClipboard(self.url_input.getValue(), self.db_allocator),
                    .username => copyToClipboard(self.user_input.getValue(), self.db_allocator),
                    .password => copyToClipboard(self.pw_input.getValue(), self.db_allocator),
                    else => {},
                },
                'H' => if (!self.is_new) return .show_history,
                's' => return .save,
                'q' => {
                    if (!self.isModified())
                        return .quit;
                    // TODO: handle dirty state, ask for confirmation or save
                },
                else => {},
            },
            .down => self.incrementFieldCursor(),
            .up => self.decrementFieldCursor(),
            else => {},
        }
        return .none;
    }

    fn editKey(self: *Viewer, key: zz.KeyEvent) Signal {
        if (self.field_cursor == .notes) {
            // TextArea: Esc exits edit mode; everything else goes to the area.
            switch (key.key) {
                .escape => {
                    self.checkNotesModified();
                    self.mode = .view;
                    self.blurAll();
                },
                else => self.notes_area.handleKey(key),
            }
        } else if (@intFromEnum(self.field_cursor) < @intFromEnum(Fields.parent)) {
            // TextInput: Esc or Enter exits edit mode.
            switch (key.key) {
                .escape, .enter => {
                    self.mode = .view;
                    self.blurAll();
                },
                // TODO: notes_area as a textarea - create union to avoid need for optional
                else => if (self.inputFor(self.field_cursor)) |*inp| inp.handleKey(key),
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

        // Size TextArea to fit inside the pane (content width = pane_width - 3 overhead,
        // minus a few more for the "Notes: " label prefix area).
        // TODO: No magic nubmers!
        const notes_w: u16 = if (pane_width > 12) pane_width - 12 else 20;
        self.notes_area.setSize(notes_w, 4);

        var buf: std.ArrayList(u8) = .{};
        defer buf.deinit(allocator);
        const w = buf.writer(allocator);

        if (self.entry != null or self.is_new) {
            const editing = self.mode == .edit;

            // TODO: use loop to reduce duplicate code
            try self.renderField(w, allocator, .path, editing);
            try self.renderField(w, allocator, .title, editing);
            try self.renderField(w, allocator, .description, editing);
            try self.renderField(w, allocator, .url, editing);
            try self.renderField(w, allocator, .username, editing);
            try self.renderField(w, allocator, .password, editing);
            try self.renderField(w, allocator, .notes, editing);

            // Parent hash (read-only, italic/dim).
            if (!self.is_new) {
                if (self.entry) |ee| {
                    var hex_buf: [40]u8 = undefined;
                    const parent_str: []const u8 = if (ee.parent_hash) |h| blk: {
                        hex_buf = std.fmt.bytesToHex(h, .lower);
                        break :blk &hex_buf;
                    } else "(genesis)";
                    const sel = self.field_cursor == .parent;
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
                "Enter/Esc: stop editing   s: save"
            else if (self.isModified())
                "j/k: nav  e: edit  s: save  h: toggle pw  g: gen pw  y: copy  H: history"
            else
                "j/k: nav  e: edit  h: pw  g: gen  y: copy  H: history  Tab: switch  q: quit";
            try w.writeAll(try hint_s.render(allocator, hints));
        } else {
            try w.writeAll("No entry selected.\n\n");
            var dim_s = zz.Style{};
            dim_s = dim_s.dim(true);
            try w.writeAll(try dim_s.render(allocator, "Select an entry in the browser pane.\nTab: switch pane  n: new entry  q: quit"));
        }

        const content_w: u16 = pane_width -| 4; // 1 left-pad + 2 borders + (?)1 right-pad(?)
        const content_h: u16 = pane_height -| 2; // 2 borders (top + bottom)

        var box_s = zz.Style{};
        if (focused) {
            box_s = box_s.borderAll(zz.Border.thick).borderForeground(zz.Color.cyan());
        } else {
            box_s = box_s.borderAll(zz.Border.rounded);
        }
        if (focused) box_s = box_s.borderForeground(zz.Color.cyan());
        box_s = box_s.paddingLeft(1);
        box_s = box_s.width(content_w);
        box_s = box_s.height(content_h);
        return box_s.render(allocator, buf.items);
    }

    fn renderField(
        self: *Viewer,
        writer: anytype,
        allocator: std.mem.Allocator,
        field: Fields,
        editing: bool,
    ) !void {
        const name = getFieldName(field);
        const display_val = self.getFieldValue(field, allocator);
        const modified = self.fieldModified(field);
        const selected = self.field_cursor == field;
        const editing_this = editing and selected;

        const mod_star: []const u8 = if (modified) "*" else "";
        const label = try std.fmt.allocPrint(allocator, "{s}{s}: ", .{ name, mod_star });
        try writer.writeAll(try labelStyle(selected, modified).render(allocator, label));
        if (editing_this) {
            if (self.inputFor(field)) |input| {
                if (field == .notes) try writer.writeAll("\n");
                try writer.writeAll(try input.view(allocator));
                if (field == .notes) try writer.writeAll("\n");
            }
        } else {
            var vs = zz.Style{};
            if (selected) vs = vs.fg(zz.Color.cyan());
            if (field == .password and !self.show_password) {
                // Password: masked in view mode unless show_password is set.
                const hidden_pw = try allocator.alloc(u8, display_val.len);
                @memset(hidden_pw, '*');
                try writer.writeAll(try vs.render(allocator, hidden_pw));
            } else if (field == .notes) {
                try writer.writeAll("\n");
                try writer.writeAll(try vs.render(allocator, display_val));
            } else {
                try writer.writeAll(try vs.render(allocator, display_val));
            }
        }
        try writer.writeByte('\n');
    }

    /// Get the raw value of the given field
    ///
    /// TODO: verify that the allocator is an arena!
    fn getFieldValue(self: *const Viewer, field: Fields, arena: std.mem.Allocator) []const u8 {
        return switch (field) {
            .path => self.path_input.getValue(),
            .title => self.title_input.getValue(),
            .description => self.desc_input.getValue(),
            .url => self.url_input.getValue(),
            .username => self.user_input.getValue(),
            .password => self.pw_input.getValue(),
            .notes => self.notes_area.getValue(arena) catch "ERROR: OOM",
            .parent => blk: {
                if (!self.is_new) {
                    if (self.entry) |ee| {
                        var hex_buf: [40]u8 = undefined;
                        if (ee.parent_hash) |h| {
                            hex_buf = std.fmt.bytesToHex(h, .lower);
                            break :blk arena.dupe(u8, hex_buf[0..]) catch "ERROR: OOM";
                        }
                    }
                }
                break :blk "(genesis)";
            },
            else => "ERROR: Invalid Field",
        };
    }

    fn incrementFieldCursor(self: *Viewer) void {
        const idx: u8 = @intFromEnum(self.field_cursor);
        const max_idx: u8 = @intFromEnum(Fields.field_max) - 1;
        self.field_cursor = @enumFromInt(@min(idx + 1, max_idx));
    }

    fn decrementFieldCursor(self: *Viewer) void {
        const idx: u8 = @intFromEnum(self.field_cursor);
        if (idx > 0) {
            self.field_cursor = @enumFromInt(@max(idx - 1, 0));
        }
    }
};

fn copyToClipboard(text: []const u8, allocator: std.mem.Allocator) void {
    const encoded_len = std.base64.standard.Encoder.calcSize(text.len);
    const encoded_buf = allocator.alloc(u8, encoded_len) catch return;
    defer allocator.free(encoded_buf);
    const encoded = std.base64.standard.Encoder.encode(encoded_buf, text);
    const seq = std.fmt.allocPrint(allocator, "\x1b]52;c;{s}\x07", .{encoded}) catch return;
    defer allocator.free(seq);
    std.fs.File.stdout().writeAll(seq) catch {};
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
