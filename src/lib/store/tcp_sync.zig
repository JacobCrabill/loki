const std = @import("std");
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

/// Read exactly `buf.len` bytes from a stream, retrying on short reads.
fn readExact(conn: std.net.Stream, buf: []u8) !void {
    var total: usize = 0;
    while (total < buf.len) {
        const n = try conn.read(buf[total..]);
        if (n == 0) return error.EndOfStream;
        total += n;
    }
}

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

/// An authenticated, encrypted TCP session derived from the database key.
const Session = struct {
    conn: std.net.Stream,
    key: [32]u8,
    send_counter: u64,
    recv_counter: u64,
    role: Role,

    /// Nonce = [direction(4 bytes)] ++ [counter(8 bytes, LE)].
    /// Client and server use different direction bytes so their nonces never collide.
    fn makeNonce(role: Role, counter: u64) [12]u8 {
        var nonce = std.mem.zeroes([12]u8);
        nonce[0] = switch (role) { .client => 0x00, .server => 0x01 };
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
        try self.conn.writeAll(&len_buf);
        try self.conn.writeAll(blob);
    }

    /// Receive and decrypt one message. Caller must free the returned slice.
    fn recv(self: *Session, allocator: std.mem.Allocator) ![]u8 {
        const peer_role: Role = switch (self.role) { .client => .server, .server => .client };
        const nonce = makeNonce(peer_role, self.recv_counter);
        self.recv_counter += 1;

        var len_buf: [4]u8 = undefined;
        try readExact(self.conn, &len_buf);
        const blob_len = std.mem.readInt(u32, &len_buf, .little);

        if (blob_len < 16) return error.InvalidMessage;
        if (blob_len > max_msg_len) return error.MessageTooLarge;

        const blob = try allocator.alloc(u8, blob_len);
        defer allocator.free(blob);
        try readExact(self.conn, blob);

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
/// Client sends first; server receives first. Both sides derive the same
/// session_key = HKDF(ikm=db_key, salt=nonce_C++nonce_S, info="loki-sync-v1").
fn establishSession(
    db_key: [32]u8,
    conn: std.net.Stream,
    role: Role,
) !Session {
    var nonce_c: [32]u8 = undefined;
    var nonce_s: [32]u8 = undefined;

    switch (role) {
        .client => {
            std.crypto.random.bytes(&nonce_c);
            try conn.writeAll(&nonce_c);
            try readExact(conn, &nonce_s);
        },
        .server => {
            try readExact(conn, &nonce_c);
            std.crypto.random.bytes(&nonce_s);
            try conn.writeAll(&nonce_s);
        },
    }

    var salt: [64]u8 = undefined;
    @memcpy(salt[0..32], &nonce_c);
    @memcpy(salt[32..64], &nonce_s);

    const prk = Hkdf.extract(&salt, &db_key);
    var session_key: [32]u8 = undefined;
    Hkdf.expand(&session_key, "loki-sync-v1", prk);

    return Session{
        .conn = conn,
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

fn sendObjectList(
    allocator: std.mem.Allocator,
    session: *Session,
    hashes: [][20]u8,
) !void {
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
fn recvObjects(
    allocator: std.mem.Allocator,
    session: *Session,
    db: *Database,
) !usize {
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
fn sendIndex(
    allocator: std.mem.Allocator,
    session: *Session,
    db: *Database,
) !void {
    var buf: std.ArrayList(u8) = .{};
    defer buf.deinit(allocator);
    try db.index.writeTo(buf.writer(allocator));

    const encrypted: []u8 = if (db.key) |k|
        try cipher.encrypt(allocator, k, buf.items)
    else
        try allocator.dupe(u8, buf.items);
    defer allocator.free(encrypted);

    const payload = try allocator.alloc(u8, 1 + encrypted.len);
    defer allocator.free(payload);
    payload[0] = @intFromEnum(MsgType.index_data);
    @memcpy(payload[1..], encrypted);
    try session.send(allocator, payload);
}

/// Receive an INDEX_DATA message and parse it into an Index. Caller must call deinit.
fn recvIndex(
    allocator: std.mem.Allocator,
    session: *Session,
    db: *Database,
) !index_mod.Index {
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

/// Sync `db` with a peer over an established TCP connection.
///
/// Both sides must use the same encrypted database (same password → same key).
/// `role` determines message ordering: the client sends first in each phase.
///
/// Conflicts are appended to `conflicts_out`; the database is saved before returning.
/// Returns `error.UnencryptedDatabase` if `db` has no encryption key.
pub fn syncSession(
    allocator: std.mem.Allocator,
    db: *Database,
    conn: std.net.Stream,
    role: Role,
    conflicts_out: *std.ArrayList(ConflictEntry),
) !SyncResult {
    const db_key = db.key orelse return error.UnencryptedDatabase;
    var session = try establishSession(db_key, conn, role);

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
