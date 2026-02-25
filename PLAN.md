# PazzMan Implementation Plan

## Open Decisions (resolve before implementation)

### 1. Storage Format

Option 2 (Git-style object store) is the better fit. Each entry version is a separate encrypted file
named by its SHA-1 hash. An `index` file maps entry IDs to their current HEAD hash. This directly
models the described version history and merge semantics, and avoids loading the entire database
into memory.

### 2. Encryption

- **Key derivation:** Argon2id (`std.crypto.pwhash.argon2`) — modern, memory-hard, available in
  Zig stdlib
- **Object encryption:** ChaCha20-Poly1305 (`std.crypto.aead.chacha_poly`) — fast, authenticated,
  no block-size alignment issues, available in Zig stdlib
- Each object gets a unique random nonce stored alongside the ciphertext

### 3. Remote Sync Protocol

Needs a decision: simple HTTP REST against a dumb file server, a custom TCP protocol, or SSH/rsync.
This can be deferred to Phase 5.

---

## Module Structure

```
src/
  main.zig              -- entry point, program init
  root.zig              -- library root, re-exports

  crypto/
    kdf.zig             -- Argon2id key derivation, salt management
    cipher.zig          -- encrypt/decrypt individual blobs

  store/
    object.zig          -- read/write encrypted objects by SHA-1 hash
    index.zig           -- database index (entry ID → current HEAD hash)
    database.zig        -- open/create/save a database directory

  model/
    entry.zig           -- Entry struct and serialization
    history.zig         -- history traversal, diff, version lookup

  vcs/
    merge.zig           -- 3-way merge logic, conflict detection

  tui/
    app.zig             -- top-level Model/Msg/update/view
    unlock.zig          -- password prompt screen
    browser.zig         -- file browser pane (left)
    viewer.zig          -- entry viewer/editor pane (right)
    generator.zig       -- password generator dialog
    history_view.zig    -- version history browser
    conflict_ui.zig     -- interactive merge conflict resolution

  sync/
    remote.zig          -- push/pull protocol (Phase 5)
```

---

## Phases

### Phase 1 — Core Data & Storage (foundation, no crypto yet)

1. Define `Entry` struct: `parent_hash: ?[20]u8`, `title`, `description`, `url`, `username`,
   `password`, `notes`
2. Implement binary serialization for `Entry` (no external deps — manual `Writer`/ `Reader`)
3. `object.zig`: store/retrieve raw blobs by SHA-1 hash from a directory (`objects/`)
4. `index.zig`: read/write a flat file mapping `entry_id → head_hash` and `entry_id → title`
5. `database.zig`: open a database dir, expose `getEntry`, `putEntry`, `listEntries`
6. Unit tests for serialize → hash → store → load roundtrip

### Phase 2 — Cryptography

1. `kdf.zig`: derive a 32-byte key from master password + stored salt using Argon2id; write/read
   `header` file containing salt + Argon2 params
2. `cipher.zig`: wrap ChaCha20-Poly1305 — `encrypt(key, plaintext) → [nonce ++ ciphertext]`,
   `decrypt(key, blob) → plaintext`
3. Hook into `object.zig` so all reads/writes go through cipher
4. Database unlock flow: read header → derive key → attempt to decrypt a sentinel object to
   verify password
5. Tests: wrong password returns error; correct password roundtrips

### Phase 3 — Version Control

1. `history.zig`: `getHistory(entry_id) → []EntryVersion` (walk `parent_hash` chain),
   `getVersion(hash) → Entry`
2. Conflict detection: given two HEADs for the same entry, find their lowest common ancestor; if
   both have diverged → conflict
3. `merge.zig`: merge non-conflicting changes (add new history entries from the remote that don't
   branch locally); flag conflicts for user resolution
4. Add `rollback(entry_id, target_hash)` — repoints the entry's HEAD to a past version (preserving
   the full history chain)

### Phase 4 — TUI: Core Views

1. **Unlock screen** (`unlock.zig`): `TextInput` for password, feedback on wrong password
2. **Browser pane** (`browser.zig`): `List` component showing entry titles; folder-style nesting
   using `Tree`
3. **Viewer pane** (`viewer.zig`): display all fields read-only; vim-motion field navigation; `h` to
   toggle password visibility; keybinding help bar at bottom using zigzag `Help` component
4. **App layout** (`app.zig`): `joinHorizontal` of browser + viewer; tab to switch active pane;
   status bar showing db path and `[modified]` flag

### Phase 5 — TUI: Editing & Generation

1. Ability to add new entries
2. Editing mode in `viewer.zig`: press `e` on a field to enter edit mode via `TextInput`/ `TextArea`
   ; track which fields are modified; highlight modified fields with a colored border and `*`
   indicator
3. `S` to save: serialize entry, compute SHA-1, store as new object version, update index HEAD
4. Discard changes prompt (`Confirm` component)
5. **Password generator** (`generator.zig`): dialog overlay with configurable length, checkboxes for
   character classes (uppercase, lowercase, digits, symbols), preview of generated password, option
   to edit before accepting
6. **Version history view** (`history_view.zig`): `List` of past versions with timestamps; select to
   view a past version read-only; option to restore

### Phase 6 — TUI: Merge & Conflict Resolution

1. **Conflict UI** (`conflict_ui.zig`): side-by-side diff view of conflicting versions; accept left
   / accept right / edit manually; option to duplicate conflicting version as a new entry

### Phase 7 — Sync

1. Finalize the sync protocol decision (HTTP, TCP, or SSH)
2. `remote.zig`: enumerate local objects not on remote, push; enumerate remote objects not local,
   pull
3. After pull, run Phase 3 merge logic; surface conflicts in the Phase 6 conflict UI

---

## Key Constraints / Notes

- No external deps beyond zigzag and Zig stdlib — crypto primitives all from `std.crypto`
- The `objects/` directory stores every version; nothing is ever deleted (history is permanent
  unless explicitly pruned, which is out of scope)
- SHA-1 is used as the content-addressable hash (matching spec), not for security —
  ChaCha20-Poly1305 provides the integrity guarantee
- `ctx.persistent_allocator` must be used for all model state in zigzag; `ctx.allocator` is
  frame-scoped only
