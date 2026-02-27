const std = @import("std");
const Database = @import("database.zig").Database;
const index_mod = @import("index.zig");
const Index = index_mod.Index;

pub const SyncResult = struct {
    objects_pulled: usize = 0,
    objects_pushed: usize = 0,
    /// Local HEAD advanced to match a newer remote HEAD (fast-forward).
    fast_forwarded: usize = 0,
    /// Remote HEAD advanced to match a newer local HEAD.
    remote_advanced: usize = 0,
    /// Entries that existed only on remote, now added to local.
    new_to_local: usize = 0,
    /// Entries that existed only on local, now pushed to remote.
    new_to_remote: usize = 0,
    /// Genuinely diverged HEADs; local HEAD retained, conflict reported.
    conflicts: usize = 0,
};

// Deferred index mutation to avoid invalidating iterators.
const Pending = struct {
    entry_id: [20]u8,
    head_hash: [20]u8,
    /// Points into source index string data (heap-stable, not moved by ArrayList resize).
    title: []const u8,
    path: []const u8,
    kind: enum { add, update },
};

// ---------------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------------

/// Walk parent_hash chain from `descendant` looking for `ancestor`.
/// Returns true if found (including when they are equal).
/// Uses `db` to load objects; returns false on read error or depth > 1000.
fn isAncestor(db: *Database, ancestor_hash: [20]u8, descendant_hash: [20]u8) bool {
    var current = descendant_hash;
    var depth: usize = 0;
    while (depth < 1000) : (depth += 1) {
        if (std.mem.eql(u8, &current, &ancestor_hash)) return true;
        const e = db.getVersion(current) catch return false;
        const parent = e.parent_hash;
        e.deinit(db.allocator);
        current = parent orelse return false;
    }
    return false;
}

/// Copy all objects missing in `dst_db` from `src_db`.
/// Copies raw encrypted bytes directly; valid only when both databases share
/// the same derived key (i.e. were created from the same `header` file).
/// Returns the number of objects copied.
fn copyObjectsOneWay(
    allocator: std.mem.Allocator,
    src_db: *Database,
    dst_db: *Database,
) !usize {
    var count: usize = 0;

    // Reopen objects dir with iteration capability (Database.open uses default flags).
    var iter_dir = try src_db.dir.openDir("objects", .{ .iterate = true });
    defer iter_dir.close();

    var iter = iter_dir.iterate();
    while (try iter.next()) |ent| {
        if (ent.kind != .file) continue;
        if (ent.name.len != 40) continue; // not a SHA-1 hex filename

        // Skip if already present in destination.
        if (dst_db.objects_dir.openFile(ent.name, .{})) |f| {
            f.close();
            continue;
        } else |err| {
            if (err != error.FileNotFound) return err;
        }

        const src_file = try iter_dir.openFile(ent.name, .{});
        defer src_file.close();
        const data = try src_file.readToEndAlloc(allocator, 64 * 1024 * 1024);
        defer allocator.free(data);

        const dst_file = dst_db.objects_dir.createFile(ent.name, .{ .exclusive = true }) catch |e| {
            if (e == error.PathAlreadyExists) continue; // lost race, harmless
            return e;
        };
        defer dst_file.close();
        try dst_file.writeAll(data);
        count += 1;
    }
    return count;
}

// ---------------------------------------------------------------------------
// Public API
// ---------------------------------------------------------------------------

