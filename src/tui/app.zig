const std = @import("std");
const zz = @import("zigzag");
const Database = @import("../store/database.zig").Database;
const Browser = @import("browser.zig").Browser;
const Viewer = @import("viewer.zig").Viewer;

/// Set this before calling `run()`.
pub var g_db_path: []const u8 = "";

// =============================================================================
// Internal types
// =============================================================================

const Pane = enum { browser, viewer };

const UnlockScreen = struct {
    input: zz.TextInput,
    error_msg: ?[]const u8,

    fn deinit(self: *UnlockScreen) void {
        self.input.deinit();
    }
};

const CreateField = enum { password, confirm };

const CreateScreen = struct {
    pw_input: zz.TextInput,
    confirm_input: zz.TextInput,
    active_field: CreateField,
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
    active_pane: Pane,

    fn deinit(self: *MainScreen) void {
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
        .active_pane = .browser,
    };
    try screen.browser.populate(screen.db.listEntries());
    if (screen.browser.selectedEntryId()) |eid| {
        const entry = screen.db.getEntry(eid) catch null;
        screen.viewer.setEntry(entry);
    }
    return screen;
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
    var confirm = zz.TextInput.init(pa);
    confirm.setEchoMode(.password);
    confirm.setPrompt("Confirm:      ");
    confirm.focused = false;
    return .{
        .pw_input = pw,
        .confirm_input = confirm,
        .active_field = .password,
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
    var buf: std.ArrayList(u8) = .{};
    defer buf.deinit(allocator);
    const w = buf.writer(allocator);

    var title_s = zz.Style{};
    title_s = title_s.bold(true);
    try w.writeAll(try title_s.render(allocator, "PazzMan"));
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
    const box = try box_s.render(allocator, buf.items);

    return zz.place.place(allocator, term_width, term_height, .center, .middle, box);
}

fn viewCreate(
    c: *const CreateScreen,
    allocator: std.mem.Allocator,
    term_width: u16,
    term_height: u16,
) ![]const u8 {
    var buf: std.ArrayList(u8) = .{};
    defer buf.deinit(allocator);
    const w = buf.writer(allocator);

    var title_s = zz.Style{};
    title_s = title_s.bold(true);
    try w.writeAll(try title_s.render(allocator, "PazzMan — Create Database"));
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

    if (c.active_field == .password) {
        try w.writeAll(arrow);
        try w.writeAll(pw_str);
        try w.writeByte('\n');
        try w.writeAll("  "); // align with arrow width
        try w.writeAll(try dim_s.render(allocator, cf_str));
    } else {
        try w.writeAll("  ");
        try w.writeAll(try dim_s.render(allocator, pw_str));
        try w.writeByte('\n');
        try w.writeAll(arrow);
        try w.writeAll(cf_str);
    }

    if (c.error_msg) |emsg| {
        try w.writeByte('\n');
        var err_s = zz.Style{};
        err_s = err_s.fg(zz.Color.red());
        try w.writeAll(try err_s.render(allocator, emsg));
    }

    try w.writeAll("\n\nLeave blank for unencrypted.  Tab: next field  Enter: create  Esc: quit");

    var box_s = zz.Style{};
    box_s = box_s.borderAll(zz.Border.rounded);
    box_s = box_s.paddingAll(1);
    const box = try box_s.render(allocator, buf.items);

    return zz.place.place(allocator, term_width, term_height, .center, .middle, box);
}

fn viewMain(
    m: *MainScreen,
    allocator: std.mem.Allocator,
    term_width: u16,
    term_height: u16,
) ![]const u8 {
    const content_height: u16 = if (term_height > 2) term_height - 1 else 1;
    const browser_width: u16 = @max(20, term_width / 3);
    const viewer_width: u16 = term_width -| browser_width;

    const browser_str = try m.browser.view(allocator, browser_width, content_height);
    const viewer_str = try m.viewer.view(allocator, viewer_width, content_height);
    const panes = try zz.joinHorizontal(allocator, &.{ browser_str, viewer_str });

    const pane_label: []const u8 = if (m.active_pane == .browser) "[browser]" else "[viewer]";
    var status_s = zz.Style{};
    status_s = status_s.dim(true);
    const status_text = try std.fmt.allocPrint(allocator, " {s}  {s}", .{ g_db_path, pane_label });
    const status = try status_s.render(allocator, status_text);

    return std.fmt.allocPrint(allocator, "{s}\n{s}", .{ panes, status });
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
                switch (k.key) {
                    .escape => return .quit,
                    .tab, .enter => {
                        if (c.active_field == .password) {
                            // Move focus to confirm field.
                            c.pw_input.blur();
                            c.confirm_input.focus();
                            c.active_field = .confirm;
                        } else {
                            // Attempt creation.
                            const pw = c.pw_input.getValue();
                            const cf = c.confirm_input.getValue();
                            if (!std.mem.eql(u8, pw, cf)) {
                                c.error_msg = "Passwords do not match.";
                                c.confirm_input.setValue("") catch {};
                                c.confirm_input.blur();
                                c.pw_input.setValue("") catch {};
                                c.pw_input.focus();
                                c.active_field = .password;
                                return .none;
                            }
                            const password: ?[]const u8 = if (pw.len > 0) pw else null;
                            var db = createDb(pa, g_db_path, password) catch {
                                c.error_msg = "Failed to create database.";
                                return .none;
                            };
                            // Save the empty index.
                            db.save() catch {};
                            const main = makeMainScreen(pa, db) catch {
                                db.deinit();
                                c.error_msg = "Failed to initialise database.";
                                return .none;
                            };
                            c.deinit();
                            self.screen = .{ .main = main };
                        }
                    },
                    else => switch (c.active_field) {
                        .password => c.pw_input.handleKey(k),
                        .confirm => c.confirm_input.handleKey(k),
                    },
                }
            },
            .main => |*m| {
                switch (k.key) {
                    .char => |c| if (c == 'q') return .quit,
                    .tab => m.active_pane = if (m.active_pane == .browser) .viewer else .browser,
                    else => {},
                }
                switch (m.active_pane) {
                    .browser => {
                        m.browser.handleKey(k);
                        if (m.browser.selectedEntryId()) |eid| {
                            const entry = m.db.getEntry(eid) catch null;
                            m.viewer.setEntry(entry);
                        }
                    },
                    .viewer => m.viewer.handleKey(k),
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
    var program = try zz.Program(Model).init(allocator);
    defer program.deinit();
    try program.run();
}
