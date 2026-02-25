const std = @import("std");
const zz = @import("zigzag");
const IndexEntry = @import("../store/index.zig").IndexEntry;

const ENTRY_ICON = "󰂺 ";

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
/// A direct child has exactly one more path segment than `parent`.
fn isDirectChild(parent: []const u8, child: []const u8) bool {
    if (parent.len == 0) {
        // Root children: non-empty paths with no '/'.
        return child.len > 0 and std.mem.indexOf(u8, child, "/") == null;
    }
    // child must be "parent/something" where "something" has no '/'.
    if (child.len <= parent.len + 1) return false;
    if (!std.mem.startsWith(u8, child, parent)) return false;
    if (child[parent.len] != '/') return false;
    const rest = child[parent.len + 1 ..];
    return std.mem.indexOf(u8, rest, "/") == null;
}

// ---------------------------------------------------------------------------
// Browser
// ---------------------------------------------------------------------------

/// Left pane: hierarchical file-browser built from entry paths.
pub const Browser = struct {
    allocator: std.mem.Allocator,
    rows: std.ArrayList(Row),
    cursor: usize,
    scroll: usize,

    pub fn init(allocator: std.mem.Allocator) Browser {
        return .{
            .allocator = allocator,
            .rows = .{},
            .cursor = 0,
            .scroll = 0,
        };
    }

    pub fn deinit(self: *Browser) void {
        for (self.rows.items) |row| row.deinit(self.allocator);
        self.rows.deinit(self.allocator);
    }

    /// Rebuild the tree from a fresh list of index entries.
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
        // All folders and entries live under "/" at depth 1+.
        try self.buildRows(sorted.items, folder_paths.items, "", 1);
    }

    /// Recursive DFS: emit folder rows, then entry rows for `current_prefix`.
    fn buildRows(
        self: *Browser,
        entries: []const IndexEntry,
        folder_paths: []const []const u8,
        current_prefix: []const u8,
        depth: usize,
    ) !void {
        // Find and sort direct child folders.
        var children: std.ArrayList([]const u8) = .{};
        defer children.deinit(self.allocator);
        for (folder_paths) |fp| {
            if (isDirectChild(current_prefix, fp)) {
                try children.append(self.allocator, fp);
            }
        }
        std.mem.sort([]const u8, children.items, {}, struct {
            fn lt(_: void, a: []const u8, b: []const u8) bool {
                return std.mem.order(u8, lastName(a), lastName(b)) == .lt;
            }
        }.lt);

        // Emit each child folder then recurse.
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

        // Emit entries that live directly at this level.
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
        if (self.rows.items.len > 0 and self.cursor + 1 < self.rows.items.len)
            self.cursor += 1;
    }

    fn cursorUp(self: *Browser) void {
        if (self.cursor > 0) self.cursor -= 1;
    }

    /// The entry ID of the currently selected row, or null if on a folder.
    pub fn selectedEntryId(self: *const Browser) ?[20]u8 {
        if (self.cursor >= self.rows.items.len) return null;
        return self.rows.items[self.cursor].entry_id;
    }

    /// The path at the current cursor position (folder path or entry's path).
    /// Useful for pre-populating the Path field when creating a new entry.
    pub fn selectedPath(self: *const Browser) []const u8 {
        if (self.cursor >= self.rows.items.len) return "";
        return self.rows.items[self.cursor].path;
    }

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
        // One line is consumed by the "Entries" title row.
        const visible: usize = if (content_h > 1) @as(usize, content_h) - 1 else 1;

        // Scroll to keep cursor in view.
        if (self.cursor < self.scroll) {
            self.scroll = self.cursor;
        } else if (self.rows.items.len > 0 and self.cursor >= self.scroll + visible) {
            self.scroll = self.cursor - visible + 1;
        }

        var buf: std.ArrayList(u8) = .{};
        defer buf.deinit(allocator);
        const w = buf.writer(allocator);

        const end = @min(self.scroll + visible, self.rows.items.len);
        for (self.scroll..end) |i| {
            if (i > self.scroll) try w.writeByte('\n');
            const row = self.rows.items[i];
            const selected = i == self.cursor;

            // Base style for this row.
            var s = zz.Style{};
            s = s.inline_style(true);
            if (selected) {
                s = s.bold(true);
                s = s.fg(zz.Color.cyan());
            } else if (row.is_folder) {
                s = s.bold(true);
            }

            // Indentation (2 spaces per depth level).
            for (0..row.depth * 2) |_| try w.writeByte(' ');

            if (row.is_folder) {
                try w.writeAll(try s.render(allocator, row.label));
            } else {
                const text = try std.fmt.allocPrint(
                    allocator,
                    ENTRY_ICON ++ "{s}",
                    .{row.label},
                );
                try w.writeAll(try s.render(allocator, text));
            }
        }

        // Prepend the styled title row.
        var title_s = zz.Style{};
        title_s = title_s.bold(true);
        title_s = title_s.inline_style(true);
        const title_line = try title_s.render(allocator, "Entries");
        const content = try std.fmt.allocPrint(allocator, "{s}\n{s}", .{ title_line, buf.items });

        var box_s = zz.Style{};
        box_s = box_s.borderAll(zz.Border.rounded);
        if (focused) box_s = box_s.borderForeground(zz.Color.cyan());
        box_s = box_s.paddingLeft(1);
        box_s = box_s.width(content_w);
        box_s = box_s.height(content_h);
        return box_s.render(allocator, content);
    }
};
