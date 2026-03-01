const std = @import("std");
const loki = @import("loki");
const utils = @import("utils.zig");

const Database = loki.Database;
const sync = loki.store.sync;
const SyncResult = sync.SyncResult;
const ConflictEntry = sync.ConflictEntry;
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

fn runCommand(argv: []const []const u8, allocator: std.mem.Allocator) !void {
    var child = std.process.Child.init(argv, allocator);
    child.stdin_behavior = .Ignore;
    child.stdout_behavior = .Inherit;
    child.stderr_behavior = .Inherit;
    const term = try child.spawnAndWait();
    switch (term) {
        .Exited => |code| if (code != 0) return error.CommandFailed,
        else => return error.CommandFailed,
    }
}

// ---------------------------------------------------------------------------
// Local sync
// ---------------------------------------------------------------------------

fn runLocal(
    allocator: std.mem.Allocator,
    local_path: []const u8,
    remote_path: []const u8,
    out: std.fs.File,
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
            try out.writeAll("Error: wrong password for local database\n");
            return;
        }
        return err;
    };
    defer local_db.deinit();

    var remote_db = utils.openDb(allocator, remote_path, pw_slice) catch |err| {
        if (err == error.WrongPassword) {
            try out.writeAll("Error: wrong password for remote database (different password?)\n");
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

    try printResult(allocator, out, result);
}

// ---------------------------------------------------------------------------
// SSH sync (uses rsync for objects transport)
// ---------------------------------------------------------------------------

/// Split an SSH remote spec into host part (including colon) and path part.
/// e.g. "user@host:/path" → host="user@host:", path="/path"
fn splitSshRemote(remote: []const u8) struct { host: []const u8, path: []const u8 } {
    const colon = std.mem.indexOfScalar(u8, remote, ':').?;
    return .{ .host = remote[0 .. colon + 1], .path = remote[colon + 1 ..] };
}

fn runSsh(
    allocator: std.mem.Allocator,
    local_path: []const u8,
    remote: []const u8,
    out: std.fs.File,
) !void {
    const parts = splitSshRemote(remote);
    const remote_host = parts.host; // e.g. "user@host:"
    const remote_db_path = parts.path; // e.g. "/home/user/.loki"

    // Paths for rsync specs.
    const remote_objects = try std.fmt.allocPrint(
        allocator,
        "{s}{s}/objects/",
        .{ remote_host, remote_db_path },
    );
    defer allocator.free(remote_objects);
    const remote_index = try std.fmt.allocPrint(
        allocator,
        "{s}{s}/index",
        .{ remote_host, remote_db_path },
    );
    defer allocator.free(remote_index);

    const local_objects = try std.fmt.allocPrint(allocator, "{s}/objects/", .{local_path});
    defer allocator.free(local_objects);

    // Temp dir for the remote index file.
    var rand_bytes: [4]u8 = undefined;
    std.crypto.random.bytes(&rand_bytes);
    const rand_hex = std.fmt.bytesToHex(rand_bytes, .lower);
    const tmp_dir = try std.fmt.allocPrint(allocator, "/tmp/loki_sync_{s}", .{&rand_hex});
    defer allocator.free(tmp_dir);
    try std.fs.makeDirAbsolute(tmp_dir);
    defer std.fs.cwd().deleteTree(tmp_dir) catch {};

    const tmp_index = try std.fmt.allocPrint(allocator, "{s}/index", .{tmp_dir});
    defer allocator.free(tmp_index);
    const tmp_index_merged = try std.fmt.allocPrint(allocator, "{s}/index_merged", .{tmp_dir});
    defer allocator.free(tmp_index_merged);

    // 1. Rsync objects: remote → local (pull new objects).
    try out.writeAll("Pulling objects...\n");
    runCommand(&.{ "rsync", "-aq", "--ignore-existing", remote_objects, local_objects }, allocator) catch |err| {
        if (err == error.CommandFailed) {
            // rsync may exit non-zero if remote objects dir is empty; continue.
        } else return err;
    };

    // 2. Rsync objects: local → remote (push new objects).
    try out.writeAll("Pushing objects...\n");
    runCommand(&.{ "rsync", "-aq", "--ignore-existing", local_objects, remote_objects }, allocator) catch |err| {
        if (err == error.CommandFailed) {
            // Tolerate non-fatal rsync errors.
        } else return err;
    };

    // 3. Open local db (to get key and local index).
    const local_enc = utils.detectEncrypted(local_path);
    var password: ?[]u8 = null;
    defer if (password) |pw| allocator.free(pw);
    if (local_enc) {
        password = try utils.promptPassword(allocator);
    }
    const pw_slice: ?[]const u8 = if (password) |pw| pw else null;

    var local_db = utils.openDb(allocator, local_path, pw_slice) catch |err| {
        if (err == error.WrongPassword) {
            try out.writeAll("Error: wrong password\n");
            return;
        }
        return err;
    };
    defer local_db.deinit();

    // 4. Fetch remote index.
    try out.writeAll("Fetching remote index...\n");
    const remote_has_index = blk: {
        runCommand(&.{ "rsync", "-aq", remote_index, tmp_index }, allocator) catch {
            break :blk false;
        };
        break :blk true;
    };

    // 5. Parse remote index.
    var remote_idx = if (remote_has_index) blk: {
        const raw = try std.fs.cwd().readFileAlloc(allocator, tmp_index, 64 * 1024 * 1024);
        defer allocator.free(raw);
        const plaintext = if (local_db.key) |k|
            try cipher_mod.decrypt(allocator, k, raw)
        else
            try allocator.dupe(u8, raw);
        defer allocator.free(plaintext);
        break :blk try Index.fromBytes(allocator, plaintext);
    } else Index.init(allocator);
    defer remote_idx.deinit();

    // 6. Merge indices.
    var conflicts: std.ArrayList(ConflictEntry) = .{};
    defer conflicts.deinit(allocator);
    var result = try sync.mergeIndexes(allocator, &local_db, &local_db.index, &remote_idx, &conflicts);
    result.objects_pulled = 0; // rsync handled this; counts not available
    result.objects_pushed = 0;
    if (conflicts.items.len > 0) try local_db.saveConflicts(conflicts.items);

    // 7. Save local db.
    try local_db.save();

    // 8. Serialize merged remote index and push back.
    var idx_buf: std.Io.Writer.Allocating = .init(allocator);
    defer idx_buf.deinit();
    try remote_idx.writeTo(&idx_buf.writer);

    const merged_bytes = if (local_db.key) |k|
        try cipher_mod.encrypt(allocator, k, idx_buf.written())
    else
        try allocator.dupe(u8, idx_buf.written());
    defer allocator.free(merged_bytes);

    const merged_file = try std.fs.cwd().createFile(tmp_index_merged, .{});
    try merged_file.writeAll(merged_bytes);
    merged_file.close();

    try out.writeAll("Pushing merged index...\n");
    try runCommand(&.{ "rsync", "-aq", tmp_index_merged, remote_index }, allocator);

    try printResult(allocator, out, result);
}

// ---------------------------------------------------------------------------
// Entry point
// ---------------------------------------------------------------------------

pub fn run(
    allocator: std.mem.Allocator,
    local_path: []const u8,
    remote_path: []const u8,
) !void {
    const out = std.fs.File.stdout();
    const header = try std.fmt.allocPrint(allocator, "Syncing {s} <-> {s}\n", .{ local_path, remote_path });
    defer allocator.free(header);
    try out.writeAll(header);

    const is_ssh = std.mem.indexOfScalar(u8, remote_path, ':') != null;
    if (is_ssh) {
        try runSsh(allocator, local_path, remote_path, out);
    } else {
        try runLocal(allocator, local_path, remote_path, out);
    }
    try out.writeAll("Done.\n");
}
