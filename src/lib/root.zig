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
    pub const sync = @import("store/sync.zig");
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
    _ = store.sync;
}
