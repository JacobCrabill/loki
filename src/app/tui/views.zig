pub const browser = @import("views/browser.zig");
pub const conflict = @import("views/conflict.zig");
pub const create = @import("views/create.zig");
pub const generator = @import("views/generator.zig");
pub const history = @import("views/history.zig");
pub const main_screen = @import("views/main.zig");
pub const search = @import("views/search.zig");
pub const unlock = @import("views/unlock.zig");
pub const viewer = @import("views/viewer.zig");

/// Entry Browser
pub const Browser = browser.Browser;

/// Database Creation Screen
pub const CreateScreen = create.CreateScreen;

/// Conflict resolution view
pub const ConflictView = conflict.ConflictView;

/// Password Generator
pub const Generator = generator.Generator;

/// Entry history view
pub const HistoryView = history.HistoryView;

/// Main window - browser + viewer, or history, or conflict
pub const MainScreen = main_screen.MainScreen;

/// Inline search pane
pub const SearchPane = search.SearchPane;

/// Database unlock screen
pub const Unlock = unlock.Unlock;

/// Single-entry view
pub const Viewer = viewer.Viewer;
