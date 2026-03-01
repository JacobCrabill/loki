const std = @import("std");
const builtin = @import("builtin");
const cipher = @import("../crypto/cipher.zig");
const index_mod = @import("index.zig");
const object = @import("object.zig");
const sync_mod = @import("sync.zig");
const Database = @import("database.zig").Database;

const AEAD = std.crypto.aead.chacha_poly.ChaCha20Poly1305;
const Hkdf = std.crypto.kdf.hkdf.HkdfSha256;

pub const SyncResult = sync_mod.SyncResult;
pub const ConflictEntry = sync_mod.ConflictEntry;
pub const Role = enum { client, server };

/// Maximum encrypted message size (8 MiB). Protects against malformed length prefixes.
const max_msg_len: u32 = 8 * 1024 * 1024;

const MsgType = enum(u8) {
    object_list = 0x01,
    object_data = 0x02,
    index_data = 0x03,
    done = 0x04,
    err = 0x05,
    _,
};

// ---------------------------------------------------------------------------
// Session
// ---------------------------------------------------------------------------

const Session = struct {
    reader: *std.Io.Reader,
    writer: *std.Io.Writer,
    key: [32]u8,
    send_counter: u64,
    recv_counter: u64,
    role: Role,

    /// Nonce = [direction(4 bytes)] ++ [counter(8 bytes, LE)].
    /// Client and server use different direction bytes so their nonces never collide.
    fn makeNonce(role: Role, counter: u64) [12]u8 {
        var nonce = std.mem.zeroes([12]u8);
        nonce[0] = switch (role) {
            .client => 0x00,
            .server => 0x01,
        };
        std.mem.writeInt(u64, nonce[4..12], counter, .little);
        return nonce;
    }

    /// Encrypt and send one message. Wire format: [len: u32 LE][tag: 16][ciphertext].
    fn send(self: *Session, allocator: std.mem.Allocator, payload: []const u8) !void {
        const nonce = makeNonce(self.role, self.send_counter);
        self.send_counter += 1;

        const blob_len: u32 = @intCast(16 + payload.len);
        const blob = try allocator.alloc(u8, blob_len);
        defer allocator.free(blob);

        var tag: [16]u8 = undefined;
        AEAD.encrypt(blob[16..], &tag, payload, "", nonce, self.key);
        @memcpy(blob[0..16], &tag);

        var len_buf: [4]u8 = undefined;
        std.mem.writeInt(u32, &len_buf, blob_len, .little);
        try self.writer.writeAll(&len_buf);
        try self.writer.writeAll(blob);
    }

    /// Receive and decrypt one message. Caller must free the returned slice.
    fn recv(self: *Session, allocator: std.mem.Allocator) ![]u8 {
        const peer_role: Role = switch (self.role) {
            .client => .server,
            .server => .client,
        };
        const nonce = makeNonce(peer_role, self.recv_counter);
        self.recv_counter += 1;

        var len_buf: [4]u8 = undefined;
        try self.reader.readSliceAll(&len_buf);
        const blob_len = std.mem.readInt(u32, &len_buf, .little);

        if (blob_len < 16) return error.InvalidMessage;
        if (blob_len > max_msg_len) return error.MessageTooLarge;

        const blob = try self.reader.readAlloc(allocator, blob_len);
        defer allocator.free(blob);

        var tag: [16]u8 = undefined;
        @memcpy(&tag, blob[0..16]);

        const plaintext = try allocator.alloc(u8, blob_len - 16);
        errdefer allocator.free(plaintext);
        try AEAD.decrypt(plaintext, blob[16..], tag, "", nonce, self.key);
        return plaintext;
    }
};

// ---------------------------------------------------------------------------
// Session establishment
// ---------------------------------------------------------------------------

