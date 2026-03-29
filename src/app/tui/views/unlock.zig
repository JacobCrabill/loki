//! Database unlock screen
const std = @import("std");
const loki = @import("loki");
const zz = @import("zigzag");

const common = @import("../common.zig");
const Context = @import("../Context.zig");

pub const Unlock = struct {
    ctx: *Context,
    input: zz.TextInput,
    error_msg: ?[]const u8,

    pub fn create(pa: std.mem.Allocator, ctx: *Context, err_msg: ?[]const u8) Unlock {
        var input = zz.TextInput.init(pa);
        input.setEchoMode(.password);
        input.setPrompt("Password: ");
        return .{ .ctx = ctx, .input = input, .error_msg = err_msg };
    }

    pub fn deinit(self: *Unlock) void {
        self.input.deinit();
    }

    pub fn view(
        u: *const Unlock,
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

    pub fn handleKey(self: *Unlock, k: zz.KeyEvent, pa: std.mem.Allocator) common.Cmd {
        switch (k.key) {
            .escape => return .quit,
            .enter => {
                const pw = self.input.getValue();
                self.ctx.deinitDb();
                self.ctx.db = common.openDb(pa, self.ctx.db_path, pw) catch |err| {
                    self.error_msg = if (err == error.WrongPassword)
                        "Wrong password. Try again."
                    else
                        "Failed to open database.";
                    self.input.setValue("") catch {};
                    return .none;
                };

                // Switch to the Main view.
                self.deinit();
                self.ctx.log("Switching from login to main view", .{});
                return .{ .msg = .{ .set_view = .main } };
            },
            else => self.input.handleKey(k),
        }
        return .none;
    }
};
