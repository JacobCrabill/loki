const std = @import("std");
const zz = @import("zigzag");
const loki = @import("loki");

const common = @import("../common.zig");
const Context = @import("../Context.zig");
// const theme = @import("../theme.zig"); // TODO

const CreateStage = enum {
    /// Entering the new password.
    password,
    /// Confirming the new password.
    confirm,
    /// Yes/no prompt before actually creating.
    confirming,
};

pub const CreateScreen = struct {
    ctx: *Context,
    pw_input: zz.TextInput,
    confirm_input: zz.TextInput,
    stage: CreateStage,
    error_msg: ?[]const u8,

    /// Create a new CreateScreen
    pub fn create(pa: std.mem.Allocator, ctx: *Context) CreateScreen {
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
            .ctx = ctx,
            .pw_input = pw,
            .confirm_input = confirm,
            .stage = .password,
            .error_msg = null,
        };
    }

    pub fn deinit(self: *CreateScreen) void {
        self.pw_input.deinit();
        self.confirm_input.deinit();
    }

    pub fn view(
        self: *const CreateScreen,
        allocator: std.mem.Allocator,
        term_width: u16,
        term_height: u16,
    ) ![]const u8 {
        self.ctx.log("Entering create view()", .{});
        var buf: std.Io.Writer.Allocating = .init(allocator);
        defer buf.deinit();
        const w = &buf.writer;

        var title_s = zz.Style{};
        title_s = title_s.bold(true);
        try w.writeAll(try title_s.render(allocator, "Create Database"));
        try w.writeAll("\n\n");

        var path_s = zz.Style{};
        path_s = path_s.dim(true);
        try w.writeAll(try path_s.render(allocator, self.ctx.db_path));
        try w.writeAll("\n\n");

        // Render each field with a ▶ indicator on the active one; dim the inactive.
        var arrow_s = zz.Style{};
        arrow_s = arrow_s.fg(zz.Color.cyan());
        arrow_s = arrow_s.bold(true);
        const arrow = try arrow_s.render(allocator, "▶ ");

        var dim_s = zz.Style{};
        dim_s = dim_s.dim(true);

        const pw_str = try self.pw_input.view(allocator);
        const cf_str = try self.confirm_input.view(allocator);

        switch (self.stage) {
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

        if (self.error_msg) |emsg| {
            try w.writeByte('\n');
            var err_s = zz.Style{};
            err_s = err_s.fg(zz.Color.red());
            try w.writeAll(try err_s.render(allocator, emsg));
        }

        if (self.stage == .confirming) {
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
            const hint: []const u8 = switch (self.stage) {
                .confirm, .password => "Tab / Shift+Tab: prev field   Enter: confirm   Esc: quit",
                .confirming => unreachable,
            };
            try w.writeAll("\n\nLeave blank for unencrypted.  ");
            try w.writeAll(hint);
        }

        var box_s = zz.Style{};
        box_s = box_s.borderAll(zz.Border.double).borderForeground(zz.Color.blue());
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

    pub fn handleKey(self: *CreateScreen, k: zz.KeyEvent, pa: std.mem.Allocator) common.Cmd {
        switch (self.stage) {
            .password => {
                switch (k.key) {
                    .escape => return .quit,
                    // Tab, Shift+Tab, or Enter: advance to confirm field.
                    .tab, .enter => {
                        self.pw_input.blur();
                        self.confirm_input.focus();
                        self.stage = .confirm;
                        self.error_msg = null;
                    },
                    else => self.pw_input.handleKey(k),
                }
            },
            .confirm => switch (k.key) {
                .escape => return .quit,
                // Tab or Shift+Tab: cycle back to password field.
                .tab => {
                    self.confirm_input.blur();
                    self.pw_input.focus();
                    self.stage = .password;
                    self.error_msg = null;
                },
                .enter => {
                    // Validate then move to yes/no confirmation.
                    const pw = self.pw_input.getValue();
                    const cf = self.confirm_input.getValue();
                    if (!std.mem.eql(u8, pw, cf)) {
                        self.error_msg = "Passwords do not match.";
                        self.confirm_input.setValue("") catch {};
                        self.confirm_input.blur();
                        self.pw_input.setValue("") catch {};
                        self.pw_input.focus();
                        self.stage = .password;
                        return .none;
                    }
                    self.confirm_input.blur();
                    self.stage = .confirming;
                    self.error_msg = null;
                },
                else => self.confirm_input.handleKey(k),
            },
            .confirming => switch (k.key) {
                .escape => {
                    // Back to confirm field.
                    self.confirm_input.focus();
                    self.stage = .confirm;
                },
                .enter => {
                    const pw = self.pw_input.getValue();
                    const password: ?[]const u8 = if (pw.len > 0) pw else null;

                    // Create the database and store it in the Context
                    self.ctx.deinitDb();
                    var db: loki.Database = common.createDb(pa, self.ctx.db_path, password) catch {
                        self.error_msg = "Failed to create database.";
                        self.confirm_input.focus();
                        self.stage = .confirm;
                        self.ctx.log("failed to create database", .{});
                        return .none;
                    };
                    db.save() catch {
                        db.deinit();
                        self.error_msg = "Failed to initialise database.";
                        self.confirm_input.focus();
                        self.stage = .confirm;
                        self.ctx.log("failed to initialise database", .{});
                        return .none;
                    };
                    self.ctx.db = db;

                    // Switch to the Main view.
                    self.deinit();
                    self.ctx.log("Switching to main view", .{});
                    return .{ .msg = .{ .set_view = .main } };
                },
                .char => |ch| switch (ch) {
                    'y', 'Y' => {
                        const pw = self.pw_input.getValue();
                        const password: ?[]const u8 = if (pw.len > 0) pw else null;
                        var db = common.createDb(pa, self.ctx.db_path, password) catch {
                            self.error_msg = "Failed to create database.";
                            self.confirm_input.focus();
                            self.stage = .confirm;
                            return .none;
                        };
                        db.save() catch {};
                        // TODO: Return main_screen event to parent?
                        // const main = makeMainScreen(pa, db) catch {
                        //     db.deinit();
                        //     self.error_msg = "Failed to initialise database.";
                        //     self.confirm_input.focus();
                        //     self.stage = .confirm;
                        //     return .none;
                        // };
                        // self.deinit();
                        // self.screen = .{ .main = main };
                        return .{ .msg = .{ .set_view = .main } };
                    },
                    'n', 'N' => {
                        self.confirm_input.focus();
                        self.stage = .confirm;
                    },
                    else => {},
                },
                else => {},
            },
        }

        // By default, submit no command to Update.
        return .none;
    }
};
