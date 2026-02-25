const std = @import("std");

pub const crypto = struct {
    pub const cipher = @import("crypto/cipher.zig");
    pub const kdf = @import("crypto/kdf.zig");
};

pub const model = struct {
    pub const entry = @import("model/entry.zig");
};

pub const store = struct {
    pub const object = @import("store/object.zig");
    pub const index = @import("store/index.zig");
    pub const database = @import("store/database.zig");
};

pub const tui = struct {
    pub const app = @import("tui/app.zig");
    pub const browser = @import("tui/browser.zig");
    pub const viewer = @import("tui/viewer.zig");
    pub const generator = @import("tui/generator.zig");
    pub const history_view = @import("tui/history_view.zig");
};

pub const Entry = model.entry.Entry;
pub const Database = store.database.Database;

// Pull in tests from all sub-modules.
comptime {
    _ = crypto.cipher;
    _ = crypto.kdf;
    _ = model.entry;
    _ = store.object;
    _ = store.index;
    _ = store.database;
}
