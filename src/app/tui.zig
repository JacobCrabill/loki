pub const tui = struct {
    pub const app = @import("tui/app.zig");
    pub const browser = @import("tui/browser.zig");
    pub const viewer = @import("tui/viewer.zig");
    pub const generator = @import("tui/generator.zig");
    pub const history_view = @import("tui/history_view.zig");
};
