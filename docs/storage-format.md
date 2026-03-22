# Loki Storage Format

This document describes how a Loki database is laid out on disk, how password-based encryption is
applied, how individual entries and their history are stored, and how the index ties everything
together.

## Directory Layout

A database named `mydb` is a single directory:

```
mydb/
├── header          KDF parameters, salt, and password-verification blob (96 bytes)
├── index           Encrypted index: maps entry IDs to current HEADs and metadata
├── conflicts       Optional: pending merge conflicts awaiting TUI resolution
└── objects/
    ├── <sha1-hex>  Encrypted entry object (one file per version)
    ├── <sha1-hex>
    └── ...
```

All sensitive data (entry content and the index) is encrypted with ChaCha20-Poly1305 using a key
derived from the user's password. The `header` file is not encrypted but is authenticated — see
below.

## Password-Based Encryption

### Key Derivation

When a database is created, a fresh 32-byte random salt is generated and the user's password is
passed through **Argon2id** (OWASP recommended parameters by default: `t=2, m=19456 KiB, p=1`) to
produce a 32-byte encryption key:

```
db_key = Argon2id(
    password = <user password>,
    salt     = <random 32 bytes>,
    t        = iterations,
    m        = memory (KiB),
    p        = parallelism,
    len      = 32
)
```

`db_key` is held in memory only for the lifetime of the open database and is never written to disk.

### The `header` File (96 bytes)

The `header` file stores everything needed to re-derive `db_key` and verify the password, without
storing the key or password themselves.

```
Offset  Size  Field
──────  ────  ─────────────────────────────────────────────────────────────
     0     8  magic: "LOKIDB\x00\x01"
     8     4  argon2 t  (u32 little-endian)
    12     4  argon2 m  (u32 little-endian, KiB)
    16     4  argon2 p  (u32 little-endian, fits in u24)
    20    32  salt
    52    44  verify_blob
```

`verify_blob` is a ChaCha20-Poly1305 ciphertext of the 16-byte known plaintext `"LOKI_HDR_VERIFY!"`,
using `db_key` as the key.

```
verify_blob layout (44 bytes):
  [nonce: 12 bytes][tag: 16 bytes][ciphertext: 16 bytes]
```

The AEAD additional data (AD) for the verify-blob is the first 52 bytes of the header (magic + all
three KDF parameters + salt). This binds the verify-blob to the exact parameter set used to derive
`db_key`, preventing a downgrade attack where an attacker replaces the KDF parameters with weaker
ones:

```
AD = magic ++ u32_le(t) ++ u32_le(m) ++ u32_le(p) ++ salt   // 52 bytes
```

**Opening a database** re-runs Argon2id with the stored salt and parameters, attempts to decrypt the
verify-blob, and succeeds only if the plaintext equals `"LOKI_HDR_VERIFY!"`. A wrong password fails
the Poly1305 tag check.

**Parameter bounds** enforced on read: `t ∈ [1, 65535]`, `m ∈ [8, 4194304]`, `p ∈ [1, 255]`. A
header with out-of-range values is rejected before the KDF is invoked.

---

## Entry Objects

Each version of a password entry is stored as a separate file in `objects/`. The filename is the
40-character lowercase hex encoding of `SHA-1(plaintext)` — i.e. the hash of the serialised,
unencrypted entry.

### Object file layout (encrypted database)

```
[nonce: 12 bytes][tag: 16 bytes][ciphertext: N bytes]
```

This is a standard ChaCha20-Poly1305 blob produced by the cipher layer. The nonce is randomly
generated per-object. There are no additional data (AD) bytes; the tag authenticates only the
ciphertext.

Decryption yields the plaintext entry — the serialised binary format described in the next
section.

### Entry serialisation format

```
Field                   Size
──────────────────────  ────────────────────────────────────────────
flags                   1 byte   bit 0 = has parent_hash
                                 bit 1 = has merge_parent_hash
parent_hash             20 bytes (present iff bit 0 set)
merge_parent_hash       20 bytes (present iff bit 1 set)
path length             4 bytes  u32 little-endian
path                    N bytes  UTF-8, forward-slash-separated folder path
title length            4 bytes  u32 little-endian
title                   N bytes  UTF-8
description length      4 bytes  u32 little-endian
description             N bytes  UTF-8
url length              4 bytes  u32 little-endian
url                     N bytes  UTF-8
username length         4 bytes  u32 little-endian
username                N bytes  UTF-8
password length         4 bytes  u32 little-endian
password                N bytes  UTF-8
notes length            4 bytes  u32 little-endian
notes                   N bytes  UTF-8
```