/// Exchange nonces and derive a one-time session key via HKDF-SHA256.
/// Client sends first; server receives first. Both derive:
///   session_key = HKDF(ikm=db_key, salt=nonce_C++nonce_S, info="loki-sync-v1")
fn establishSession(
    db_key: [32]u8,
    reader: *std.Io.Reader,
    writer: *std.Io.Writer,
    role: Role,
) !Session {
    var nonce_c: [32]u8 = undefined;
    var nonce_s: [32]u8 = undefined;

    switch (role) {
        .client => {
            std.crypto.random.bytes(&nonce_c);
            try writer.writeAll(&nonce_c);
            try reader.readSliceAll(&nonce_s);
        },
        .server => {
            try reader.readSliceAll(&nonce_c);
            std.crypto.random.bytes(&nonce_s);
            try writer.writeAll(&nonce_s);
        },
    }

    var salt: [64]u8 = undefined;
    @memcpy(salt[0..32], &nonce_c);
    @memcpy(salt[32..64], &nonce_s);

    const prk = Hkdf.extract(&salt, &db_key);
    var session_key: [32]u8 = undefined;
    Hkdf.expand(&session_key, "loki-sync-v1", prk);

    return .{
        .reader = reader,
        .writer = writer,
        .key = session_key,
        .send_counter = 0,
        .recv_counter = 0,
        .role = role,
    };
}

// ---------------------------------------------------------------------------
// Phase 1: object list exchange
// ---------------------------------------------------------------------------

fn listObjectHashes(allocator: std.mem.Allocator, db: *Database) ![][20]u8 {
    var list: std.ArrayList([20]u8) = .{};
    errdefer list.deinit(allocator);

    var iter_dir = try db.dir.openDir("objects", .{ .iterate = true });
    defer iter_dir.close();

    var iter = iter_dir.iterate();
    while (try iter.next()) |ent| {
        if (ent.kind != .file) continue;
        if (ent.name.len != 40) continue;
        const h = try object.hexToHash(ent.name);
        try list.append(allocator, h);
    }
    return list.toOwnedSlice(allocator);
}

fn sendObjectList(allocator: std.mem.Allocator, session: *Session, hashes: [][20]u8) !void {
    const payload = try allocator.alloc(u8, 1 + 4 + hashes.len * 20);
    defer allocator.free(payload);
    payload[0] = @intFromEnum(MsgType.object_list);
    std.mem.writeInt(u32, payload[1..5], @intCast(hashes.len), .little);
    for (hashes, 0..) |h, i| {
        @memcpy(payload[5 + i * 20 ..][0..20], &h);
    }
    try session.send(allocator, payload);
}

/// Caller must free the returned slice.
fn recvObjectList(allocator: std.mem.Allocator, session: *Session) ![][20]u8 {
    const msg = try session.recv(allocator);
    defer allocator.free(msg);
    if (msg.len < 5) return error.InvalidMessage;
    if (@as(MsgType, @enumFromInt(msg[0])) != .object_list) return error.UnexpectedMessage;
    const count = std.mem.readInt(u32, msg[1..5], .little);
    if (msg.len != 5 + @as(usize, count) * 20) return error.InvalidMessage;
    const hashes = try allocator.alloc([20]u8, count);
    for (hashes, 0..) |*h, i| {
        @memcpy(h, msg[5 + i * 20 ..][0..20]);
    }
    return hashes;
}

// ---------------------------------------------------------------------------
// Phase 2: object transfer
// ---------------------------------------------------------------------------

/// Send all local objects that the remote does not have, then send DONE.
fn sendMissingObjects(
    allocator: std.mem.Allocator,
    session: *Session,
    db: *Database,
    remote_hashes: [][20]u8,
    local_hashes: [][20]u8,
) !usize {
    var count: usize = 0;
    for (local_hashes) |h| {
        const remote_has = for (remote_hashes) |rh| {
            if (std.mem.eql(u8, &h, &rh)) break true;
        } else false;
        if (remote_has) continue;

        const hex = object.hashToHex(h);
        const file = db.objects_dir.openFile(&hex, .{}) catch |err| {
            if (err == error.FileNotFound) continue;
            return err;
        };
        defer file.close();
        const raw = try file.readToEndAlloc(allocator, max_msg_len);
        defer allocator.free(raw);

        // Payload: [type(1)][hash(20)][data]
        const payload = try allocator.alloc(u8, 1 + 20 + raw.len);
        defer allocator.free(payload);
        payload[0] = @intFromEnum(MsgType.object_data);
        @memcpy(payload[1..21], &h);
        @memcpy(payload[21..], raw);
        try session.send(allocator, payload);
        count += 1;
    }
    try session.send(allocator, &[_]u8{@intFromEnum(MsgType.done)});
    return count;
}

