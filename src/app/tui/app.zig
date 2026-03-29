const std = @import("std");
const loki = @import("loki");
const zz = @import("zigzag");

const theme = @import("theme.zig");
const common = @import("common.zig");
const Context = @import("Context.zig");
const views = @import("views.zig");

/// Available screens for our TUI.
/// At any given time, only one screen is active.
const Screen = union(enum) {
    unlock: views.Unlock,
    create: views.CreateScreen,
    main: views.MainScreen,
};

/// ZigZag Model Object
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
                self.ctx.deinitDb();
                self.ctx.db = common.openDb(pa, db_path, null) catch {
                    return .{ .msg = .{ .set_view = .{ .unlock = "Failed to open database." } } };
                };
                const main = views.MainScreen.create(pa, &self.ctx) catch {
                    self.ctx.deinitDb();
                    return .{ .msg = .{ .set_view = .{ .unlock = "Failed to load entries." } } };
                };
                self.screen = .{ .main = main };
            },
            .encrypted => {
                self.screen = .{ .unlock = views.Unlock.create(pa, &self.ctx, null) };
            },
        }
        return .none;
    }

    pub fn update(self: *Model, msg: common.Msg, ctx: *zz.Context) common.Cmd {
        // self.ctx.log("app update() with msg: {any}", .{msg});
        switch (msg) {
            .key => |k| return self.handleKey(k, ctx.persistent_allocator),
            .set_view => |sv| {
                // self.ctx.log("Changing view to: {t}", .{sv});
                switch (sv) {
                    .create => {
                        self.screen = .{ .create = views.CreateScreen.create(ctx.persistent_allocator, &self.ctx) };
                    },
                    .unlock => |why| {
                        self.screen = .{ .unlock = views.Unlock.create(ctx.persistent_allocator, &self.ctx, why) };
                    },
                    .main => {
                        const main = views.MainScreen.create(ctx.persistent_allocator, &self.ctx) catch {
                            self.ctx.deinitDb();
                            self.screen = .{ .unlock = views.Unlock.create(ctx.persistent_allocator, &self.ctx, "Failed to load entries.") };
                            return .none;
                        };
                        self.screen = .{ .main = main };
                    },
                    else => {
                        // self.ctx.log("TODO: Unimplemented set_view: {t}", .{sv});
                        @panic("TODO: handle set_view in update()");
                    },
                }
            },
        }
        return .none;
    }

    fn handleKey(self: *Model, k: zz.KeyEvent, pa: std.mem.Allocator) common.Cmd {
        switch (self.screen) {
            .unlock => |*u| return u.handleKey(k, pa),
            .create => |*c| return c.handleKey(k, pa),
            .main => |*m| return m.handleKey(k, pa),
        }
        return .none;
    }

    pub fn view(self: *Model, ctx: *const zz.Context) []const u8 {
        // self.ctx.log("entering view()", .{});
        return switch (self.screen) {
            .unlock => |*u| u.view(ctx.allocator, ctx.width, ctx.height),
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

/// Setup and run the ZigZag application Model
pub fn run(allocator: std.mem.Allocator, db_path: []const u8) !void {
    // DEBUGGING
    // var log_file = try std.fs.cwd().createFile("debug-log.txt", .{ .truncate = true });
    // defer log_file.close();
    // var log_w = log_file.writer(&.{});

    try theme.catppuccin_mocha.apply();
    defer theme.Theme.reset() catch {};
    var program = try zz.Program(Model).initWithOptions(allocator, .{
        .foreground = zz.Color.fromRgb(0xcd, 0xd6, 0xf4),
        .background = zz.Color.fromRgb(0x1e, 0x1e, 0x2e),
    });
    defer program.deinit();
    program.model = Model.create(.{
        .db_path = db_path,
        // .dbg_writer = &log_w.interface,
    });
    try program.run();
}
