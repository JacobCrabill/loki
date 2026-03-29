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

    // Notes display in view mode uses a Viewport (scrollable, fixed height).
    // notes_content is owned by db_allocator so it outlives the frame arena.
    notes_viewport: zz.Viewport,
    notes_content: ?[]const u8,

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
            .notes_viewport = zz.Viewport.init(allocator, 40, 4),
            .notes_content = null,
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
        self.notes_viewport.deinit();
        if (self.notes_content) |nc| self.db_allocator.free(nc);
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
        self.setNotesContent(if (new_entry) |e| e.notes else "");
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
        self.setNotesContent("");
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
        if (self.field_cursor == .notes) {
            self.checkNotesModified();
            // Refresh the viewport with whatever was typed into the TextArea.
            // getValue returns db_allocator-owned memory; take ownership directly.
            if (self.notes_area.getValue(self.db_allocator)) |cur| {
                if (self.notes_content) |old| self.db_allocator.free(old);
                self.notes_content = cur;
                self.notes_viewport.setContent(cur) catch {};
            } else |_| {}
        }
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

    /// Update the notes content owned by this Viewer and refresh the Viewport.
    /// The string is duped onto db_allocator so it survives across frames.
    fn setNotesContent(self: *Viewer, notes: []const u8) void {
        if (self.notes_content) |old| self.db_allocator.free(old);
        self.notes_content = @as(?[]const u8, self.db_allocator.dupe(u8, notes) catch null);
        const nc = self.notes_content orelse "";
        self.notes_viewport.setContent(nc) catch {};
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

    pub fn getHints(self: *const Viewer) []const u8 {
        if (self.generator.active) return self.generator.getHints();
        if (self.entry == null and !self.is_new) return "Tab: switch  q: quit";
        return switch (self.mode) {
            .edit => if (self.field_cursor == .notes)
                "Esc: stop editing"
            else
                "Enter/Esc: stop editing",
            .view => if (self.isModified())
                "j/k: nav  e: edit  s: save  h: toggle pw  g: gen  y: copy  H: history"
            else
                "j/k: nav  e: edit  h: pw  g: gen  y: copy  H: history  Tab: switch  q: quit",
        };
    }

    pub fn handleKey(self: *Viewer, key: zz.KeyEvent) Signal {
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
            .down => if (self.field_cursor == .notes) self.notes_viewport.scrollDown(1) else self.incrementFieldCursor(),
            .up => if (self.field_cursor == .notes) self.notes_viewport.scrollUp(1) else self.decrementFieldCursor(),
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

        // ── Layout dimensions ────────────────────────────────────────────────
        // Must be computed before rendering so we can size both the edit
        // TextArea and the view Viewport ahead of the renderField calls.
        const content_w: u16 = pane_width -| 4; // 1 left-pad + 2 borders + 1 right-pad
        const content_h: u16 = pane_height -| 2; // top + bottom borders

        // Dynamic notes height: fill space not consumed by other fields.
        // The -1 accounts for the phantom row that measure.height() adds for
        // the final trailing '\n' in the content buffer.
        const non_notes: usize = self.calcNonNotesRows(content_w);
        const notes_h: u16 = blk: {
            const ch: usize = content_h;
            const available = if (ch > non_notes + 1) ch - non_notes - 1 else 2;
            break :blk @intCast(@min(@max(available, 2), @as(usize, std.math.maxInt(u16))));
        };

        // Size the edit TextArea (used when editing notes).
        self.notes_area.setSize(content_w, notes_h);
        // Size the view Viewport (used when displaying notes in view mode).
        // NOTE: Removing 1 column for the scroll bar
        self.notes_viewport.setSize(content_w - 1, notes_h);

        var buf: std.Io.Writer.Allocating = .init(allocator);
        defer buf.deinit();
        const w = &buf.writer;

        if (self.entry != null or self.is_new) {
            const editing = self.mode == .edit;

            try self.renderField(w, allocator, .path, editing, content_w);
            try self.renderField(w, allocator, .title, editing, content_w);
            try self.renderField(w, allocator, .description, editing, content_w);
            try self.renderField(w, allocator, .url, editing, content_w);
            try self.renderField(w, allocator, .username, editing, content_w);
            try self.renderField(w, allocator, .password, editing, content_w);
            try self.renderField(w, allocator, .notes, editing, content_w);

            // Parent hash (read-only, italic/dim).
            if (!self.is_new) {
                if (self.entry) |ee| {
                    var hex_buf: [40]u8 = undefined;
                    const parent_str: []const u8 = if (ee.parent_hash) |h| blk: {
                        hex_buf = std.fmt.bytesToHex(h, .lower);
                        break :blk &hex_buf;
                    } else "(genesis)";
                    const sel = self.field_cursor == .parent;
                    try w.writeByte('\n');
                    try w.writeAll(try labelStyle(sel, false).render(allocator, "Parent: "));
                    var vs = zz.Style{};
                    vs = vs.italic(true);
                    vs = vs.dim(true);
                    try w.writeAll(try vs.render(allocator, parent_str));
                }
            }
        } else {
            try w.writeAll("No entry selected.\n\nSelect an entry in the browser pane.");
        }

        // Pad content to exactly content_h rows so the bottom border reaches
        // the bottom of the pane.
        const content_padded = try zz.placeVertical(allocator, content_h, .top, buf.written());

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

    fn renderField(
        self: *Viewer,
        writer: *std.Io.Writer,
        allocator: std.mem.Allocator,
        field: Fields,
        editing: bool,
        content_w: u16,
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
                // TextArea (notes) renders on its own line; TextInputs are inline.
                if (field == .notes) try writer.writeAll("\n");
                try writer.writeAll(try input.view(allocator));
                // No extra '\n' after the TextArea — writeByte('\n') below is enough.
            }
        } else {
            var vs = zz.Style{};
            if (selected) vs = vs.fg(zz.Color.cyan());
            const cw: usize = content_w;
            // label is ASCII-only so its byte length equals its display width.
            const lw: usize = label.len;

            if (field == .password and !self.show_password) {
                // Masked password: fill with '*', capped to available line width.
                const first_w = if (cw > lw) cw - lw else 0;
                const star_count = @min(display_val.len, first_w);
                const hidden = try allocator.alloc(u8, star_count);
                @memset(hidden, '*');
                try writer.writeAll(try vs.render(allocator, hidden));
            } else if (field == .notes) {
                // Notes: render below the label using the pre-sized Viewport.
                // The Viewport output is already exactly (content_w × notes_h)
                // so no extra styling or padding is needed.
                try writer.writeAll("\n");
                try writer.writeAll(try self.notes_viewport.view(allocator));
            } else {
                // All other fields: soft-wrap long values so they never overflow
                // the pane width.
                const first_w = if (cw > lw) cw - lw else 0;
                const wrapped = try wrapText(allocator, display_val, first_w, cw);
                try writer.writeAll(try vs.render(allocator, wrapped));
            }
        }
        try writer.writeByte('\n');
    }

    /// Get the raw value of the given field
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

    /// Count display rows used by every rendered element except the notes
    /// Viewport itself.  Drives the dynamic notes height calculation.
    ///
    /// Accounting (per full render of one existing entry):
    ///   - Each field "Label: value\n" contributes countWrappedRows(value, …) rows.
    ///   - The notes label line ("Notes: \n") contributes 1 row.
    ///   - The trailing \n of the notes field (writeByte('\n') in renderField)
    ///     does NOT add a blank row when another field follows immediately.
    ///   - The parent row contributes 1 row.
    ///   - measure.height counts one extra phantom row from the final trailing \n
    ///     of the whole content buffer, accounted for by the -1 in view().
    fn calcNonNotesRows(self: *const Viewer, cw: u16) usize {
        if (self.entry == null and !self.is_new) return 0;
        const w: usize = cw;
        // Conservative label widths (name + "*: ") so we never under-count.
        const LW_PATH: usize = 7; // "Path*: "
        const LW_TITLE: usize = 8; // "Title*: "
        const LW_DESC: usize = 14; // "Description*: "
        const LW_URL: usize = 6; // "URL*: "
        const LW_USER: usize = 11; // "Username*: "
        var rows: usize = 0;
        rows += countWrappedRows(self.path_input.getValue(), w -| LW_PATH, w);
        rows += countWrappedRows(self.title_input.getValue(), w -| LW_TITLE, w);
        rows += countWrappedRows(self.desc_input.getValue(), w -| LW_DESC, w);
        rows += countWrappedRows(self.url_input.getValue(), w -| LW_URL, w);
        rows += countWrappedRows(self.user_input.getValue(), w -| LW_USER, w);
        rows += 1; // password (always 1 — masked)
        rows += 1; // "Notes: " label line
        if (!self.is_new and self.entry != null) rows += 1; // parent hash
        return rows;
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

/// Soft-wrap `text` to fit in `first_w` display columns on the first segment
/// and `rest_w` on every subsequent segment.  Hard newlines are honoured.
/// Returns a freshly-allocated, newline-joined string.
fn wrapText(
    allocator: std.mem.Allocator,
    text: []const u8,
    first_w: usize,
    rest_w: usize,
) ![]const u8 {
    if (text.len == 0) return allocator.dupe(u8, text);
    var out = std.Io.Writer.Allocating.init(allocator);
    defer out.deinit();
    const w = &out.writer;
    var col: usize = 0;
    var cap: usize = if (first_w > 0) first_w else rest_w;
    var i: usize = 0;
    while (i < text.len) {
        if (text[i] == '\n') {
            try w.writeByte('\n');
            col = 0;
            cap = rest_w;
            i += 1;
            continue;
        }
        const blen = std.unicode.utf8ByteSequenceLength(text[i]) catch 1;
        const end = @min(i + blen, text.len);
        const ch = text[i..end];
        const cp = std.unicode.utf8Decode(ch) catch 0xFFFD;
        const cw = zz.measure.charWidth(cp);
        if (col > 0 and col + cw > cap) {
            try w.writeByte('\n');
            col = 0;
            cap = rest_w;
        }
        try w.writeAll(ch);
        col += cw;
        i = end;
    }
    return allocator.dupe(u8, out.written());
}

/// Count how many display rows `text` occupies when soft-wrapped at `first_w`
/// / `rest_w` columns.  Always returns at least 1.
fn countWrappedRows(text: []const u8, first_w: usize, rest_w: usize) usize {
    const cap0: usize = if (first_w > 0) first_w else rest_w;
    if (cap0 == 0) return 1;
    var rows: usize = 1;
    var col: usize = 0;
    var cap: usize = cap0;
    var i: usize = 0;
    while (i < text.len) {
        if (text[i] == '\n') {
            rows += 1;
            col = 0;
            cap = rest_w;
            i += 1;
            continue;
        }
        const blen = std.unicode.utf8ByteSequenceLength(text[i]) catch 1;
        const end = @min(i + blen, text.len);
        const cp = std.unicode.utf8Decode(text[i..end]) catch 0xFFFD;
        const cw = zz.measure.charWidth(cp);
        if (col > 0 and col + cw > cap) {
            rows += 1;
            col = 0;
            cap = rest_w;
        }
        col += cw;
        i = end;
    }
    return rows;
}

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
    s = s.bold(true);
    if (selected) {
        s = s.fg(zz.Color.magenta());
    }
    if (modified) s = s.fg(zz.Color.yellow());
    return s;
}