/// Receive OBJECT_DATA messages until DONE. Write each object to the local store.
fn recvObjects(allocator: std.mem.Allocator, session: *Session, db: *Database) !usize {
    var count: usize = 0;
    while (true) {
        const msg = try session.recv(allocator);
        defer allocator.free(msg);
        if (msg.len == 0) return error.InvalidMessage;
        switch (@as(MsgType, @enumFromInt(msg[0]))) {
            .done => break,
            .object_data => {
                if (msg.len < 21) return error.InvalidMessage;
                var h: [20]u8 = undefined;
                @memcpy(&h, msg[1..21]);
                const hex = object.hashToHex(h);
                const f = db.objects_dir.createFile(&hex, .{ .exclusive = true }) catch |err| {
                    if (err == error.PathAlreadyExists) continue;
                    return err;
                };
                defer f.close();
                try f.writeAll(msg[21..]);
                count += 1;
            },
            .err => return error.RemoteError,
            else => return error.UnexpectedMessage,
        }
    }
    return count;
}

// ---------------------------------------------------------------------------
// Phase 3: index exchange and merge
// ---------------------------------------------------------------------------

/// Serialize the in-memory index, encrypt it, and send it.
fn sendIndex(allocator: std.mem.Allocator, session: *Session, db: *Database) !void {
    var buf: std.Io.Writer.Allocating = .init(allocator);
    defer buf.deinit();
    try db.index.writeTo(&buf.writer);

    const encrypted: []u8 = if (db.key) |k|
        try cipher.encrypt(allocator, k, buf.written())
    else
        try allocator.dupe(u8, buf.written());
    defer allocator.free(encrypted);

    const payload = try allocator.alloc(u8, 1 + encrypted.len);
    defer allocator.free(payload);
    payload[0] = @intFromEnum(MsgType.index_data);
    @memcpy(payload[1..], encrypted);
    try session.send(allocator, payload);
}

/// Receive an INDEX_DATA message and parse it into an Index. Caller must call deinit.
fn recvIndex(allocator: std.mem.Allocator, session: *Session, db: *Database) !index_mod.Index {
    const msg = try session.recv(allocator);
    defer allocator.free(msg);
    if (msg.len < 1 or @as(MsgType, @enumFromInt(msg[0])) != .index_data)
        return error.UnexpectedMessage;

    const plaintext: []u8 = if (db.key) |k|
        try cipher.decrypt(allocator, k, msg[1..])
    else
        try allocator.dupe(u8, msg[1..]);
    defer allocator.free(plaintext);

    return index_mod.Index.fromBytes(allocator, plaintext);
}

// ---------------------------------------------------------------------------
// Public API
// ---------------------------------------------------------------------------

