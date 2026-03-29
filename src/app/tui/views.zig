pub const browser = @import("views/browser.zig");
pub const conflict = @import("views/conflict.zig");
pub const create = @import("views/create.zig");
pub const history = @import("views/history.zig");
pub const viewer = @import("views/viewer.zig");

// pub const login = @import("views/login.zig");
// pub const password = @import("views/password.zig");

pub const Browser = browser.Browser;
pub const CreateScreen = create.CreateScreen;
pub const ConflictView = conflict.ConflictView;
pub const HistoryView = history.HistoryView;
pub const Viewer = viewer.Viewer;