/// Merge two indices in place.
/// `obj_db` is used to load objects for parent-hash chain walks; call this
/// AFTER copying all objects bidirectionally so ancestor checks work for both
/// sides.
///
/// Titles and paths in the result come from whichever side has the newer HEAD.
pub fn mergeIndexes(
    allocator: std.mem.Allocator,
    obj_db: *Database,
    local_idx: *Index,
    remote_idx: *Index,
) !SyncResult {
    var result = SyncResult{};

    var local_pending: std.ArrayList(Pending) = .{};
    defer local_pending.deinit(allocator);
    var remote_pending: std.ArrayList(Pending) = .{};
    defer remote_pending.deinit(allocator);

    // Pass 1: for each local entry, decide what remote needs.
    for (local_idx.entries.items) |le| {
        if (remote_idx.find(le.entry_id)) |re| {
            if (std.mem.eql(u8, &le.head_hash, &re.head_hash)) continue; // in sync

            if (isAncestor(obj_db, le.head_hash, re.head_hash)) {
                // Remote is ahead → fast-forward local to remote HEAD.
                try local_pending.append(allocator, .{
                    .entry_id = le.entry_id,
                    .head_hash = re.head_hash,
                    .title = re.title,
                    .path = re.path,
                    .kind = .update,
                });
                result.fast_forwarded += 1;
            } else if (isAncestor(obj_db, re.head_hash, le.head_hash)) {
                // Local is ahead → fast-forward remote to local HEAD.
                try remote_pending.append(allocator, .{
                    .entry_id = le.entry_id,
                    .head_hash = le.head_hash,
                    .title = le.title,
                    .path = le.path,
                    .kind = .update,
                });
                result.remote_advanced += 1;
            } else {
                // True divergence: keep local HEAD, report conflict.
                result.conflicts += 1;
            }
        } else {
            // Entry only in local → push to remote.
            try remote_pending.append(allocator, .{
                .entry_id = le.entry_id,
                .head_hash = le.head_hash,
                .title = le.title,
                .path = le.path,
                .kind = .add,
            });
            result.new_to_remote += 1;
        }
    }

    // Pass 2: find remote entries that local doesn't have yet.
    for (remote_idx.entries.items) |re| {
        if (local_idx.find(re.entry_id) == null) {
            try local_pending.append(allocator, .{
                .entry_id = re.entry_id,
                .head_hash = re.head_hash,
                .title = re.title,
                .path = re.path,
                .kind = .add,
            });
            result.new_to_local += 1;
        }
    }

    // Apply local mutations after both passes (avoids ArrayList invalidation).
    for (local_pending.items) |p| {
        switch (p.kind) {
            .add => try local_idx.addEntry(p.entry_id, p.head_hash, p.title, p.path),
            .update => try local_idx.updateEntry(p.entry_id, p.head_hash, p.title, p.path),
        }
    }

    // Apply remote mutations.
    for (remote_pending.items) |p| {
        switch (p.kind) {
            .add => try remote_idx.addEntry(p.entry_id, p.head_hash, p.title, p.path),
            .update => try remote_idx.updateEntry(p.entry_id, p.head_hash, p.title, p.path),
        }
    }

    return result;
}

/// Full local-path sync: bidirectional object copy followed by index merge.
/// Both databases must share the same encryption key (created from the same
/// `header` file). After this call both indices are merged; call `db.save()`
/// on each to persist the result.
pub fn syncDatabases(
    allocator: std.mem.Allocator,
    local_db: *Database,
    remote_db: *Database,
) !SyncResult {
    // Copy objects first so ancestor chain walks have full history on both sides.
    const pulled = try copyObjectsOneWay(allocator, remote_db, local_db);
    const pushed = try copyObjectsOneWay(allocator, local_db, remote_db);

    var result = try mergeIndexes(allocator, local_db, &local_db.index, &remote_db.index);
    result.objects_pulled = pulled;
    result.objects_pushed = pushed;
    return result;
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

test "sync two disjoint plaintext databases" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var local_db = try Database.create(allocator, tmp.dir, "local", null);
    defer local_db.deinit();

    var remote_db = try Database.create(allocator, tmp.dir, "remote", null);
    defer remote_db.deinit();

    // Add one entry to each side.
    _ = try local_db.createEntry(.{
        .parent_hash = null,
        .path = "",
        .title = "Local Entry",
        .description = "",
        .url = "",
        .username = "u",
        .password = "p",
        .notes = "",
    });
    _ = try remote_db.createEntry(.{
        .parent_hash = null,
        .path = "",
        .title = "Remote Entry",
        .description = "",
        .url = "",
        .username = "r",
        .password = "q",
        .notes = "",
    });

    const result = try syncDatabases(allocator, &local_db, &remote_db);

    try std.testing.expectEqual(@as(usize, 1), result.objects_pulled);
    try std.testing.expectEqual(@as(usize, 1), result.objects_pushed);
    try std.testing.expectEqual(@as(usize, 1), result.new_to_local);
    try std.testing.expectEqual(@as(usize, 1), result.new_to_remote);
    try std.testing.expectEqual(@as(usize, 0), result.fast_forwarded);
    try std.testing.expectEqual(@as(usize, 0), result.conflicts);

    try std.testing.expectEqual(@as(usize, 2), local_db.listEntries().len);
    try std.testing.expectEqual(@as(usize, 2), remote_db.listEntries().len);
}

