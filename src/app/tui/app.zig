const std = @import("std");
const zz = @import("zigzag");
const loki = @import("loki");
const theme = @import("theme.zig");

const common = @import("common.zig");
const Context = @import("Context.zig");
const views = @import("views.zig");

const IndexEntry = loki.store.index.IndexEntry;
const Database = loki.Database;
const ConflictEntry = loki.model.merge.ConflictEntry;

const Browser = views.Browser;
const Viewer = views.Viewer;
const HistoryView = views.HistoryView;
const ConflictView = views.ConflictView;

// =============================================================================
// Internal types
// =============================================================================

const Pane = enum { browser, viewer, conflict };

const UnlockScreen = struct {
    input: zz.TextInput,
    error_msg: ?[]const u8,

    fn deinit(self: *UnlockScreen) void {
        self.input.deinit();
    }
};

const CreateStage = enum {
    /// Entering the new password.
    password,
    /// Confirming the new password.
    confirm,
    /// Yes/no prompt before actually creating.
    confirming,
};

const MainScreen = struct {
    ctx: *Context,
    browser: Browser,
    viewer: Viewer,
    history: HistoryView,
    conflict_view: ConflictView,
    /// Number of unresolved conflicts (persists after conflict view is closed).
    pending_conflicts: usize,
    active_pane: Pane,

    fn deinit(self: *MainScreen) void {
        self.conflict_view.deinit();
        self.history.deinit();
        self.viewer.deinit();
        self.browser.deinit();
    }
};

const Screen = union(enum) {
    unlock: UnlockScreen,
    create: views.CreateScreen,
    main: MainScreen,
};

// =============================================================================
// Helpers
// =============================================================================

const DbState = enum { not_found, plaintext, encrypted };

fn detectDbState(db_path: []const u8) DbState {
    var dir = std.fs.cwd().openDir(db_path, .{}) catch return .not_found;
    defer dir.close();
    const f = dir.openFile("header", .{}) catch |err| {
        if (err == error.FileNotFound) return .plaintext;
        return .plaintext;
    };
    f.close();
    return .encrypted;
}

