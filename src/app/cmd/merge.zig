const std = @import("std");
const loki = @import("loki");

const utils = @import("../utils.zig");

const Database = loki.Database;
const sync = loki.sync.core;
const SyncResult = sync.SyncResult;
const ConflictEntry = loki.model.merge.ConflictEntry;
const cipher_mod = loki.crypto.cipher;
const index_mod = loki.store.index;
const Index = index_mod.Index;

// ---------------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------------

fn printResult(allocator: std.mem.Allocator, out: std.fs.File, result: SyncResult) !void {
    const objects_line = try std.fmt.allocPrint(
        allocator,
        "  Objects:  {d} pulled, {d} pushed\n",
        .{ result.objects_pulled, result.objects_pushed },
    );
    defer allocator.free(objects_line);
    try out.writeAll(objects_line);

    var entries_line = try std.fmt.allocPrint(
        allocator,
        "  Entries:  {d} new to local, {d} new to remote, {d} fast-forwarded",
        .{ result.new_to_local, result.new_to_remote, result.fast_forwarded },
    );
    defer allocator.free(entries_line);

    if (result.remote_advanced > 0) {
        const extended = try std.fmt.allocPrint(
            allocator,
            "{s}, {d} remote advanced",
            .{ entries_line, result.remote_advanced },
        );
        allocator.free(entries_line);
        entries_line = extended;
    }
    try out.writeAll(entries_line);
    try out.writeAll("\n");

    if (result.conflicts > 0) {
        const conflict_line = try std.fmt.allocPrint(
            allocator,
            "  WARNING: {d} conflict(s) — open loki to resolve interactively\n",
            .{result.conflicts},
        );
        defer allocator.free(conflict_line);
        try out.writeAll(conflict_line);
    }
}

pub fn merge(
    allocator: std.mem.Allocator,
    w: *std.Io.Writer,
    local_path: []const u8,
    remote_path: []const u8,
) !void {
    const local_enc = utils.detectEncrypted(local_path);
    const remote_enc = utils.detectEncrypted(remote_path);

    var password: ?[]u8 = null;
    defer if (password) |pw| allocator.free(pw);

    if (local_enc or remote_enc) {
        password = try utils.promptPassword(allocator);
    }
    const pw_slice: ?[]const u8 = if (password) |pw| pw else null;

    var local_db = utils.openDb(allocator, local_path, pw_slice) catch |err| {
        if (err == error.WrongPassword) {
            try w.writeAll("Error: wrong password for local database\n");
            return;
        }
        return err;
    };
    defer local_db.deinit();

    var remote_db = utils.openDb(allocator, remote_path, pw_slice) catch |err| {
        if (err == error.WrongPassword) {
            try w.writeAll("Error: wrong password for remote database (different password?)\n");
            return;
        }
        return err;
    };
    defer remote_db.deinit();

    var conflicts: std.ArrayList(ConflictEntry) = .{};
    defer conflicts.deinit(allocator);
    const result = try sync.syncDatabases(allocator, &local_db, &remote_db, &conflicts);
    if (conflicts.items.len > 0) try local_db.saveConflicts(conflicts.items);
    try local_db.save();
    try remote_db.save();

    try utils.printMergeResult(allocator, w, result);
}
