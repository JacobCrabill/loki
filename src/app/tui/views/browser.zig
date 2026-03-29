const std = @import("std");
const zz = @import("zigzag");
const loki = @import("loki");

const IndexEntry = loki.store.index.IndexEntry;

const ENTRY_ICON = "󰂺 ";
const DIR_ICON = " ";

/// A single visible row in the tree browser.
const Row = struct {
    is_folder: bool,
    depth: usize,
    label: []u8, // owned
    entry_id: ?[20]u8, // non-null for entries
    path: []u8, // owned — folder's full path or entry's path

    fn deinit(self: Row, a: std.mem.Allocator) void {
        a.free(self.label);
        a.free(self.path);
    }
};

// ---------------------------------------------------------------------------
// File-level helpers
// ---------------------------------------------------------------------------

/// Returns the last path segment of `path` (the part after the last '/').
fn lastName(path: []const u8) []const u8 {
    if (std.mem.lastIndexOfScalar(u8, path, '/')) |idx| return path[idx + 1 ..];
    return path;
}

/// Returns true if `child` is a direct child folder of `parent`.
fn isDirectChild(parent: []const u8, child: []const u8) bool {
    if (parent.len == 0) {
        return child.len > 0 and std.mem.indexOf(u8, child, "/") == null;
    }
    if (child.len <= parent.len + 1) return false;
    if (!std.mem.startsWith(u8, child, parent)) return false;
    if (child[parent.len] != '/') return false;
    const rest = child[parent.len + 1 ..];
    return std.mem.indexOf(u8, rest, "/") == null;
}

/// Build a search key for `row` into `buf` without heap allocation.
/// Returns a slice of `buf`: "path/label" for entries, "path" for folders.
fn buildSearchKey(buf: *[512]u8, row: *const Row) []const u8 {
    if (row.is_folder) {
        const n = @min(row.path.len, buf.len);
        @memcpy(buf[0..n], row.path[0..n]);
        return buf[0..n];
    }
    if (row.path.len == 0) {
        const n = @min(row.label.len, buf.len);
        @memcpy(buf[0..n], row.label[0..n]);
        return buf[0..n];
    }
    var pos: usize = 0;
    const pl = @min(row.path.len, buf.len);
    @memcpy(buf[0..pl], row.path[0..pl]);
    pos += pl;
    if (pos < buf.len) {
        buf[pos] = '/';
        pos += 1;
    }
    const ll = @min(row.label.len, buf.len - pos);
    @memcpy(buf[pos..][0..ll], row.label[0..ll]);
    return buf[0 .. pos + ll];
}

// ---------------------------------------------------------------------------
// Browser
// ---------------------------------------------------------------------------

