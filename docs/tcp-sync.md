# Loki TCP Sync Protocol

Loki can sync two encrypted databases directly over TCP using the shared
database password as a pre-shared key (PSK). No SSL/TLS certificate
infrastructure is required; MITM resistance comes from the fact that an
attacker without the password cannot forge valid AEAD ciphertexts or pass
the implicit mutual authentication check.

Only encrypted databases are supported — an unencrypted database has no
shared secret to anchor the session.

---

## Session Establishment

```
Client                                  Server
  |──── nonce_C [32 bytes] ────────────>|
  |<─── nonce_S [32 bytes] ─────────────|
```

Both sides independently derive a one-time session key:

```
session_key = HKDF-SHA256(
    ikm  = db_key,            // Argon2id-derived database key (32 bytes)
    salt = nonce_C ++ nonce_S, // 64 bytes
    info = "loki-sync-v1"
)
```

The session key is separate from the database encryption key, preventing
cross-context key reuse. No explicit challenge-response is needed: the
first message that decrypts successfully proves both sides know `db_key`.

---

## Message Framing

All messages after the nonce exchange are encrypted. Wire layout:

```
┌─────────────────┬──────────────────────────────────────┐
│ len: u32 LE     │ ciphertext: bytes × len              │
└─────────────────┴──────────────────────────────────────┘
                         │
                         ▼
              ┌──────────┬─────────────────┐
              │ tag [16] │ ciphertext [..] │
              └──────────┴─────────────────┘
```

`len` includes the 16-byte Poly1305 tag. Plaintext length is `len - 16`.

### Nonce Derivation

Nonces are derived from a per-direction counter and never transmitted:

```
client_send_nonce(n) = [0x00, 0x00, 0x00, 0x00] ++ u64_le(n)   // 12 bytes
server_send_nonce(n) = [0x01, 0x00, 0x00, 0x00] ++ u64_le(n)   // 12 bytes
```

Each side maintains a send counter (starts at 0, increments per message)
and a receive counter (mirrors the peer's send counter). Out-of-order or
replayed messages fail AEAD authentication.

---

## Payload Format

Plaintext payload before encryption:

```
┌──────────────┬───────────────┐
│ type: u8     │ body: [..]    │
└──────────────┴───────────────┘
```

| Type | Name          | Body |
|------|---------------|------|
| 0x01 | `OBJECT_LIST` | `count: u32` + `hash: [20]u8 × count` |
| 0x02 | `OBJECT_DATA` | `hash: [20]u8` + `data: [..]` (rest of payload) |
| 0x03 | `INDEX_DATA`  | `data: [..]` (rest of payload) |
| 0x04 | `DONE`        | (empty) |
| 0x05 | `ERROR`       | `message: [..]` (UTF-8, rest of payload) |

Maximum message size: 8 MiB. Larger messages are a protocol error.

---

## Sync Flow

The client drives the protocol. All steps are sequential.

```
Client                                  Server
  |──── OBJECT_LIST ──────────────────>|   C sends its object hashes
  |<─── OBJECT_LIST ───────────────────|   S sends its object hashes

  |──── OBJECT_DATA × (S missing) ───>|   C pushes objects S lacks
  |──── DONE ─────────────────────────>|
  |<─── OBJECT_DATA × (C missing) ────|   S pushes objects C lacks
  |<─── DONE ──────────────────────────|

  |──── INDEX_DATA ───────────────────>|   C sends its encrypted index
  |<─── INDEX_DATA ────────────────────|   S sends its encrypted index

  (both sides independently run mergeIndexes and save)
```

### Why symmetric merge works

`mergeIndexes` is deterministic: given the same local index, remote index,
and object history, both sides produce the same merged result. After the
object and index exchange, both sides have identical data and independently
arrive at the same merged index.

Conflicts detected on each side are saved to the local `conflicts` file for
TUI resolution. The conflict set is identical on both sides.

### Object data note

Object files are already ChaCha20-Poly1305 encrypted by the database layer.
The session encryption wraps them a second time during transit. This is
intentional: it prevents an observer from learning object sizes or hashes
from traffic analysis.

---

## Security Properties

| Property | Mechanism |
|----------|-----------|
| Mutual authentication | Session key derived from `db_key`; first decryption proves knowledge |
| Confidentiality | ChaCha20-Poly1305 session encryption |
| Integrity | Poly1305 AEAD tag on every message |
| Replay prevention | Counter-derived nonces; replayed messages fail auth |
| MITM resistance | Attacker without `db_key` cannot forge valid ciphertexts |
| Forward secrecy | Not provided; session key is deterministic from `db_key` + nonces |

---

## CLI Usage

```
loki serve [port] [db_path]        listen for a single incoming sync
                                    (default port: 7777, default db: ~/.loki)

loki connect <host:port> [db_path] connect and sync with a server
                                    (default db: ~/.loki)
```

The server accepts one connection, performs the sync, then exits. For
repeated syncing, restart the server or wrap it in a loop.