String fields use a 4-byte length prefix followed by the UTF-8 bytes. Empty strings are encoded as a
4-byte zero.

---

## Version History

Loki uses an append-only, content-addressed history modelled loosely on Git objects.

### How history is stored

Every time an entry is created or updated, a new object file is written. Objects are never modified
or deleted. The `parent_hash` field in each entry points to the previous version's object hash,
forming a singly-linked chain:

```
genesis (parent_hash = null)
    └─▶ v1 (parent_hash = hash(genesis))
            └─▶ v2 (parent_hash = hash(v1))
                    └─▶ ...
```

The hash of the genesis object serves as the stable **entry ID** throughout the entry's lifetime,
regardless of how many times it is updated.

### Merge commits

When a sync conflict is resolved in the TUI, a merge commit is created with two parent pointers:

```
merge_parent_hash ──┐
                    ▼
    ... ──▶ local_edit ──▶ merge_commit
                    ▲
    ... ──▶ remote_edit ──┘  (via merge_parent_hash)
```

`merge_parent_hash` allows the ancestry check used during sync to follow both branches of the
history. On the next sync the remote fast-forwards to the merge commit rather than re-detecting the
already-resolved conflict.

### Entry IDs

The entry ID is `SHA-1` of the genesis object's plaintext. Because it is derived from immutable
content (the genesis serialisation), it is stable across all devices and all future versions of the
entry.

---

## The `index` File

The index is a compact in-memory data structure that maps entry IDs to their current HEAD hash and
caches human-readable metadata (title and path) to allow fast listing without decrypting individual
objects.

### On-disk format (before encryption)

```
Offset  Size  Field
──────  ────  ─────────────────────────────────────────────────────────────
     0     8  magic: "LOKIIDX\x00"
     8     4  entry count (u32 little-endian)

Per entry (repeated entry-count times):
     0    20  entry_id   (SHA-1 of genesis object plaintext)
    20    20  head_hash  (SHA-1 of current HEAD object plaintext)
    40     2  title length (u16 little-endian)
    42     N  title (UTF-8)
  42+N     2  path length (u16 little-endian)
44+N       M  path (UTF-8, forward-slash-separated)
```

The maximum title and path lengths are bounded by the u16 prefix (65535 bytes each).

### Encryption

When saved to disk, the entire serialised index is encrypted as a single ChaCha20-Poly1305 blob
(identical layout to an object file: nonce + tag + ciphertext). This means the number of entries,
their titles, and their paths are all protected.

---

## The `conflicts` File

The `conflicts` file is written only when a sync produces unresolved conflicts. It is **not**
encrypted (conflict records contain only opaque hash values, no plaintext passwords or metadata).

```
Offset  Size  Field
──────  ────  ─────────────────────────────────────────────────────────────
     0     4  conflict count (u32 little-endian)

Per conflict (60 bytes each):
     0    20  entry_id
    20    20  local_hash   (local HEAD at time of conflict)
    40    20  remote_hash  (remote HEAD at time of conflict)
```

The TUI reads this file to present both versions to the user for resolution. After resolution the
file is deleted.

## Security Notes

- `db_key` is never written to disk. It exists only in process memory while the database is open.
- Each object is encrypted with an independently randomly-chosen nonce. Nonce reuse across objects
  is astronomically unlikely (96-bit random nonce space).
- The object filename (`SHA-1(plaintext)`) is the same across all devices that share the database.
  An attacker with filesystem access but without the password can observe which objects are present
  and whether two databases share the same entry versions, but cannot read entry content.
- SHA-1 is used as the content-addressing hash. While SHA-1 is collision-broken in the general case,
  practical exploitation requires the ability to influence plaintexts before they are encrypted,
  which is not the attack model here. A future migration to SHA-256 is advisable.