/// Left pane: hierarchical file-browser built from entry paths.
pub const Browser = struct {
    allocator: std.mem.Allocator,
    rows: std.ArrayList(Row),
    /// Index into `rows` of the currently selected item.
    cursor: usize,
    /// Scroll offset for unfiltered view.
    scroll: usize,

    // Filter state — set by MainScreen via setFilter / clearFilter.
    // The browser does not own the SearchPane; it only stores a copy of the
    // query string so it can refilter after populate().
    filter: std.ArrayList(u8),
    /// Indices into `rows` that match the current filter query.
    filtered_indices: std.ArrayList(usize),
    /// Position within `filtered_indices` of the highlighted row.
    filter_cursor: usize,
    /// Scroll offset within `filtered_indices`.
    filter_scroll: usize,

    pub fn init(allocator: std.mem.Allocator) Browser {
        return .{
            .allocator = allocator,
            .rows = .{},
            .cursor = 0,
            .scroll = 0,
            .filter = .{},
            .filtered_indices = .{},
            .filter_cursor = 0,
            .filter_scroll = 0,
        };
    }

    pub fn deinit(self: *Browser) void {
        for (self.rows.items) |row| row.deinit(self.allocator);
        self.rows.deinit(self.allocator);
        self.filter.deinit(self.allocator);
        self.filtered_indices.deinit(self.allocator);
    }

    /// Rebuild the tree from a fresh list of index entries.
    /// Re-applies the current filter if one is active.
    pub fn populate(self: *Browser, entries: []const IndexEntry) !void {
        for (self.rows.items) |row| row.deinit(self.allocator);
        self.rows.clearRetainingCapacity();
        self.cursor = 0;
        self.scroll = 0;

        // Sort by (path, title).
        var sorted: std.ArrayList(IndexEntry) = .{};
        defer sorted.deinit(self.allocator);
        try sorted.appendSlice(self.allocator, entries);
        std.mem.sort(IndexEntry, sorted.items, {}, struct {
            fn lt(_: void, a: IndexEntry, b: IndexEntry) bool {
                const pc = std.mem.order(u8, a.path, b.path);
                if (pc != .eq) return pc == .lt;
                return std.mem.order(u8, a.title, b.title) == .lt;
            }
        }.lt);

        // Collect every unique folder path (including parent segments).
        var folder_paths: std.ArrayList([]const u8) = .{};
        defer folder_paths.deinit(self.allocator);
        for (sorted.items) |e| {
            var path = e.path;
            while (path.len > 0) {
                var found = false;
                for (folder_paths.items) |p| {
                    if (std.mem.eql(u8, p, path)) {
                        found = true;
                        break;
                    }
                }
                if (!found) try folder_paths.append(self.allocator, path);
                if (std.mem.lastIndexOfScalar(u8, path, '/')) |idx| {
                    path = path[0..idx];
                } else break;
            }
        }

        // Always-present root row — represents the database root path "".
        try self.rows.append(self.allocator, .{
            .is_folder = true,
            .depth = 0,
            .label = try self.allocator.dupe(u8, "/"),
            .entry_id = null,
            .path = try self.allocator.dupe(u8, ""),
        });
        try self.buildRows(sorted.items, folder_paths.items, "", 1);

        // Re-apply filter if one is active (e.g. after saving an entry).
        if (self.filter.items.len > 0) {
            self.refilter();
            self.filter_cursor = 0;
            self.filter_scroll = 0;
            self.syncCursorFromFilter();
        }
    }

    /// Recursive DFS: emit folder rows then entry rows for `current_prefix`.
    fn buildRows(
        self: *Browser,
        entries: []const IndexEntry,
        folder_paths: []const []const u8,
        current_prefix: []const u8,
        depth: usize,
    ) !void {
        var children: std.ArrayList([]const u8) = .{};
        defer children.deinit(self.allocator);
        for (folder_paths) |fp| {
            if (isDirectChild(current_prefix, fp))
                try children.append(self.allocator, fp);
        }
        std.mem.sort([]const u8, children.items, {}, struct {
            fn lt(_: void, a: []const u8, b: []const u8) bool {
                return std.mem.order(u8, lastName(a), lastName(b)) == .lt;
            }
        }.lt);

        for (children.items) |fp| {
            try self.rows.append(self.allocator, .{
                .is_folder = true,
                .depth = depth,
                .label = try self.allocator.dupe(u8, lastName(fp)),
                .entry_id = null,
                .path = try self.allocator.dupe(u8, fp),
            });
            try self.buildRows(entries, folder_paths, fp, depth + 1);
        }

        for (entries) |e| {
            if (std.mem.eql(u8, e.path, current_prefix)) {
                try self.rows.append(self.allocator, .{
                    .is_folder = false,
                    .depth = depth,
                    .label = try self.allocator.dupe(u8, e.title),
                    .entry_id = e.entry_id,
                    .path = try self.allocator.dupe(u8, e.path),
                });
            }
        }
    }

    // -------------------------------------------------------------------------
    // Filter API (called by MainScreen)
    // -------------------------------------------------------------------------

    /// Returns true when a non-empty filter is active.
    pub fn isFiltered(self: *const Browser) bool {
        return self.filter.items.len > 0;
    }

    /// Copy `query` into the browser and recompute the match list.
    /// Called by MainScreen on every search keystroke.
    pub fn setFilter(self: *Browser, query: []const u8) void {
        self.filter.clearRetainingCapacity();
        self.filter.appendSlice(self.allocator, query) catch {};
        self.refilter();
        self.filter_cursor = 0;
        self.filter_scroll = 0;
        self.syncCursorFromFilter();
    }

    /// Remove the filter and restore normal (unfiltered) navigation.
    /// Called by MainScreen when the search pane is closed.
    pub fn clearFilter(self: *Browser) void {
        self.filter.clearRetainingCapacity();
        self.filtered_indices.clearRetainingCapacity();
        self.filter_cursor = 0;
        self.filter_scroll = 0;
    }

    /// Recompute `filtered_indices` from the current filter string.
    fn refilter(self: *Browser) void {
        self.filtered_indices.clearRetainingCapacity();
        const query = self.filter.items;
        if (query.len == 0) return;

        // Lower-case the query once, using a stack buffer.
        var lq_buf: [256]u8 = undefined;
        const lq_len = @min(query.len, lq_buf.len);
        for (query[0..lq_len], 0..) |c, i| lq_buf[i] = std.ascii.toLower(c);
        const lower_q = lq_buf[0..lq_len];

        for (self.rows.items, 0..) |*row, i| {
            var key_buf: [512]u8 = undefined;
            const key = buildSearchKey(&key_buf, row);
            var lk_buf: [512]u8 = undefined;
            const lk_len = @min(key.len, lk_buf.len);
            for (key[0..lk_len], 0..) |c, j| lk_buf[j] = std.ascii.toLower(c);
            const lower_k = lk_buf[0..lk_len];
            if (std.mem.indexOf(u8, lower_k, lower_q) != null)
                self.filtered_indices.append(self.allocator, i) catch {};
        }
    }

    /// Sync `cursor` (index into `rows`) from `filter_cursor` (position
    /// within `filtered_indices`).
    fn syncCursorFromFilter(self: *Browser) void {
        const matches = self.filtered_indices.items;
        if (matches.len == 0) return;
        const clamped = @min(self.filter_cursor, matches.len - 1);
        self.filter_cursor = clamped;
        self.cursor = matches[clamped];
    }

    // -------------------------------------------------------------------------
    // Input handling
    // -------------------------------------------------------------------------

    pub fn handleKey(self: *Browser, key: zz.KeyEvent) void {
        switch (key.key) {
            .char => |c| switch (c) {
                'j' => self.cursorDown(),
                'k' => self.cursorUp(),
                else => {},
            },
            .down => self.cursorDown(),
            .up => self.cursorUp(),
            else => {},
        }
    }

    fn cursorDown(self: *Browser) void {
        if (self.isFiltered()) {
            if (self.filtered_indices.items.len > 0 and
                self.filter_cursor + 1 < self.filtered_indices.items.len)
            {
                self.filter_cursor += 1;
                self.syncCursorFromFilter();
            }
        } else {
            if (self.rows.items.len > 0 and self.cursor + 1 < self.rows.items.len)
                self.cursor += 1;
        }
    }

    fn cursorUp(self: *Browser) void {
        if (self.isFiltered()) {
            if (self.filter_cursor > 0) {
                self.filter_cursor -= 1;
                self.syncCursorFromFilter();
            }
        } else {
            if (self.cursor > 0) self.cursor -= 1;
        }
    }

    /// The entry ID of the currently selected row, or null if on a folder.
    pub fn selectedEntryId(self: *const Browser) ?[20]u8 {
        if (self.cursor >= self.rows.items.len) return null;
        return self.rows.items[self.cursor].entry_id;
    }

    /// The path at the current cursor position.
    pub fn selectedPath(self: *const Browser) []const u8 {
        if (self.cursor >= self.rows.items.len) return "";
        return self.rows.items[self.cursor].path;
    }

    pub fn getHints(self: *const Browser) []const u8 {
        _ = self;
        return "j/k: nav  /: search  n: new  Tab: switch  q: quit";
    }

    // -------------------------------------------------------------------------
    // Rendering
    // -------------------------------------------------------------------------

    /// Render the browser pane into a styled box of `pane_width` × `pane_height`.
    pub fn view(
        self: *Browser,
        allocator: std.mem.Allocator,
        pane_width: u16,
        pane_height: u16,
        focused: bool,
    ) ![]const u8 {
        const content_w: u16 = pane_width -| 3; // 1 left-pad + 2 borders
        const content_h: u16 = pane_height -| 2; // top + bottom borders
        // One row is consumed by the "Entries" title.
        const visible: usize = if (content_h > 1) @as(usize, content_h) - 1 else 0;

        var buf: std.Io.Writer.Allocating = .init(allocator);
        defer buf.deinit();
        const w = &buf.writer;

        if (self.isFiltered()) {
            // Scroll filtered view to keep filter_cursor visible.
            if (self.filter_cursor < self.filter_scroll) {
                self.filter_scroll = self.filter_cursor;
            } else if (self.filtered_indices.items.len > 0 and
                self.filter_cursor >= self.filter_scroll + visible)
            {
                self.filter_scroll = if (visible > 0)
                    self.filter_cursor - visible + 1
                else
                    self.filter_cursor;
            }

            const end = @min(self.filter_scroll + visible, self.filtered_indices.items.len);
            for (self.filter_scroll..end) |mi| {
                if (mi > self.filter_scroll) try w.writeByte('\n');
                const i = self.filtered_indices.items[mi];
                try renderRow(w, allocator, &self.rows.items[i], i == self.cursor);
            }
        } else {
            // Scroll unfiltered view to keep cursor visible.
            if (self.cursor < self.scroll) {
                self.scroll = self.cursor;
            } else if (self.rows.items.len > 0 and self.cursor >= self.scroll + visible) {
                self.scroll = if (visible > 0) self.cursor - visible + 1 else self.cursor;
            }

            const end = @min(self.scroll + visible, self.rows.items.len);
            for (self.scroll..end) |i| {
                if (i > self.scroll) try w.writeByte('\n');
                try renderRow(w, allocator, &self.rows.items[i], i == self.cursor);
            }
        }

        // Title row: shows match count when filtered.
        var title_s = zz.Style{};
        title_s = title_s.bold(true).inline_style(true);
        const title_text = if (self.isFiltered())
            try std.fmt.allocPrint(allocator, "Entries ({d} match{s})", .{
                self.filtered_indices.items.len,
                if (self.filtered_indices.items.len == 1) "" else "es",
            })
        else
            try allocator.dupe(u8, "Entries");
        defer allocator.free(title_text);
        const title_line = try title_s.render(allocator, title_text);
        const content = try std.fmt.allocPrint(allocator, "{s}\n{s}", .{ title_line, buf.written() });

        const content_padded = try zz.placeVertical(allocator, content_h, .top, content);

        var box_s = zz.Style{};
        if (focused) {
            box_s = box_s.borderAll(zz.Border.double).borderForeground(zz.Color.cyan());
        } else {
            box_s = box_s.borderAll(zz.Border.rounded);
        }
        box_s = box_s.paddingLeft(1).width(content_w);
        return box_s.render(allocator, content_padded);
    }

    fn renderRow(
        w: *std.Io.Writer,
        allocator: std.mem.Allocator,
        row: *const Row,
        selected: bool,
    ) !void {
        var s = zz.Style{};
        s = s.inline_style(true);
        if (selected) {
            s = s.bold(true).fg(zz.Color.cyan());
        } else if (row.is_folder) {
            s = s.bold(true);
        }

        for (0..row.depth * 2) |_| try w.writeByte(' ');

        if (row.is_folder) {
            var icon_s = zz.Style{};
            icon_s = icon_s.fg(zz.Color.yellow()).inline_style(true);
            try w.writeAll(try icon_s.render(allocator, DIR_ICON));
            try w.writeAll(try s.render(allocator, row.label));
        } else {
            var icon_s = zz.Style{};
            icon_s = icon_s.fg(zz.Color.blue()).inline_style(true);
            try w.writeAll(try icon_s.render(allocator, ENTRY_ICON));
            try w.writeAll(try s.render(allocator, row.label));
        }
    }
};
