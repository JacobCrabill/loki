const std = @import("std");
const loki = @import("loki");
const zz = @import("zigzag");

const common = @import("../common.zig");
const Context = @import("../Context.zig");
const views = @import("../views.zig");
const search_mod = @import("search.zig");

const SEARCH_PANE_HEIGHT = search_mod.PANE_HEIGHT;

pub const Pane = enum { browser, search, viewer, conflict };

pub const MainScreen = struct {
    ctx: *Context,
    browser: views.Browser,
    viewer: views.Viewer,
    history: views.HistoryView,
    conflict_view: views.ConflictView,
    search: views.SearchPane,
    /// Whether the search pane is currently visible.
    search_open: bool,
    /// Number of unresolved conflicts (persists after conflict view is closed).
    pending_conflicts: usize,
    active_pane: Pane,

    pub fn create(pa: std.mem.Allocator, ctx: *Context) !MainScreen {
        var screen = MainScreen{
            .ctx = ctx,
            .browser = views.Browser.init(pa),
            .viewer = views.Viewer.init(pa),
            .history = views.HistoryView.init(pa),
            .conflict_view = views.ConflictView.init(pa),
            .search = views.SearchPane.init(pa),
            .search_open = false,
            .pending_conflicts = 0,
            .active_pane = .browser,
        };

        var db: *loki.Database = try ctx.getDb();
        try screen.browser.populate(db.listEntries());
        if (screen.browser.selectedEntryId()) |eid| {
            const head_hash = common.findHeadHash(db.listEntries(), eid);
            const entry = db.getEntry(eid) catch null;
            screen.viewer.setEntry(eid, head_hash, entry);
        }

        // Load any pending conflicts saved by a previous `loki sync`.
        const conflicts = db.loadConflicts(pa) catch &.{};
        defer pa.free(conflicts);
        if (conflicts.len > 0) {
            screen.conflict_view.load(db, conflicts);
            screen.pending_conflicts = conflicts.len;
            screen.active_pane = .conflict;
        }

        return screen;
    }

    pub fn deinit(self: *MainScreen) void {
        self.search.deinit();
        self.conflict_view.deinit();
        self.history.deinit();
        self.viewer.deinit();
        self.browser.deinit();
    }

    pub fn view(
        self: *MainScreen,
        allocator: std.mem.Allocator,
        term_width: u16,
        term_height: u16,
    ) ![]const u8 {
        // Reserve 2 rows for the hints line and the status line; panes fill the rest.
        const pane_height: u16 = if (term_height > 2) term_height - 2 else 1;

        // Conflict view takes the full width.
        if (self.active_pane == .conflict) {
            const conflict_raw = try self.conflict_view.view(allocator, term_width, pane_height);
            const conflict_padded = try zz.placeVertical(allocator, pane_height, .top, conflict_raw);

            var hints_buf: std.Io.Writer.Allocating = .init(allocator);
            defer hints_buf.deinit();
            const hb = &hints_buf.writer;
            try hb.writeByte(' ');
            try hb.writeAll(try renderHints(allocator, self.conflict_view.getHints()));

            var db_s = zz.Style{};
            db_s = db_s.bold(true).fg(zz.Color.brightBlue()).inline_style(true);
            var dim_s = zz.Style{};
            dim_s = dim_s.dim(true).inline_style(true);
            var status_buf: std.Io.Writer.Allocating = .init(allocator);
            defer status_buf.deinit();
            const sb = &status_buf.writer;
            try sb.writeByte(' ');
            try sb.writeAll(try db_s.render(allocator, self.ctx.db_path));
            try sb.writeAll(try dim_s.render(allocator, "  [conflict]"));
            return std.fmt.allocPrint(allocator, "{s}\n{s}\n{s}", .{ conflict_padded, hints_buf.written(), status_buf.written() });
        }

        const browser_width: u16 = @max(20, term_width / 3);
        const viewer_width: u16 = term_width -| browser_width;

        // When search is open, the browser is shorter to leave room for the
        // search pane below it.  The viewer always uses the full pane height.
        const browser_pane_h: u16 = if (self.search_open)
            pane_height -| SEARCH_PANE_HEIGHT
        else
            pane_height;

        // Left column: browser (possibly history mode) + optional search pane.
        const browser_raw = if (self.history.active)
            try self.history.view(allocator, browser_width, browser_pane_h, true)
        else
            try self.browser.view(allocator, browser_width, browser_pane_h, self.active_pane == .browser);

        const left_raw = if (self.search_open) blk: {
            const search_raw = try self.search.view(allocator, browser_width, self.active_pane == .search);
            break :blk try std.fmt.allocPrint(allocator, "{s}\n{s}", .{ browser_raw, search_raw });
        } else browser_raw;

        // Right column: viewer.  Focused only when not in history mode.
        const viewer_raw = try self.viewer.view(
            allocator,
            viewer_width,
            pane_height,
            !self.history.active and self.active_pane == .viewer,
        );

        // Pad both columns to exactly pane_height rows before joining.
        const left_padded = try zz.placeVertical(allocator, pane_height, .top, left_raw);
        const viewer_padded = try zz.placeVertical(allocator, pane_height, .top, viewer_raw);
        const panes = try zz.joinHorizontal(allocator, &.{ left_padded, viewer_padded });

        const pane_label: []const u8 = switch (self.active_pane) {
            .browser => "[browser]",
            .search => "[search]",
            .viewer => "[viewer]",
            .conflict => unreachable,
        };

        // Conflict banner.
        const conflict_banner: []const u8 = if (self.pending_conflicts > 0) blk: {
            var s = zz.Style{};
            s = s.fg(zz.Color.yellow()).bold(true);
            const text = try std.fmt.allocPrint(
                allocator,
                "[{d} conflict(s) — press C]",
                .{self.pending_conflicts},
            );
            defer allocator.free(text);
            break :blk try s.render(allocator, text);
        } else "";

        const hints: []const u8 = if (self.history.active)
            self.history.getHints()
        else switch (self.active_pane) {
            .browser => self.browser.getHints(),
            .search => self.search.getHints(),
            .viewer => self.viewer.getHints(),
            .conflict => unreachable,
        };

        const full_hints = if (self.pending_conflicts > 0)
            try std.fmt.allocPrint(allocator, "{s}  C: conflicts", .{hints})
        else
            try allocator.dupe(u8, hints);
        defer allocator.free(full_hints);

        var hints_buf: std.Io.Writer.Allocating = .init(allocator);
        defer hints_buf.deinit();
        const hb = &hints_buf.writer;
        try hb.writeByte(' ');
        try hb.writeAll(try renderHints(allocator, full_hints));

        var db_s = zz.Style{};
        db_s = db_s.bold(true).fg(zz.Color.brightBlue()).inline_style(true);
        var dim_s = zz.Style{};
        dim_s = dim_s.dim(true).inline_style(true);

        var status_buf: std.Io.Writer.Allocating = .init(allocator);
        defer status_buf.deinit();
        const sb = &status_buf.writer;

        try sb.writeByte(' ');
        try sb.writeAll(try db_s.render(allocator, self.ctx.db_path));
        try sb.writeAll(try dim_s.render(allocator, "  "));
        if (self.pending_conflicts > 0) {
            try sb.writeAll(conflict_banner);
            try sb.writeAll(try dim_s.render(allocator, "  "));
        }
        try sb.writeAll(try dim_s.render(allocator, pane_label));
        if (self.viewer.isModified()) {
            var mod_s = zz.Style{};
            mod_s = mod_s.fg(zz.Color.yellow()).inline_style(true);
            try sb.writeAll(try mod_s.render(allocator, " [modified]"));
        }

        return std.fmt.allocPrint(allocator, "{s}\n{s}\n{s}", .{ panes, hints_buf.written(), status_buf.written() });
    }

    pub fn handleKey(self: *MainScreen, k: zz.KeyEvent, pa: std.mem.Allocator) common.Cmd {
        const db = self.ctx.getDb() catch return .none;

        // Conflict view intercepts all keys when active.
        if (self.active_pane == .conflict) {
            const sig = self.conflict_view.handleKey(k, db);
            switch (sig) {
                .none => {},
                .closed => {
                    self.pending_conflicts = self.conflict_view.pending.items.len;
                    if (self.pending_conflicts > 0) {
                        db.saveConflicts(self.conflict_view.pending.items) catch {};
                    } else {
                        db.clearConflicts();
                    }
                    self.active_pane = .browser;
                },
                .all_resolved => {
                    self.pending_conflicts = 0;
                    db.clearConflicts();
                    self.browser.populate(db.listEntries()) catch {};
                    self.active_pane = .browser;
                    if (self.browser.selectedEntryId()) |eid| {
                        const head_hash = common.findHeadHash(db.listEntries(), eid);
                        const entry = db.getEntry(eid) catch null;
                        self.viewer.setEntry(eid, head_hash, entry);
                    }
                },
            }
            return .none;
        }

        // History mode intercepts all keys.
        if (self.history.active) {
            const sig = self.history.handleKey(k, db);
            switch (sig) {
                .none => {
                    if (self.history.takePreview()) |preview| {
                        self.viewer.setEntry(self.history.entry_id, self.history.selectedHash(), preview);
                    }
                },
                .closed => {
                    const eid = self.history.entry_id;
                    const head_hash = common.findHeadHash(db.listEntries(), eid);
                    const entry = db.getEntry(eid) catch null;
                    self.viewer.setEntry(eid, head_hash, entry);
                    self.active_pane = .viewer;
                },
                .restored => {
                    const eid = self.history.entry_id;
                    self.browser.populate(db.listEntries()) catch {};
                    const head_hash = common.findHeadHash(db.listEntries(), eid);
                    const entry = db.getEntry(eid) catch null;
                    self.viewer.setEntry(eid, head_hash, entry);
                    self.active_pane = .viewer;
                },
            }
            return .none;
        }

        // Tab: cycle panes.
        // When search is open the cycle is: search → browser → viewer → search.
        // When search is closed: browser ↔ viewer.
        if (k.key == .tab) {
            if (self.search_open) {
                // Leave edit mode when tabbing away from viewer.
                if (self.active_pane == .viewer and self.viewer.isEditing())
                    self.viewer.leaveEditMode();
                const next: Pane = switch (self.active_pane) {
                    .search => .browser,
                    .browser => .viewer,
                    .viewer => .search,
                    .conflict => .browser,
                };
                self.active_pane = next;
                // Keep the search input focused iff the search pane has focus.
                if (next == .search) self.search.focus() else self.search.blur();
            } else {
                if (self.viewer.isEditing()) self.viewer.leaveEditMode();
                self.active_pane = if (self.active_pane == .browser) .viewer else .browser;
            }
            return .none;
        }

        // Open search via '/' or Ctrl+F from any pane (except while editing).
        if (!self.history.active) {
            const viewer_editing = self.active_pane == .viewer and self.viewer.isEditing();
            if (!viewer_editing) {
                const open_search = (k.key == .char and k.key.char == '/') or
                    (k.modifiers.ctrl and k.key == .char and k.key.char == 'f');
                if (open_search) {
                    self.search_open = true;
                    self.search.focus();
                    self.active_pane = .search;
                    return .none;
                }
            }
        }

        switch (self.active_pane) {
            .conflict => unreachable,

            .browser => {
                switch (k.key) {
                    .char => |c| switch (c) {
                        'q' => if (!self.viewer.isModified()) return .quit,
                        'n' => {
                            self.viewer.setNewEntry(self.browser.selectedPath());
                            self.active_pane = .viewer;
                            return .none;
                        },
                        'C' => if (self.pending_conflicts > 0) {
                            self.active_pane = .conflict;
                            return .none;
                        },
                        else => self.browser.handleKey(k),
                    },
                    else => self.browser.handleKey(k),
                }

                // Sync viewer to new selection.
                if (!self.viewer.isModified()) {
                    if (self.browser.selectedEntryId()) |eid| {
                        const head_hash = common.findHeadHash(db.listEntries(), eid);
                        const entry = db.getEntry(eid) catch null;
                        self.viewer.setEntry(eid, head_hash, entry);
                    } else {
                        self.viewer.setEntry(null, null, null);
                    }
                }
            },

            .search => {
                const sig = self.search.handleKey(k);

                // Push the updated query to the browser on every keystroke.
                self.browser.setFilter(self.search.getQuery());

                // Sync viewer to whatever the browser now selects.
                if (!self.viewer.isModified()) {
                    if (self.browser.selectedEntryId()) |eid| {
                        const head_hash = common.findHeadHash(db.listEntries(), eid);
                        const entry = db.getEntry(eid) catch null;
                        self.viewer.setEntry(eid, head_hash, entry);
                    } else {
                        self.viewer.setEntry(null, null, null);
                    }
                }

                // Esc closes the search pane and clears the filter.
                if (sig == .dismissed) {
                    self.search.close();
                    self.browser.clearFilter();
                    self.search_open = false;
                    self.active_pane = .browser;
                }
            },

            .viewer => {
                if (k.key == .char and k.key.char == 'C' and self.pending_conflicts > 0) {
                    self.active_pane = .conflict;
                    return .none;
                }
                const sig = self.viewer.handleKey(k);
                switch (sig) {
                    .none => {},
                    .save => self.saveEntry(pa),
                    .show_history => {
                        if (self.viewer.entry_id) |eid| {
                            if (self.viewer.head_hash) |hh| {
                                self.history.show(db, eid, hh) catch {};
                            }
                        }
                    },
                    .quit => return .quit,
                }
            },
        }

        return .none;
    }

    /// Render a hint string with cyan keys and dimmed descriptions.
    fn renderHints(allocator: std.mem.Allocator, hints: []const u8) ![]const u8 {
        var buf: std.Io.Writer.Allocating = .init(allocator);
        defer buf.deinit();
        const w = &buf.writer;

        var key_s = zz.Style{};
        key_s = key_s.fg(zz.Color.cyan()).inline_style(true);
        var dim_s = zz.Style{};
        dim_s = dim_s.dim(true).inline_style(true);

        var first = true;
        var pairs = std.mem.splitSequence(u8, hints, "  ");
        while (pairs.next()) |pair| {
            if (pair.len == 0) continue;
            if (!first) try w.writeAll(try dim_s.render(allocator, "  "));
            first = false;

            if (std.mem.indexOf(u8, pair, ": ")) |ci| {
                try w.writeAll(try key_s.render(allocator, pair[0..ci]));
                try w.writeAll(try dim_s.render(allocator, ": "));
                try w.writeAll(try dim_s.render(allocator, pair[ci + 2 ..]));
            } else {
                try w.writeAll(try dim_s.render(allocator, pair));
            }
        }
        return allocator.dupe(u8, buf.written());
    }

    fn saveEntry(m: *MainScreen, pa: std.mem.Allocator) void {
        const entry = m.viewer.buildEntry() catch return;
        defer entry.deinit(pa);

        const db: *loki.Database = m.ctx.getDb() catch @panic("Database not initialized!");
        if (m.viewer.is_new) {
            if (entry.title.len == 0) return;
            const eid = db.createEntry(entry) catch return;
            db.save() catch {};
            m.browser.populate(db.listEntries()) catch {};
            const loaded = db.getEntry(eid) catch null;
            m.viewer.setEntry(eid, eid, loaded);
        } else if (m.viewer.entry_id) |eid| {
            const new_hash = db.updateEntry(eid, entry) catch return;
            db.save() catch {};
            m.browser.populate(db.listEntries()) catch {};
            const loaded = db.getEntry(eid) catch null;
            m.viewer.setEntry(eid, new_hash, loaded);
        }
    }
};
