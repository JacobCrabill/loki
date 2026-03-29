const std = @import("std");
const loki = @import("loki");
const zz = @import("zigzag");

const common = @import("../common.zig");
const Context = @import("../Context.zig");
const views = @import("../views.zig");

pub const Pane = enum { browser, viewer, conflict };

pub const MainScreen = struct {
    ctx: *Context,
    browser: views.Browser,
    viewer: views.Viewer,
    history: views.HistoryView,
    conflict_view: views.ConflictView,
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

            // Hints row (directly above the status row).
            var hints_buf: std.Io.Writer.Allocating = .init(allocator);
            defer hints_buf.deinit();
            const hb = &hints_buf.writer;
            try hb.writeByte(' ');
            try hb.writeAll(try renderHints(allocator, self.conflict_view.getHints()));

            // Status row (bottom line).
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

        // When in history mode, show history list as the left pane.
        const left_raw = if (self.history.active)
            try self.history.view(allocator, browser_width, pane_height, true)
        else
            try self.browser.view(allocator, browser_width, pane_height, self.active_pane == .browser);
        // Viewer shows focused=false while in history mode (history has focus).
        const viewer_raw = try self.viewer.view(allocator, viewer_width, pane_height, !self.history.active and self.active_pane == .viewer);

        // Pad each pane to exactly pane_height rows. The zigzag style renderer
        // silently discards the height() constraint, so without this the panes
        // can be shorter than the terminal and the status line floats up.
        const left_padded = try zz.placeVertical(allocator, pane_height, .top, left_raw);
        const viewer_padded = try zz.placeVertical(allocator, pane_height, .top, viewer_raw);
        const panes = try zz.joinHorizontal(allocator, &.{ left_padded, viewer_padded });

        const pane_label: []const u8 = if (self.active_pane == .browser) "[browser]" else "[viewer]";

        // Conflict banner: shown when conflicts are pending but view is closed.
        const conflict_banner: []const u8 = if (self.pending_conflicts > 0) blk: {
            var s = zz.Style{};
            s = s.fg(zz.Color.yellow());
            s = s.bold(true);
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
            .viewer => self.viewer.getHints(),
            .conflict => unreachable, // handled above
        };

        // Append "C: conflicts" to hints when conflicts are pending.
        const full_hints = if (self.pending_conflicts > 0)
            try std.fmt.allocPrint(allocator, "{s}  C: conflicts", .{hints})
        else
            try allocator.dupe(u8, hints);
        defer allocator.free(full_hints);

        // Hints row (directly above the status row).
        var hints_buf: std.Io.Writer.Allocating = .init(allocator);
        defer hints_buf.deinit();
        const hb = &hints_buf.writer;
        try hb.writeByte(' ');
        try hb.writeAll(try renderHints(allocator, full_hints));

        // Status row (bottom line): db name, conflict banner, pane label, modified.
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
        const db = self.ctx.getDb() catch return .none; // TODO: set_view unlock?

        // Conflict view intercepts all keys when active.
        if (self.active_pane == .conflict) {
            const sig = self.conflict_view.handleKey(k, db);
            switch (sig) {
                .none => {},
                .closed => {
                    // User deferred: keep banner, return to browser.
                    self.pending_conflicts = self.conflict_view.pending.items.len;
                    // Save remaining conflicts back to disk so they survive restarts.
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
                    // Reload viewer for currently selected entry.
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
                    // Navigation: take preview and update viewer.
                    if (self.history.takePreview()) |preview| {
                        self.viewer.setEntry(self.history.entry_id, self.history.selectedHash(), preview);
                    }
                },
                .closed => {
                    // Reload the current HEAD version into viewer.
                    const eid = self.history.entry_id;
                    const head_hash = common.findHeadHash(db.listEntries(), eid);
                    const entry = db.getEntry(eid) catch null;
                    self.viewer.setEntry(eid, head_hash, entry);
                    self.active_pane = .viewer;
                },
                .restored => {
                    // Entry was restored: repopulate browser, reload from db.
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

        // Tab always switches panes (and exits edit mode first).
        if (k.key == .tab) {
            if (self.viewer.isEditing()) self.viewer.leaveEditMode();
            self.active_pane = if (self.active_pane == .browser) .viewer else .browser;
            return .none;
        }

        switch (self.active_pane) {
            .conflict => unreachable, // handled above
            .browser => {
                switch (k.key) {
                    .char => |c| switch (c) {
                        'q' => if (!self.viewer.isModified()) return .quit,
                        'n' => {
                            self.viewer.setNewEntry(self.browser.selectedPath());
                            self.active_pane = .viewer;
                            return .none; // key consumed; do not pass to viewer
                        },
                        'C' => if (self.pending_conflicts > 0) {
                            self.active_pane = .conflict;
                            return .none;
                        },
                        else => self.browser.handleKey(k),
                    },
                    else => self.browser.handleKey(k),
                }
                // Update viewer when browser selection changes (no unsaved edits).
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
            .viewer => {
                // C re-enters conflict view when pending conflicts exist.
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

    /// Render a hint string of the form "key: action  key: action  …" with keys
    /// highlighted in cyan and action descriptions dimmed.  Pairs are separated by
    /// two consecutive spaces; the key and action within each pair are separated by
    /// ": ".
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
            // Require at least a non-empty title.
            if (entry.title.len == 0) return;
            const eid = db.createEntry(entry) catch return;
            db.save() catch {};
            m.browser.populate(db.listEntries()) catch {};
            // head_hash == entry_id for a genesis entry.
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