test "sync: remote ahead fast-forwards local" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var local_db = try Database.create(allocator, tmp.dir, "local", null);
    defer local_db.deinit();
    var remote_db = try Database.create(allocator, tmp.dir, "remote", null);
    defer remote_db.deinit();

    // Create the genesis entry on local.
    const eid = try local_db.createEntry(.{
        .parent_hash = null,
        .path = "",
        .title = "Entry",
        .description = "",
        .url = "",
        .username = "u",
        .password = "v1",
        .notes = "",
    });
    const v1_hash = local_db.listEntries()[0].head_hash;

    // Sync so remote has the genesis.
    _ = try syncDatabases(allocator, &local_db, &remote_db);

    // Advance remote by one version.
    _ = try remote_db.updateEntry(eid, .{
        .parent_hash = v1_hash,
        .path = "",
        .title = "Entry",
        .description = "",
        .url = "",
        .username = "u",
        .password = "v2",
        .notes = "",
    });

    // Second sync: local should fast-forward to v2.
    const result2 = try syncDatabases(allocator, &local_db, &remote_db);
    try std.testing.expectEqual(@as(usize, 1), result2.fast_forwarded);
    try std.testing.expectEqual(@as(usize, 0), result2.conflicts);

    const local_entry = try local_db.getEntry(eid);
    defer local_entry.deinit(allocator);
    try std.testing.expectEqualStrings("v2", local_entry.password);
}

test "sync: diverged entries produce conflict" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var local_db = try Database.create(allocator, tmp.dir, "local", null);
    defer local_db.deinit();
    var remote_db = try Database.create(allocator, tmp.dir, "remote", null);
    defer remote_db.deinit();

    // Shared genesis.
    const eid = try local_db.createEntry(.{
        .parent_hash = null,
        .path = "",
        .title = "Entry",
        .description = "",
        .url = "",
        .username = "u",
        .password = "v0",
        .notes = "",
    });
    const v0_hash = local_db.listEntries()[0].head_hash;

    // Sync genesis to remote.
    _ = try syncDatabases(allocator, &local_db, &remote_db);

    // Both sides independently edit the same entry.
    _ = try local_db.updateEntry(eid, .{
        .parent_hash = v0_hash,
        .path = "",
        .title = "Entry",
        .description = "",
        .url = "",
        .username = "u",
        .password = "local-edit",
        .notes = "",
    });
    _ = try remote_db.updateEntry(eid, .{
        .parent_hash = v0_hash,
        .path = "",
        .title = "Entry",
        .description = "",
        .url = "",
        .username = "u",
        .password = "remote-edit",
        .notes = "",
    });

    const result = try syncDatabases(allocator, &local_db, &remote_db);
    try std.testing.expectEqual(@as(usize, 1), result.conflicts);
    try std.testing.expectEqual(@as(usize, 0), result.fast_forwarded);

    // Local HEAD is retained.
    const local_entry = try local_db.getEntry(eid);
    defer local_entry.deinit(allocator);
    try std.testing.expectEqualStrings("local-edit", local_entry.password);
}