/// Sync `db` with a peer over a reader/writer pair.
///
/// Both sides must use the same encrypted database (same password → same key).
/// `role` determines message ordering: the client sends first in each phase.
///
/// Conflicts are appended to `conflicts_out`; the database is saved before returning.
/// Returns `error.UnencryptedDatabase` if `db` has no encryption key.
///
/// For TCP: obtain `reader`/`writer` via `stream.reader(&buf).interface()` and `&stream.writer(&buf).interface`.
/// For pipes/tests: obtain via `&file.readerStreaming(&buf).interface` and `&file.writerStreaming(&buf).interface`.
pub fn syncSession(
    allocator: std.mem.Allocator,
    db: *Database,
    reader: *std.Io.Reader,
    writer: *std.Io.Writer,
    role: Role,
    conflicts_out: *std.ArrayList(ConflictEntry),
) !SyncResult {
    const db_key = db.key orelse return error.UnencryptedDatabase;
    var session = try establishSession(db_key, reader, writer, role);

    // Phase 1: exchange object lists (client sends first)
    const local_hashes = try listObjectHashes(allocator, db);
    defer allocator.free(local_hashes);

    const remote_hashes: [][20]u8 = switch (role) {
        .client => blk: {
            try sendObjectList(allocator, &session, local_hashes);
            break :blk try recvObjectList(allocator, &session);
        },
        .server => blk: {
            const rh = try recvObjectList(allocator, &session);
            try sendObjectList(allocator, &session, local_hashes);
            break :blk rh;
        },
    };
    defer allocator.free(remote_hashes);

    // Phase 2: object transfer (client sends first, then server)
    var objects_pushed: usize = 0;
    var objects_pulled: usize = 0;
    switch (role) {
        .client => {
            objects_pushed = try sendMissingObjects(allocator, &session, db, remote_hashes, local_hashes);
            objects_pulled = try recvObjects(allocator, &session, db);
        },
        .server => {
            objects_pulled = try recvObjects(allocator, &session, db);
            objects_pushed = try sendMissingObjects(allocator, &session, db, remote_hashes, local_hashes);
        },
    }

    // Phase 3: index exchange and merge (client sends first, then server)
    var result: SyncResult = switch (role) {
        .client => blk: {
            try sendIndex(allocator, &session, db);
            var remote_idx = try recvIndex(allocator, &session, db);
            defer remote_idx.deinit();
            break :blk try sync_mod.mergeIndexes(allocator, db, &db.index, &remote_idx, conflicts_out);
        },
        .server => blk: {
            var remote_idx = try recvIndex(allocator, &session, db);
            defer remote_idx.deinit();
            try sendIndex(allocator, &session, db);
            break :blk try sync_mod.mergeIndexes(allocator, db, &db.index, &remote_idx, conflicts_out);
        },
    };

    result.objects_pushed = objects_pushed;
    result.objects_pulled = objects_pulled;

    try db.save();
    if (conflicts_out.items.len > 0) try db.saveConflicts(conflicts_out.items);

    return result;
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

/// Create a new database directory `name` under `base_dir` by copying the
/// header from `src_db` so both databases share the same derived key.
fn testOpenPairedDb(
    allocator: std.mem.Allocator,
    base_dir: std.fs.Dir,
    src_db: *const Database,
    name: []const u8,
    password: []const u8,
) !Database {
    try base_dir.makeDir(name);
    {
        var new_dir = try base_dir.openDir(name, .{});
        defer new_dir.close();
        try new_dir.makeDir("objects");
        const hdr = try src_db.dir.readFileAlloc(allocator, "header", 512);
        defer allocator.free(hdr);
        const f = try new_dir.createFile("header", .{});
        defer f.close();
        try f.writeAll(hdr);
    }
    return Database.open(allocator, base_dir, name, password);
}

const TestServerCtx = struct {
    allocator: std.mem.Allocator,
    db: *Database,
    server: *std.net.Server,
    result: SyncResult = .{},
    err: ?anyerror = null,
};

fn testServerFn(ctx: *TestServerCtx) void {
    const conn = ctx.server.accept() catch |e| {
        ctx.err = e;
        return;
    };
    defer conn.stream.close();
    var r = conn.stream.reader(&.{});
    var w = conn.stream.writer(&.{});
    var conflicts: std.ArrayList(ConflictEntry) = .{};
    defer conflicts.deinit(ctx.allocator);
    ctx.result = syncSession(
        ctx.allocator, ctx.db, r.interface(), &w.interface, .server, &conflicts,
    ) catch |e| blk: {
        ctx.err = e;
        break :blk .{};
    };
}

test "TCP sync: disjoint entries exchanged between client and server" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var client_db = try Database.create(allocator, tmp.dir, "client", "pw");
    defer client_db.deinit();
    var server_db = try testOpenPairedDb(allocator, tmp.dir, &client_db, "server", "pw");
    defer server_db.deinit();

    _ = try client_db.createEntry(.{
        .parent_hash = null, .path = "", .title = "Client Entry",
        .description = "", .url = "", .username = "c", .password = "cp", .notes = "",
    });
    _ = try server_db.createEntry(.{
        .parent_hash = null, .path = "", .title = "Server Entry",
        .description = "", .url = "", .username = "s", .password = "sp", .notes = "",
    });

    const addr = try std.net.Address.parseIp("127.0.0.1", 0);
    var listener = try addr.listen(.{});
    defer listener.deinit();

    var srv_ctx = TestServerCtx{ .allocator = allocator, .db = &server_db, .server = &listener };
    const thread = try std.Thread.spawn(.{}, testServerFn, .{&srv_ctx});

    const stream = try std.net.tcpConnectToAddress(listener.listen_address);
    defer stream.close();
    var cr = stream.reader(&.{});
    var cw = stream.writer(&.{});
    var client_conflicts: std.ArrayList(ConflictEntry) = .{};
    defer client_conflicts.deinit(allocator);
    const client_result = syncSession(
        allocator, &client_db, cr.interface(), &cw.interface, .client, &client_conflicts,
    );
    thread.join();
    if (srv_ctx.err) |e| return e;
    const result = try client_result;

    try std.testing.expectEqual(@as(usize, 1), result.objects_pushed);
    try std.testing.expectEqual(@as(usize, 1), result.objects_pulled);
    try std.testing.expectEqual(@as(usize, 1), result.new_to_local);
    try std.testing.expectEqual(@as(usize, 1), result.new_to_remote);
    try std.testing.expectEqual(@as(usize, 0), result.conflicts);
    try std.testing.expectEqual(@as(usize, 2), client_db.listEntries().len);
    try std.testing.expectEqual(@as(usize, 2), server_db.listEntries().len);
}

