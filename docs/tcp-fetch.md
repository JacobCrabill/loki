# Loki TCP Fetch Protocol

The fetch protocol is a one-shot, client-initiated download that creates a fresh local copy of a
remote encrypted database. It is used when a device does not yet have any local database at all —
the first-time clone scenario. Subsequent synchronisation uses the [sync protocol](tcp-sync.md).

Like the sync protocol, fetch requires an encrypted database. The shared password serves as the
pre-shared key.

## Overview

```
Client                                      Server
  |──── challenge [32 bytes] ─────────────>|  1. client proves it can drive auth
  |<─── header_len [4 bytes] ──────────────| \
  |<─── header [header_len bytes] ─────────|  2. server sends KDF header
  |<─── hmac [32 bytes] ───────────────────| /   + proof of password knowledge

  (client verifies HMAC; aborts if invalid)
  (client runs Argon2id; aborts if wrong password)

  |──── nonce_C [32 bytes] ───────────── >| \
  |<─── nonce_S [32 bytes] ────────────── | / 3. encrypted session established

  |<─── OBJECT_DATA × all objects ─────── |   4. server pushes entire object store
  |<─── DONE ──────────────────────────── |

  |<─── INDEX_DATA ────────────────────── |   5. server pushes index
```

## Step 1 — Client challenge

The client generates 32 cryptographically random bytes and sends them immediately upon connection,
before receiving anything:

```
Client → Server:  challenge [32 bytes]
```

The challenge is single-use and random; it binds the server's authentication response to this
specific connection, preventing replay of a previously observed valid HMAC.

## Step 2 — Server header + HMAC

The server responds with the raw KDF header (unencrypted, length-prefixed) immediately followed by a
32-byte HMAC:

```
Server → Client:  header_len [u32 LE]
                  header     [header_len bytes]  (always 96 bytes; see storage docs)
                  hmac       [32 bytes]
```

The HMAC is computed as:

```
auth_key = HKDF-SHA256(ikm=db_key, salt=challenge, info="loki-auth-v1")
hmac     = HMAC-SHA256(key=auth_key, msg=header_bytes)
```

`db_key` is the Argon2id-derived database encryption key (32 bytes). Only a party that knows the
database password can produce a correct `auth_key` and therefore a valid HMAC.

The HMAC covers the full header bytes, so any tampering with the KDF parameters, salt, or
verify-blob is also detected.

## Step 3 — Client verification (before writing to disk)

The client performs the following checks entirely in memory, writing nothing to disk until both
pass:

1. **Parse the header** — validate magic bytes and parameter bounds (see
   [storage format](storage-format.md)).

2. **Run Argon2id** — derive `db_key` from the received `salt` and `params` using the supplied
   password.

3. **Verify the HMAC** — recompute `auth_key` and `hmac` locally and compare using a constant-time
   equality check. Failure → `error.AuthenticationFailed`. This error covers both a genuine MITM
   (attacker cannot produce a valid HMAC without knowing `db_key`) and a wrong password (wrong
   password → wrong `db_key` → wrong `auth_key` → HMAC mismatch). The two cases are
   cryptographically indistinguishable at this stage, so both surface as `AuthenticationFailed`
   rather than the more specific `WrongPassword`.

4. **Verify the password via the verify-blob** — decrypt the AEAD verify-blob embedded in the
   header (see [storage format](storage-format.md)). Failure → `error.WrongPassword`. At this
   point the header is trusted (HMAC passed), so this failure is definitively a wrong password
   rather than a substitution attack.

Only after both checks pass does the client write the header to disk and open the local database.

## Step 4 — Encrypted session

An encrypted session is established using the same mechanism as the sync protocol, but with a
different `info` string to prevent cross-protocol key reuse:

```
session_key = HKDF-SHA256(
    ikm  = db_key,
    salt = nonce_C ++ nonce_S,
    info = "loki-fetch-v1"          ← differs from "loki-sync-v1"
)
```

The client sends `nonce_C` first; the server replies with `nonce_S`. Message framing, nonce
derivation, and payload format are identical to the sync protocol — see [tcp-sync.md](tcp-sync.md)
.

## Step 5 — Object transfer

The server sends every object in its store as `OBJECT_DATA` messages, followed by a `DONE` message.
The client has no objects yet so no client→server object transfer occurs.

The receiver verifies each object's integrity exactly as in the sync protocol: after decrypting the
payload data, `SHA-1(plaintext)` must equal the `hash` field in the message.

## Step 6 — Index transfer

The server sends a single `INDEX_DATA` message containing its encrypted index. The client replaces
its (empty) local index with the received one and saves to disk.

No index merge is performed — the client is starting from scratch, so the server's index is
authoritative.

## Security Properties

| Property                        | Mechanism                                                       |
| ------------------------------- | --------------------------------------------------------------- |
| Server authentication           | HMAC-SHA256 over header bytes, keyed with `db_key`              |
| Replay prevention (auth)        | HMAC is bound to the client's random challenge                  |
| Header integrity                | HMAC covers all header bytes; any tampering invalidates it      |
| Downgrade prevention            | AEAD additional data in verify-blob binds KDF params to the key |
| Confidentiality                 | ChaCha20-Poly1305 session encryption for all objects and index  |
| Object integrity                | SHA-1(plaintext) verified by client before storing              |
| Wrong password                  | Detected via verify-blob after HMAC passes                      |
| No filesystem writes on failure | Client writes nothing until both auth and password checks pass  |

## CLI Usage

```
loki fetch <host:port> [db_name]   download a remote database for the first time
                                    (default name: derived from host)
```
