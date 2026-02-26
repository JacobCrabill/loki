const std = @import("std");
const app = @import("loki").tui.app;
const known_folders = @import("known-folders");

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    const args = try std.process.argsAlloc(allocator);
    defer std.process.argsFree(allocator, args);

    if (args.len >= 2) {
        if (std.mem.eql(u8, args[1], "-h") or std.mem.eql(u8, args[1], "--help")) {
            std.debug.print("Loki: Simple TUI Password Manager\n", .{});
            std.debug.print("Usage: {s} [database_path]\n", .{args[0]});
            std.debug.print("\nDefault database_path: ~/.loki\n", .{});
            std.process.exit(0);
        }
        try app.run(allocator, args[1]);
        std.process.exit(0);
    }

    // No database path provided
    const home_path = try known_folders.getPath(allocator, .home);
    if (home_path) |home| {
        defer allocator.free(home);
        const db_path = try std.fmt.allocPrint(allocator, "{s}/.loki/", .{home});
        defer allocator.free(db_path);
        try app.run(allocator, db_path);
    } else {
        std.debug.print("Error: Cannot find $HOME directory!\n", .{});
        std.process.exit(1);
    }
}
