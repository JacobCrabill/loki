const std = @import("std");
const loki = @import("loki");

/// Detect whether a database is encrypted by validating its header file.
/// Returns true if the header exists and contains the expected magic.
pub fn detectEncrypted(db_path: []const u8) bool {
    var dir = std.fs.cwd().openDir(db_path, .{}) catch return false;
    defer dir.close();
    _ = loki.crypto.kdf.readHeader(dir) catch return false;
    return true;
}

/// RAII guard that disables terminal echo on init and restores it on deinit.
/// Selects the platform-appropriate implementation at compile time.
pub const EchoGuard = switch (@import("builtin").os.tag) {
    .windows => struct {
        const windows = std.os.windows;
        const ENABLE_ECHO_INPUT: windows.DWORD = 0x0004;
        extern "kernel32" fn GetConsoleMode(hConsole: windows.HANDLE, lpMode: *windows.DWORD) callconv(.winapi) windows.BOOL;
        extern "kernel32" fn SetConsoleMode(hConsole: windows.HANDLE, dwMode: windows.DWORD) callconv(.winapi) windows.BOOL;

        handle: windows.HANDLE,
        old_mode: windows.DWORD,

        fn init(file: std.fs.File) !@This() {
            const handle = file.handle;
            var old_mode: windows.DWORD = 0;
            if (GetConsoleMode(handle, &old_mode) == 0) return error.GetConsoleModeError;
            if (SetConsoleMode(handle, old_mode & ~ENABLE_ECHO_INPUT) == 0) return error.SetConsoleModeError;
            return .{ .handle = handle, .old_mode = old_mode };
        }

        fn deinit(self: @This()) void {
            _ = SetConsoleMode(self.handle, self.old_mode);
        }
    },
    else => struct {
        fd: std.posix.fd_t,
        old_tio: std.posix.termios,

        fn init(file: std.fs.File) !@This() {
            const fd = file.handle;
            const old_tio = try std.posix.tcgetattr(fd);
            var new_tio = old_tio;
            new_tio.lflag.ECHO = false;
            try std.posix.tcsetattr(fd, .NOW, new_tio);
            return .{ .fd = fd, .old_tio = old_tio };
        }

        fn deinit(self: @This()) void {
            std.posix.tcsetattr(self.fd, .NOW, self.old_tio) catch {};
        }
    },
};

pub fn promptPassword(allocator: std.mem.Allocator) ![]u8 {
    const stderr = std.fs.File.stderr();
    try stderr.writeAll("Password: ");

    const stdin = std.fs.File.stdin();
    const guard = try EchoGuard.init(stdin);
    defer guard.deinit();

    var buf: std.ArrayList(u8) = .{};
    errdefer buf.deinit(allocator);

    var byte: [1]u8 = undefined;
    while (true) {
        const n = stdin.read(&byte) catch break;
        if (n == 0) break;
        if (byte[0] == '\n') break;
        if (byte[0] == '\r') continue;
        try buf.append(allocator, byte[0]);
    }

    try stderr.writeAll("\n");
    return buf.toOwnedSlice(allocator);
}

/// Open a database using dirname/basename split (handles absolute and relative paths).
pub fn openDb(allocator: std.mem.Allocator, db_path: []const u8, password: ?[]const u8) !loki.Database {
    const dirname = std.fs.path.dirname(db_path) orelse ".";
    const basename = std.fs.path.basename(db_path);
    var base_dir = try std.fs.cwd().openDir(dirname, .{});
    defer base_dir.close();
    return loki.Database.open(allocator, base_dir, basename, password);
}