test "TCP sync: client ahead fast-forwards server" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var client_db = try Database.create(allocator, tmp.dir, "client", "pw");
    defer client_db.deinit();
    var server_db = try testOpenPairedDb(allocator, tmp.dir, &client_db, "server", "pw");
    defer server_db.deinit();

    const eid = try client_db.createEntry(.{
        .parent_hash = null, .path = "", .title = "Entry",
        .description = "", .url = "", .username = "u", .password = "v1", .notes = "",
    });
    const v1_hash = client_db.listEntries()[0].head_hash;

    // Initial sync: server gets the genesis.
    {
        const addr = try std.net.Address.parseIp("127.0.0.1", 0);
        var listener = try addr.listen(.{});
        defer listener.deinit();
        var ctx = TestServerCtx{ .allocator = allocator, .db = &server_db, .server = &listener };
        const t = try std.Thread.spawn(.{}, testServerFn, .{&ctx});
        const s = try std.net.tcpConnectToAddress(listener.listen_address);
        defer s.close();
        var r = s.reader(&.{});
        var w = s.writer(&.{});
        var c: std.ArrayList(ConflictEntry) = .{};
        defer c.deinit(allocator);
        const res = syncSession(allocator, &client_db, r.interface(), &w.interface, .client, &c);
        t.join();
        if (ctx.err) |e| return e;
        _ = try res;
    }

    // Advance client to v2.
    _ = try client_db.updateEntry(eid, .{
        .parent_hash = v1_hash, .path = "", .title = "Entry",
        .description = "", .url = "", .username = "u", .password = "v2", .notes = "",
    });

    // Second sync: server should fast-forward to v2.
    const addr2 = try std.net.Address.parseIp("127.0.0.1", 0);
    var listener2 = try addr2.listen(.{});
    defer listener2.deinit();
    var srv_ctx = TestServerCtx{ .allocator = allocator, .db = &server_db, .server = &listener2 };
    const thread2 = try std.Thread.spawn(.{}, testServerFn, .{&srv_ctx});
    const stream2 = try std.net.tcpConnectToAddress(listener2.listen_address);
    defer stream2.close();
    var r2 = stream2.reader(&.{});
    var w2 = stream2.writer(&.{});
    var conflicts2: std.ArrayList(ConflictEntry) = .{};
    defer conflicts2.deinit(allocator);
    const client_result2 = syncSession(
        allocator, &client_db, r2.interface(), &w2.interface, .client, &conflicts2,
    );
    thread2.join();
    if (srv_ctx.err) |e| return e;
    const result2 = try client_result2;

    try std.testing.expectEqual(@as(usize, 1), result2.objects_pushed);
    try std.testing.expectEqual(@as(usize, 0), result2.objects_pulled);
    try std.testing.expectEqual(@as(usize, 1), result2.remote_advanced);
    try std.testing.expectEqual(@as(usize, 0), result2.conflicts);

    const server_entry = try server_db.getEntry(eid);
    defer server_entry.deinit(allocator);
    try std.testing.expectEqualStrings("v2", server_entry.password);
}