fn makeMainScreen(pa: std.mem.Allocator, ctx: *Context) !MainScreen {
    var screen = MainScreen{
        .ctx = ctx,
        .browser = Browser.init(pa),
        .viewer = Viewer.init(pa),
        .history = HistoryView.init(pa),
        .conflict_view = ConflictView.init(pa),
        .pending_conflicts = 0,
        .active_pane = .browser,
    };
    var db: *loki.Database = try ctx.getDb();
    try screen.browser.populate(db.listEntries());
    if (screen.browser.selectedEntryId()) |eid| {
        const head_hash = findHeadHash(db.listEntries(), eid);
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

fn findHeadHash(entries: []const IndexEntry, entry_id: [20]u8) ?[20]u8 {
    for (entries) |ie| {
        if (std.mem.eql(u8, &ie.entry_id, &entry_id)) return ie.head_hash;
    }
    return null;
}

fn makeUnlockScreen(pa: std.mem.Allocator, err_msg: ?[]const u8) UnlockScreen {
    var input = zz.TextInput.init(pa);
    input.setEchoMode(.password);
    input.setPrompt("Password: ");
    return .{ .input = input, .error_msg = err_msg };
}

fn makeCreateScreen(pa: std.mem.Allocator) views.create.CreateScreen {
    var pw = zz.TextInput.init(pa);
    pw.setEchoMode(.password);
    pw.setPrompt("New password: ");
    pw.prompt_style = pw.prompt_style.foreground_color(zz.Color.cyan());
    var confirm = zz.TextInput.init(pa);
    confirm.setEchoMode(.password);
    confirm.setPrompt("Confirm:      ");
    confirm.prompt_style = confirm.prompt_style.foreground_color(zz.Color.cyan());
    confirm.focused = false;
    return .{
        .pw_input = pw,
        .confirm_input = confirm,
        .stage = .password,
        .error_msg = null,
    };
}

fn createDb(pa: std.mem.Allocator, db_path: []const u8, password: ?[]const u8) !Database {
    const dirname = std.fs.path.dirname(db_path) orelse ".";
    const basename = std.fs.path.basename(db_path);
    var base_dir = try std.fs.cwd().openDir(dirname, .{});
    defer base_dir.close();
    return Database.create(pa, base_dir, basename, password);
}

// =============================================================================
// Views
// =============================================================================

fn viewUnlock(
    u: *const UnlockScreen,
    allocator: std.mem.Allocator,
    term_width: u16,
    term_height: u16,
) ![]const u8 {
    var buf: std.Io.Writer.Allocating = .init(allocator);
    defer buf.deinit();
    const w = &buf.writer;

    var title_s = zz.Style{};
    title_s = title_s.bold(true);
    try w.writeAll(try title_s.render(allocator, "Loki"));
    try w.writeAll("\n\n");

    const input_str = try u.input.view(allocator);
    try w.writeAll(input_str);
    if (u.error_msg) |emsg| {
        try w.writeByte('\n');
        var err_s = zz.Style{};
        err_s = err_s.fg(zz.Color.red());
        try w.writeAll(try err_s.render(allocator, emsg));
    }
    try w.writeAll("\n\nEnter: unlock   Esc: quit");

    var box_s = zz.Style{};
    box_s = box_s.borderAll(zz.Border.rounded);
    box_s = box_s.paddingAll(1);
    const box = try box_s.render(allocator, buf.written());

    // Render the ASCII-art banner in our theme's blue, then stack it above
    // the dialog box (centered horizontally) with a blank line between them.
    var art_s = zz.Style{};
    art_s = art_s.fg(zz.Color.blue()).bold(true).width(common.loki_art_len); // width of ascii art
    const styled_art = try art_s.render(allocator, common.loki_art);
    const combined = try zz.join.vertical(allocator, .center, &.{ styled_art, "", box });

    return zz.place.place(allocator, term_width, term_height, .center, .middle, combined);
}

/// Clip each line of `str` to `max_width` visual columns (ANSI-aware).
/// Lines wider than `max_width` get truncated with "…" via zz.measure.truncate.
fn clipLines(allocator: std.mem.Allocator, str: []const u8, max_width: usize) ![]const u8 {
    var out: std.ArrayList(u8) = .{};
    defer out.deinit(allocator);
    var lines = std.mem.splitScalar(u8, str, '\n');
    var first = true;
    while (lines.next()) |line| {
        if (!first) try out.append(allocator, '\n');
        first = false;
        if (zz.measure.width(line) > max_width) {
            const clipped = try zz.measure.truncate(allocator, line, max_width);
            defer allocator.free(clipped);
            try out.appendSlice(allocator, clipped);
        } else {
            try out.appendSlice(allocator, line);
        }
    }
    return out.toOwnedSlice(allocator);
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

fn viewMain(
    m: *MainScreen,
    allocator: std.mem.Allocator,
    term_width: u16,
    term_height: u16,
) ![]const u8 {
    // Reserve 2 rows for the hints line and the status line; panes fill the rest.
    const pane_height: u16 = if (term_height > 2) term_height - 2 else 1;

    // Conflict view takes the full width.
    if (m.active_pane == .conflict) {
        const conflict_raw = try m.conflict_view.view(allocator, term_width, pane_height);
        const conflict_padded = try zz.placeVertical(allocator, pane_height, .top, conflict_raw);

        // Hints row (directly above the status row).
        var hints_buf: std.Io.Writer.Allocating = .init(allocator);
        defer hints_buf.deinit();
        const hb = &hints_buf.writer;
        try hb.writeByte(' ');
        try hb.writeAll(try renderHints(allocator, m.conflict_view.getHints()));

        // Status row (bottom line).
        var db_s = zz.Style{};
        db_s = db_s.bold(true).fg(zz.Color.brightBlue()).inline_style(true);
        var dim_s = zz.Style{};
        dim_s = dim_s.dim(true).inline_style(true);
        var status_buf: std.Io.Writer.Allocating = .init(allocator);
        defer status_buf.deinit();
        const sb = &status_buf.writer;
        try sb.writeByte(' ');
        try sb.writeAll(try db_s.render(allocator, m.ctx.db_path));
        try sb.writeAll(try dim_s.render(allocator, "  [conflict]"));
        return std.fmt.allocPrint(allocator, "{s}\n{s}\n{s}", .{ conflict_padded, hints_buf.written(), status_buf.written() });
    }

    const browser_width: u16 = @max(20, term_width / 3);
    const viewer_width: u16 = term_width -| browser_width;

    // When in history mode, show history list as the left pane.
    const left_raw = if (m.history.active)
        try m.history.view(allocator, browser_width, pane_height, true)
    else
        try m.browser.view(allocator, browser_width, pane_height, m.active_pane == .browser);
    // Viewer shows focused=false while in history mode (history has focus).
    const viewer_raw = try m.viewer.view(allocator, viewer_width, pane_height, !m.history.active and m.active_pane == .viewer);

    // Pad each pane to exactly pane_height rows. The zigzag style renderer
    // silently discards the height() constraint, so without this the panes
    // can be shorter than the terminal and the status line floats up.
    const left_padded = try zz.placeVertical(allocator, pane_height, .top, left_raw);
    const viewer_padded = try zz.placeVertical(allocator, pane_height, .top, viewer_raw);
    const panes = try zz.joinHorizontal(allocator, &.{ left_padded, viewer_padded });

    const pane_label: []const u8 = if (m.active_pane == .browser) "[browser]" else "[viewer]";

    // Conflict banner: shown when conflicts are pending but view is closed.
    const conflict_banner: []const u8 = if (m.pending_conflicts > 0) blk: {
        var s = zz.Style{};
        s = s.fg(zz.Color.yellow());
        s = s.bold(true);
        const text = try std.fmt.allocPrint(
            allocator,
            "[{d} conflict(s) — press C]",
            .{m.pending_conflicts},
        );
        defer allocator.free(text);
        break :blk try s.render(allocator, text);
    } else "";

    const hints: []const u8 = if (m.history.active)
        m.history.getHints()
    else switch (m.active_pane) {
        .browser => m.browser.getHints(),
        .viewer => m.viewer.getHints(),
        .conflict => unreachable, // handled above
    };

    // Append "C: conflicts" to hints when conflicts are pending.
    const full_hints = if (m.pending_conflicts > 0)
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
    try sb.writeAll(try db_s.render(allocator, m.ctx.db_path));
    try sb.writeAll(try dim_s.render(allocator, "  "));
    if (m.pending_conflicts > 0) {
        try sb.writeAll(conflict_banner);
        try sb.writeAll(try dim_s.render(allocator, "  "));
    }
    try sb.writeAll(try dim_s.render(allocator, pane_label));
    if (m.viewer.isModified()) {
        var mod_s = zz.Style{};
        mod_s = mod_s.fg(zz.Color.yellow()).inline_style(true);
        try sb.writeAll(try mod_s.render(allocator, " [modified]"));
    }

    return std.fmt.allocPrint(allocator, "{s}\n{s}\n{s}", .{ panes, hints_buf.written(), status_buf.written() });
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

// =============================================================================
// Model
// =============================================================================

pub const Model = struct {
    ctx: Context,
    screen: Screen,

    pub const Msg = common.Msg;
    pub const Cmd = common.Cmd;

    /// ZigZag calls 'init()' upon first 'run()' with only the zz Context.
    /// We have additional context that should be stored, so set that up
    /// before zz calls init.
    pub fn create(ctx: Context) Model {
        return .{
            .ctx = ctx,
            .screen = undefined,
        };
    }

    pub fn init(self: *Model, zz_ctx: *zz.Context) common.Cmd {
        const pa = zz_ctx.persistent_allocator;
        const db_path = self.ctx.db_path;

        switch (detectDbState(db_path)) {
            .not_found => {
                self.screen = .{ .create = views.CreateScreen.create(pa, &self.ctx) };
            },
            .plaintext => {
                // TODO: views.UnlockScreen.create(alloc, err_msg)
                self.ctx.deinitDb();
                self.ctx.db = common.openDb(pa, db_path, null) catch {
                    self.screen = .{ .unlock = makeUnlockScreen(pa, "Failed to open database.") };
                    return .none;
                };
                const main = makeMainScreen(pa, &self.ctx) catch {
                    self.ctx.deinitDb();
                    self.screen = .{ .unlock = makeUnlockScreen(pa, "Failed to load entries.") };
                    return .none;
                };
                self.screen = .{ .main = main };
            },
            .encrypted => {
                self.screen = .{ .unlock = makeUnlockScreen(pa, null) };
            },
        }
        return .none;
    }

    pub fn update(self: *Model, msg: common.Msg, ctx: *zz.Context) common.Cmd {
        switch (msg) {
            .key => |k| return self.handleKey(k, ctx.persistent_allocator),
            .set_view => |sv| switch (sv) {
                .create => {
                    self.screen = .{ .create = views.CreateScreen.create(ctx.persistent_allocator, &self.ctx) };
                },
                .unlock => |why| {
                    self.screen = .{ .unlock = makeUnlockScreen(ctx.persistent_allocator, why) };
                },
                else => @panic("TODO: handle set_view in update()"),
            },
        }
        return .none;
    }

    fn handleKey(self: *Model, k: zz.KeyEvent, pa: std.mem.Allocator) common.Cmd {
        switch (self.screen) {
            .unlock => |*u| {
                switch (k.key) {
                    .escape => return .quit,
                    .enter => {
                        const pw = u.input.getValue();
                        self.ctx.deinitDb();
                        self.ctx.db = common.openDb(pa, self.ctx.db_path, pw) catch |err| {
                            u.error_msg = if (err == error.WrongPassword)
                                "Wrong password. Try again."
                            else
                                "Failed to open database.";
                            u.input.setValue("") catch {};
                            return .none;
                        };
                        const main = makeMainScreen(pa, &self.ctx) catch {
                            self.ctx.deinitDb();
                            u.error_msg = "Failed to load entries.";
                            return .none;
                        };
                        u.deinit();
                        self.screen = .{ .main = main };
                    },
                    else => u.input.handleKey(k),
                }
            },
            .create => |*c| {
                return c.handleKey(k, pa);
            },
            .main => |*m| {
                const db = self.ctx.getDb() catch return .none; // TODO: set_view unlock?

                // Conflict view intercepts all keys when active.
                if (m.active_pane == .conflict) {
                    const sig = m.conflict_view.handleKey(k, db);
                    switch (sig) {
                        .none => {},
                        .closed => {
                            // User deferred: keep banner, return to browser.
                            m.pending_conflicts = m.conflict_view.pending.items.len;
                            // Save remaining conflicts back to disk so they survive restarts.
                            if (m.pending_conflicts > 0) {
                                db.saveConflicts(m.conflict_view.pending.items) catch {};
                            } else {
                                db.clearConflicts();
                            }
                            m.active_pane = .browser;
                        },
                        .all_resolved => {
                            m.pending_conflicts = 0;
                            db.clearConflicts();
                            m.browser.populate(db.listEntries()) catch {};
                            m.active_pane = .browser;
                            // Reload viewer for currently selected entry.
                            if (m.browser.selectedEntryId()) |eid| {
                                const head_hash = findHeadHash(db.listEntries(), eid);
                                const entry = db.getEntry(eid) catch null;
                                m.viewer.setEntry(eid, head_hash, entry);
                            }
                        },
                    }
                    return .none;
                }

                // History mode intercepts all keys.
                if (m.history.active) {
                    const sig = m.history.handleKey(k, db);
                    switch (sig) {
                        .none => {
                            // Navigation: take preview and update viewer.
                            if (m.history.takePreview()) |preview| {
                                m.viewer.setEntry(m.history.entry_id, m.history.selectedHash(), preview);
                            }
                        },
                        .closed => {
                            // Reload the current HEAD version into viewer.
                            const eid = m.history.entry_id;
                            const head_hash = findHeadHash(db.listEntries(), eid);
                            const entry = db.getEntry(eid) catch null;
                            m.viewer.setEntry(eid, head_hash, entry);
                            m.active_pane = .viewer;
                        },
                        .restored => {
                            // Entry was restored: repopulate browser, reload from db.
                            const eid = m.history.entry_id;
                            m.browser.populate(db.listEntries()) catch {};
                            const head_hash = findHeadHash(db.listEntries(), eid);
                            const entry = db.getEntry(eid) catch null;
                            m.viewer.setEntry(eid, head_hash, entry);
                            m.active_pane = .viewer;
                        },
                    }
                    return .none;
                }

                // Tab always switches panes (and exits edit mode first).
                if (k.key == .tab) {
                    if (m.viewer.isEditing()) m.viewer.leaveEditMode();
                    m.active_pane = if (m.active_pane == .browser) .viewer else .browser;
                    return .none;
                }

                switch (m.active_pane) {
                    .conflict => unreachable, // handled above
                    .browser => {
                        switch (k.key) {
                            .char => |c| switch (c) {
                                'q' => if (!m.viewer.isModified()) return .quit,
                                'n' => {
                                    m.viewer.setNewEntry(m.browser.selectedPath());
                                    m.active_pane = .viewer;
                                    return .none; // key consumed; do not pass to viewer
                                },
                                'C' => if (m.pending_conflicts > 0) {
                                    m.active_pane = .conflict;
                                    return .none;
                                },
                                else => m.browser.handleKey(k),
                            },
                            else => m.browser.handleKey(k),
                        }
                        // Update viewer when browser selection changes (no unsaved edits).
                        if (!m.viewer.isModified()) {
                            if (m.browser.selectedEntryId()) |eid| {
                                const head_hash = findHeadHash(db.listEntries(), eid);
                                const entry = db.getEntry(eid) catch null;
                                m.viewer.setEntry(eid, head_hash, entry);
                            } else {
                                m.viewer.setEntry(null, null, null);
                            }
                        }
                    },
                    .viewer => {
                        // C re-enters conflict view when pending conflicts exist.
                        if (k.key == .char and k.key.char == 'C' and m.pending_conflicts > 0) {
                            m.active_pane = .conflict;
                            return .none;
                        }
                        const sig = m.viewer.handleKey(k);
                        switch (sig) {
                            .none => {},
                            .save => saveEntry(m, pa),
                            .show_history => {
                                if (m.viewer.entry_id) |eid| {
                                    if (m.viewer.head_hash) |hh| {
                                        m.history.show(db, eid, hh) catch {};
                                    }
                                }
                            },
                            .quit => return .quit,
                        }
                    },
                }
            },
        }
        return .none;
    }

    pub fn view(self: *const Model, ctx: *const zz.Context) []const u8 {
        // Use @constCast so browser.view() can set list.height for scrolling.
        const self_mut = @constCast(self);
        return switch (self_mut.screen) {
            .unlock => |*u| viewUnlock(u, ctx.allocator, ctx.width, ctx.height),
            .create => |*c| c.view(ctx.allocator, ctx.width, ctx.height),
            .main => |*m| viewMain(m, ctx.allocator, ctx.width, ctx.height),
        } catch "Error rendering view.";
    }

    pub fn deinit(self: *Model) void {
        switch (self.screen) {
            .unlock => |*u| u.deinit(),
            .create => |*c| c.deinit(),
            .main => |*m| m.deinit(),
        }
        self.ctx.deinit();
    }
};

// =============================================================================
// Entry point
// =============================================================================

pub fn run(allocator: std.mem.Allocator, db_path: []const u8) !void {
    try theme.catppuccin_mocha.apply();
    defer theme.Theme.reset() catch {};
    var program = try zz.Program(Model).init(allocator);
    defer program.deinit();
    program.model = Model.create(.{ .db_path = db_path });
    try program.run();
}
