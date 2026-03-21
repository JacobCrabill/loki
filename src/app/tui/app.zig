const std = @import("std");
const zz = @import("zigzag");
const loki = @import("loki");
const theme = @import("theme.zig");

const IndexEntry = loki.store.index.IndexEntry;
const Database = loki.Database;
const ConflictEntry = loki.model.merge.ConflictEntry;
const Browser = @import("browser.zig").Browser;
const Viewer = @import("viewer.zig").Viewer;
const HistoryView = @import("history_view.zig").HistoryView;
const ConflictView = @import("conflict_view.zig").ConflictView;

/// Set this before calling `run()`.
pub var g_db_path: []const u8 = "";

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

const CreateScreen = struct {
    pw_input: zz.TextInput,
    confirm_input: zz.TextInput,
    stage: CreateStage,
    error_msg: ?[]const u8,

    fn deinit(self: *CreateScreen) void {
        self.pw_input.deinit();
        self.confirm_input.deinit();
    }
};

const MainScreen = struct {
    db: Database,
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
        self.db.deinit();
    }
};

const Screen = union(enum) {
    unlock: UnlockScreen,
    create: CreateScreen,
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

fn openDb(pa: std.mem.Allocator, db_path: []const u8, password: ?[]const u8) !Database {
    const dirname = std.fs.path.dirname(db_path) orelse ".";
    const basename = std.fs.path.basename(db_path);
    var base_dir = try std.fs.cwd().openDir(dirname, .{});
    defer base_dir.close();
    return Database.open(pa, base_dir, basename, password);
}

fn makeMainScreen(pa: std.mem.Allocator, db: Database) !MainScreen {
    var screen = MainScreen{
        .db = db,
        .browser = Browser.init(pa),
        .viewer = Viewer.init(pa),
        .history = HistoryView.init(pa),
        .conflict_view = ConflictView.init(pa),
        .pending_conflicts = 0,
        .active_pane = .browser,
    };
    try screen.browser.populate(screen.db.listEntries());
    if (screen.browser.selectedEntryId()) |eid| {
        const head_hash = findHeadHash(screen.db.listEntries(), eid);
        const entry = screen.db.getEntry(eid) catch null;
        screen.viewer.setEntry(eid, head_hash, entry);
    }

    // Load any pending conflicts saved by a previous `loki sync`.
    const conflicts = screen.db.loadConflicts(pa) catch &.{};
    defer pa.free(conflicts);
    if (conflicts.len > 0) {
        screen.conflict_view.load(&screen.db, conflicts);
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

fn makeCreateScreen(pa: std.mem.Allocator) CreateScreen {
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

    return zz.place.place(allocator, term_width, term_height, .center, .middle, box);
}

fn viewCreate(
    c: *const CreateScreen,
    allocator: std.mem.Allocator,
    term_width: u16,
    term_height: u16,
) ![]const u8 {
    var buf: std.Io.Writer.Allocating = .init(allocator);
    defer buf.deinit();
    const w = &buf.writer;

    var title_s = zz.Style{};
    title_s = title_s.bold(true);
    try w.writeAll(try title_s.render(allocator, "Loki — Create Database"));
    try w.writeAll("\n\n");

    var path_s = zz.Style{};
    path_s = path_s.dim(true);
    try w.writeAll(try path_s.render(allocator, g_db_path));
    try w.writeAll("\n\n");

    // Render each field with a ▶ indicator on the active one; dim the inactive.
    var arrow_s = zz.Style{};
    arrow_s = arrow_s.fg(zz.Color.cyan());
    arrow_s = arrow_s.bold(true);
    const arrow = try arrow_s.render(allocator, "▶ ");

    var dim_s = zz.Style{};
    dim_s = dim_s.dim(true);

    const pw_str = try c.pw_input.view(allocator);
    const cf_str = try c.confirm_input.view(allocator);

    switch (c.stage) {
        .password => {
            try w.writeAll(arrow);
            try w.writeAll(pw_str);
            try w.writeByte('\n');
            try w.writeAll("  ");
            try w.writeAll(try dim_s.render(allocator, cf_str));
        },
        .confirm => {
            try w.writeAll("  ");
            try w.writeAll(try dim_s.render(allocator, pw_str));
            try w.writeByte('\n');
            try w.writeAll(arrow);
            try w.writeAll(cf_str);
        },
        .confirming => {
            try w.writeAll("  ");
            try w.writeAll(try dim_s.render(allocator, pw_str));
            try w.writeByte('\n');
            try w.writeAll("  ");
            try w.writeAll(try dim_s.render(allocator, cf_str));
        },
    }

    if (c.error_msg) |emsg| {
        try w.writeByte('\n');
        var err_s = zz.Style{};
        err_s = err_s.fg(zz.Color.red());
        try w.writeAll(try err_s.render(allocator, emsg));
    }

    if (c.stage == .confirming) {
        try w.writeAll("\n\n");
        try w.writeAll(arrow);
        var confirm_s = zz.Style{};
        confirm_s = confirm_s.bold(true);
        try w.writeAll(try confirm_s.render(allocator, "Create this database?"));
        try w.writeAll("\n\n");
        var hint_s = zz.Style{};
        hint_s = hint_s.dim(true);
        try w.writeAll(try hint_s.render(allocator, "Y / Enter: yes   N / Esc: no"));
    } else {
        const hint: []const u8 = switch (c.stage) {
            .confirm, .password => "Tab / Shift+Tab: prev field   Enter: confirm   Esc: quit",
            .confirming => unreachable,
        };
        try w.writeAll("\n\nLeave blank for unencrypted.  ");
        try w.writeAll(hint);
    }

    var box_s = zz.Style{};
    box_s = box_s.borderAll(zz.Border.rounded);
    box_s = box_s.paddingAll(1);
    const box = try box_s.render(allocator, buf.written());

    return zz.place.place(allocator, term_width, term_height, .center, .middle, box);
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
    // Reserve 1 row for the status line; panes fill the rest.
    const pane_height: u16 = if (term_height > 1) term_height - 1 else 1;

    // Conflict view takes the full width.
    if (m.active_pane == .conflict) {
        const conflict_raw = try m.conflict_view.view(allocator, term_width, pane_height);
        const conflict_padded = try zz.placeVertical(allocator, pane_height, .top, conflict_raw);

        var db_s = zz.Style{};
        db_s = db_s.bold(true).fg(zz.Color.brightBlue()).inline_style(true);
        var dim_s = zz.Style{};
        dim_s = dim_s.dim(true).inline_style(true);
        var status_buf: std.Io.Writer.Allocating = .init(allocator);
        defer status_buf.deinit();
        const sb = &status_buf.writer;
        try sb.writeByte(' ');
        try sb.writeAll(try db_s.render(allocator, g_db_path));
        try sb.writeAll(try dim_s.render(allocator, "  [conflict]  │  "));
        try sb.writeAll(try renderHints(allocator, m.conflict_view.getHints()));
        return std.fmt.allocPrint(allocator, "{s}\n{s}", .{ conflict_padded, status_buf.written() });
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

    // Build the status bar piece-by-piece so each element can carry its own
    // style: bold+blue db name, dim pane label, yellow [modified], styled hints.
    var db_s = zz.Style{};
    db_s = db_s.bold(true).fg(zz.Color.brightBlue()).inline_style(true);
    var dim_s = zz.Style{};
    dim_s = dim_s.dim(true).inline_style(true);

    var status_buf: std.Io.Writer.Allocating = .init(allocator);
    defer status_buf.deinit();
    const sb = &status_buf.writer;

    try sb.writeByte(' ');
    try sb.writeAll(try db_s.render(allocator, g_db_path));
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
    try sb.writeAll(try dim_s.render(allocator, "  │  "));
    try sb.writeAll(try renderHints(allocator, full_hints));

    return std.fmt.allocPrint(allocator, "{s}\n{s}", .{ panes, status_buf.written() });
}

fn saveEntry(m: *MainScreen, pa: std.mem.Allocator) void {
    const entry = m.viewer.buildEntry() catch return;
    defer entry.deinit(pa);

    if (m.viewer.is_new) {
        // Require at least a non-empty title.
        if (entry.title.len == 0) return;
        const eid = m.db.createEntry(entry) catch return;
        m.db.save() catch {};
        m.browser.populate(m.db.listEntries()) catch {};
        // head_hash == entry_id for a genesis entry.
        const loaded = m.db.getEntry(eid) catch null;
        m.viewer.setEntry(eid, eid, loaded);
    } else if (m.viewer.entry_id) |eid| {
        const new_hash = m.db.updateEntry(eid, entry) catch return;
        m.db.save() catch {};
        m.browser.populate(m.db.listEntries()) catch {};
        const loaded = m.db.getEntry(eid) catch null;
        m.viewer.setEntry(eid, new_hash, loaded);
    }
}

// =============================================================================
// Model
// =============================================================================

pub const Model = struct {
    screen: Screen,

    pub const Msg = union(enum) {
        key: zz.KeyEvent,
    };

    pub fn init(self: *Model, ctx: *zz.Context) zz.Cmd(Msg) {
        const pa = ctx.persistent_allocator;
        const db_path = g_db_path;

        switch (detectDbState(db_path)) {
            .not_found => {
                self.* = .{ .screen = .{ .create = makeCreateScreen(pa) } };
            },
            .plaintext => {
                var db = openDb(pa, db_path, null) catch {
                    self.* = .{ .screen = .{ .unlock = makeUnlockScreen(pa, "Failed to open database.") } };
                    return .none;
                };
                const main = makeMainScreen(pa, db) catch {
                    db.deinit();
                    self.* = .{ .screen = .{ .unlock = makeUnlockScreen(pa, "Failed to load entries.") } };
                    return .none;
                };
                self.* = .{ .screen = .{ .main = main } };
            },
            .encrypted => {
                self.* = .{ .screen = .{ .unlock = makeUnlockScreen(pa, null) } };
            },
        }
        return .none;
    }

    pub fn update(self: *Model, msg: Msg, ctx: *zz.Context) zz.Cmd(Msg) {
        switch (msg) {
            .key => |k| return self.handleKey(k, ctx.persistent_allocator),
        }
    }

    fn handleKey(self: *Model, k: zz.KeyEvent, pa: std.mem.Allocator) zz.Cmd(Msg) {
        switch (self.screen) {
            .unlock => |*u| {
                switch (k.key) {
                    .escape => return .quit,
                    .enter => {
                        const pw = u.input.getValue();
                        var db = openDb(pa, g_db_path, pw) catch |err| {
                            u.error_msg = if (err == error.WrongPassword)
                                "Wrong password. Try again."
                            else
                                "Failed to open database.";
                            u.input.setValue("") catch {};
                            return .none;
                        };
                        const main = makeMainScreen(pa, db) catch {
                            db.deinit();
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
                switch (c.stage) {
                    .password => switch (k.key) {
                        .escape => return .quit,
                        // Tab, Shift+Tab, or Enter: advance to confirm field.
                        .tab, .enter => {
                            c.pw_input.blur();
                            c.confirm_input.focus();
                            c.stage = .confirm;
                            c.error_msg = null;
                        },
                        else => c.pw_input.handleKey(k),
                    },
                    .confirm => switch (k.key) {
                        .escape => return .quit,
                        // Tab or Shift+Tab: cycle back to password field.
                        .tab => {
                            c.confirm_input.blur();
                            c.pw_input.focus();
                            c.stage = .password;
                            c.error_msg = null;
                        },
                        .enter => {
                            // Validate then move to yes/no confirmation.
                            const pw = c.pw_input.getValue();
                            const cf = c.confirm_input.getValue();
                            if (!std.mem.eql(u8, pw, cf)) {
                                c.error_msg = "Passwords do not match.";
                                c.confirm_input.setValue("") catch {};
                                c.confirm_input.blur();
                                c.pw_input.setValue("") catch {};
                                c.pw_input.focus();
                                c.stage = .password;
                                return .none;
                            }
                            c.confirm_input.blur();
                            c.stage = .confirming;
                            c.error_msg = null;
                        },
                        else => c.confirm_input.handleKey(k),
                    },
                    .confirming => switch (k.key) {
                        .escape => {
                            // Back to confirm field.
                            c.confirm_input.focus();
                            c.stage = .confirm;
                        },
                        .enter => {
                            const pw = c.pw_input.getValue();
                            const password: ?[]const u8 = if (pw.len > 0) pw else null;
                            var db = createDb(pa, g_db_path, password) catch {
                                c.error_msg = "Failed to create database.";
                                c.confirm_input.focus();
                                c.stage = .confirm;
                                return .none;
                            };
                            db.save() catch {};
                            const main = makeMainScreen(pa, db) catch {
                                db.deinit();
                                c.error_msg = "Failed to initialise database.";
                                c.confirm_input.focus();
                                c.stage = .confirm;
                                return .none;
                            };
                            c.deinit();
                            self.screen = .{ .main = main };
                        },
                        .char => |ch| switch (ch) {
                            'y', 'Y' => {
                                const pw = c.pw_input.getValue();
                                const password: ?[]const u8 = if (pw.len > 0) pw else null;
                                var db = createDb(pa, g_db_path, password) catch {
                                    c.error_msg = "Failed to create database.";
                                    c.confirm_input.focus();
                                    c.stage = .confirm;
                                    return .none;
                                };
                                db.save() catch {};
                                const main = makeMainScreen(pa, db) catch {
                                    db.deinit();
                                    c.error_msg = "Failed to initialise database.";
                                    c.confirm_input.focus();
                                    c.stage = .confirm;
                                    return .none;
                                };
                                c.deinit();
                                self.screen = .{ .main = main };
                            },
                            'n', 'N' => {
                                c.confirm_input.focus();
                                c.stage = .confirm;
                            },
                            else => {},
                        },
                        else => {},
                    },
                }
            },
            .main => |*m| {
                // Conflict view intercepts all keys when active.
                if (m.active_pane == .conflict) {
                    const sig = m.conflict_view.handleKey(k, &m.db);
                    switch (sig) {
                        .none => {},
                        .closed => {
                            // User deferred: keep banner, return to browser.
                            m.pending_conflicts = m.conflict_view.pending.items.len;
                            // Save remaining conflicts back to disk so they survive restarts.
                            if (m.pending_conflicts > 0) {
                                m.db.saveConflicts(m.conflict_view.pending.items) catch {};
                            } else {
                                m.db.clearConflicts();
                            }
                            m.active_pane = .browser;
                        },
                        .all_resolved => {
                            m.pending_conflicts = 0;
                            m.db.clearConflicts();
                            m.browser.populate(m.db.listEntries()) catch {};
                            m.active_pane = .browser;
                            // Reload viewer for currently selected entry.
                            if (m.browser.selectedEntryId()) |eid| {
                                const head_hash = findHeadHash(m.db.listEntries(), eid);
                                const entry = m.db.getEntry(eid) catch null;
                                m.viewer.setEntry(eid, head_hash, entry);
                            }
                        },
                    }
                    return .none;
                }

                // History mode intercepts all keys.
                if (m.history.active) {
                    const sig = m.history.handleKey(k, &m.db);
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
                            const head_hash = findHeadHash(m.db.listEntries(), eid);
                            const entry = m.db.getEntry(eid) catch null;
                            m.viewer.setEntry(eid, head_hash, entry);
                            m.active_pane = .viewer;
                        },
                        .restored => {
                            // Entry was restored: repopulate browser, reload from db.
                            const eid = m.history.entry_id;
                            m.browser.populate(m.db.listEntries()) catch {};
                            const head_hash = findHeadHash(m.db.listEntries(), eid);
                            const entry = m.db.getEntry(eid) catch null;
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
                                const head_hash = findHeadHash(m.db.listEntries(), eid);
                                const entry = m.db.getEntry(eid) catch null;
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
                                        m.history.show(&m.db, eid, hh) catch {};
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
            .create => |*c| viewCreate(c, ctx.allocator, ctx.width, ctx.height),
            .main => |*m| viewMain(m, ctx.allocator, ctx.width, ctx.height),
        } catch "Error rendering view.";
    }

    pub fn deinit(self: *Model) void {
        switch (self.screen) {
            .unlock => |*u| u.deinit(),
            .create => |*c| c.deinit(),
            .main => |*m| m.deinit(),
        }
    }
};

// =============================================================================
// Entry point
// =============================================================================

pub fn run(allocator: std.mem.Allocator, db_path: []const u8) !void {
    g_db_path = db_path;
    try theme.catppuccin_mocha.apply();
    defer theme.Theme.reset() catch {};
    var program = try zz.Program(Model).init(allocator);
    defer program.deinit();
    try program.run();
}
