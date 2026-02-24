# PazzMan Password Manager Project

## Goals

- Simple TUI interface
- Similar functionality as KeePassXC
  - Password-protected "database" (exact format TBD)
  - Organize entries in folders
  - Entries contain username, password, URL, and notes
  - Password generation with option to enable different sets of allowed characters
- Version tracking of all changes
  - See past versions of an entry
- Automatic syncing of the "database" to a remote server
  - Git-style push/pull synchronization
  - Ability for the user to interactively resolve vesrion conflicts

## Details

### Entry Representation

Each entry in the database should consist of the following pieces of data:

- Parent (previous) version: The unique SHA-1 hash of the previous version of the entry. If it is
  the first revision, this value is null.
- Title: The name of the entry, to be shown in the "file browser".
- Description: A short description of the entry
- URL
- Username
- Password
- Notes

### Version Control

All entries should have a Git-style vesrion history; each version should have one and only one
"parent", forming a linear history of changes.

The user should have an option to merge two databases together. New changes (additions to the
history "tree") to entries should be brought in if there are no conflicts. When there are conflicts;
that is, when the two copies of an entry are edited in ways that produce a branching history tree
for the entry, the user should be provided with an interactive means of comparing the conflicting
versions and selecting or creating the correct version, or turning one of the conflicting versions
into a copy (new entry) with a different name. The user should also have the option of rolling back
an entry to a previous version.

### Storage Format

We will **not** be using a normal database like sqlite, because I wish to have more flexibility in
exactly how the data is serialized, and how versions are stored and linked. Also, I would like to
limit the number of dependencies brought into this project.

**Option 1:** Binary format that simulates an in-memory filesystem. The binary blob is read from the
disk, decrypted into an in-memory "filesystem" object, entries are added/removed/modified, and the
result is serialized, encrypted, and written back to the disk.

**Option 2:** Git-style object storage. A directory contains an index referencing the current state
of the "database", with each entry stored based on its SHA-1 hash as a single encrypted file.

### TUI Interface

The TUI will be developed using the "zigzag" library (see `ziig-pkg/zigzag/`).

When opening a database, the user should first be prompted to enter the password to decrypt the
database. If the password successfully decrypts the database, the user is then shown a sort of "file
browser" interface to navigate the entries within it. At the bottom of the TUI screen are tips for
keybindings - e.g. vim motions to navigate within a pane, tab to toggle between panes , 'S' to save,
etc.

The panes in this primary view should be the file browser on the left, and the viewer/editor on the
right showing the title, description, URL, username, password (hidden by default), and notes. The
"parent" (previous version) hash may also be shown (read-only!) in italics somewhere. When entering
the view/edit pane at first, it is read-only, and vim motions (or arrow keys) can move bewteen the
fields, with the help text at the bottom of the screen updating to show the available actions (edit,
copy, unhide password, generate new password, etc.) as appropriate. There should also be an option,
while in "view" mode (not editing a field), to view the previous versions of

The "Generate Password" interface should show options to select the length of the password,
enable/disable types of special characters, and allow the user to edit the generated password before
storing to the entry.

When any field of an entry has been modified, a statusbar line at the bottom of the TUI should show
that unsaved changes are present, and the modified field(s) should have some sort of visual change
as well (such as a different color border, and perhaps a `*` next to the field.).
