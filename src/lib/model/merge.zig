/// A pair of diverged HEADs for the same entry.  Stored in the local database's
/// `conflicts` file so the TUI can offer interactive resolution later.
pub const ConflictEntry = struct {
    entry_id: [20]u8,
    local_hash: [20]u8,
    remote_hash: [20]u8,
};