test "TCP sync: diverged entries produce conflict" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var client_db = try Database.create(allocator, tmp.dir, "client", "pw");
    defer client_db.deinit();
    var server_db = try testOpenPairedDb(allocator, tmp.dir, &client_db, "server", "pw");
    defer server_db.deinit();

    const eid = try client_db.createEntry(.{
        .parent_hash = null, .path = "", .title = "Entry",
        .description = "", .url = "", .username = "u", .password = "v0", .notes = "",
    });
    const v0_hash = client_db.listEntries()[0].head_hash;

    // Initial sync: server gets genesis.
    {
        const addr = try std.net.Address.parseIp("127.0.0.1", 0);
        var listener = try addr.listen(.{});
        defer listener.deinit();
        var ctx = TestServerCtx{ .allocator = allocator, .db = &server_db, .server = &listener };
        const t = try std.Thread.spawn(.{}, testServerFn, .{&ctx});
        const s = try std.net.tcpConnectToAddress(listener.listen_address);
        defer s.close();
        var r = s.reader(&.{});
        var w = s.writer(&.{});
        var c: std.ArrayList(ConflictEntry) = .{};
        defer c.deinit(allocator);
        const res = syncSession(allocator, &client_db, r.interface(), &w.interface, .client, &c);
        t.join();
        if (ctx.err) |e| return e;
        _ = try res;
    }

    // Both sides independently update the same entry from the same parent.
    _ = try client_db.updateEntry(eid, .{
        .parent_hash = v0_hash, .path = "", .title = "Entry",
        .description = "", .url = "", .username = "u", .password = "client-edit", .notes = "",
    });
    _ = try server_db.updateEntry(eid, .{
        .parent_hash = v0_hash, .path = "", .title = "Entry",
        .description = "", .url = "", .username = "u", .password = "server-edit", .notes = "",
    });

    // Second sync: divergence → conflict.
    const addr2 = try std.net.Address.parseIp("127.0.0.1", 0);
    var listener2 = try addr2.listen(.{});
    defer listener2.deinit();
    var srv_ctx = TestServerCtx{ .allocator = allocator, .db = &server_db, .server = &listener2 };
    const thread2 = try std.Thread.spawn(.{}, testServerFn, .{&srv_ctx});
    const stream2 = try std.net.tcpConnectToAddress(listener2.listen_address);
    defer stream2.close();
    var r2 = stream2.reader(&.{});
    var w2 = stream2.writer(&.{});
    var conflicts2: std.ArrayList(ConflictEntry) = .{};
    defer conflicts2.deinit(allocator);
    const client_result2 = syncSession(
        allocator, &client_db, r2.interface(), &w2.interface, .client, &conflicts2,
    );
    thread2.join();
    if (srv_ctx.err) |e| return e;
    const result2 = try client_result2;

    try std.testing.expectEqual(@as(usize, 1), result2.objects_pushed);
    try std.testing.expectEqual(@as(usize, 1), result2.objects_pulled);
    try std.testing.expectEqual(@as(usize, 1), result2.conflicts);
    try std.testing.expectEqual(@as(usize, 1), conflicts2.items.len);
    try std.testing.expectEqual(eid, conflicts2.items[0].entry_id);

    // Client local HEAD is retained.
    const local_entry = try client_db.getEntry(eid);
    defer local_entry.deinit(allocator);
    try std.testing.expectEqualStrings("client-edit", local_entry.password);
}

test "TCP sync: unencrypted database returns error before any IO" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var db = try Database.create(allocator, tmp.dir, "plain", null);
    defer db.deinit();

    // The error fires before any IO, so a fixed empty reader and no-op
    // allocating writer are sufficient stubs.
    var stub_r = std.Io.Reader.fixed(&[_]u8{});
    var stub_w: std.Io.Writer.Allocating = .init(allocator);
    defer stub_w.deinit();
    var conflicts: std.ArrayList(ConflictEntry) = .{};
    defer conflicts.deinit(allocator);

    try std.testing.expectError(
        error.UnencryptedDatabase,
        syncSession(allocator, &db, &stub_r, &stub_w.writer, .client, &conflicts),
    );
}
