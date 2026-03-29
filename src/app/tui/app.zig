const std = @import("std");
const loki = @import("loki");
const zz = @import("zigzag");

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

const Screen = union(enum) {
    unlock: UnlockScreen,
    create: views.CreateScreen,
    main: views.MainScreen,
};

// =============================================================================
// Helpers
// =============================================================================

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

        switch (common.detectDbState(db_path)) {
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
                const main = views.MainScreen.create(pa, &self.ctx) catch {
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
        self.ctx.log("app update() with msg: {any}", .{msg});
        switch (msg) {
            .key => |k| return self.handleKey(k, ctx.persistent_allocator),
            .set_view => |sv| {
                self.ctx.log("Changing view to: {t}", .{sv});
                switch (sv) {
                    .create => {
                        self.screen = .{ .create = views.CreateScreen.create(ctx.persistent_allocator, &self.ctx) };
                    },
                    .unlock => |why| {
                        self.screen = .{ .unlock = makeUnlockScreen(ctx.persistent_allocator, why) };
                    },
                    .main => {
                        const main = views.MainScreen.create(ctx.persistent_allocator, &self.ctx) catch {
                            self.ctx.deinitDb();
                            self.screen = .{ .unlock = makeUnlockScreen(ctx.persistent_allocator, "Failed to load entries.") };
                            return .none;
                        };
                        self.screen = .{ .main = main };
                    },
                    else => {
                        self.ctx.log("TODO: Unimplemented set_view: {t}", .{sv});
                        @panic("TODO: handle set_view in update()");
                    },
                }
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
                        const main = views.MainScreen.create(pa, &self.ctx) catch {
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
                return m.handleKey(k, pa);
            },
        }
        return .none;
    }

    pub fn view(self: *const Model, ctx: *const zz.Context) []const u8 {
        // Use @constCast so browser.view() can set list.height for scrolling.
        self.ctx.log("entering view()", .{});
        const self_mut = @constCast(self);
        return switch (self_mut.screen) {
            .unlock => |*u| viewUnlock(u, ctx.allocator, ctx.width, ctx.height),
            .create => |*c| c.view(ctx.allocator, ctx.width, ctx.height),
            .main => |*m| m.view(ctx.allocator, ctx.width, ctx.height),
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
    // DEBUGGING
    var log_file = try std.fs.cwd().createFile("debug-log.txt", .{ .truncate = true });
    defer log_file.close();
    var log_w = log_file.writer(&.{});

    try theme.catppuccin_mocha.apply();
    defer theme.Theme.reset() catch {};
    var program = try zz.Program(Model).init(allocator);
    defer program.deinit();
    program.model = Model.create(.{
        .db_path = db_path,
        .dbg_writer = &log_w.interface,
    });
    try program.run();
}
