const std = @import("std");
const app = @import("pazzman").tui.app;

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    const args = try std.process.argsAlloc(allocator);
    defer std.process.argsFree(allocator, args);

    if (args.len < 2) {
        std.debug.print("Usage: pazzman <database-path>\n", .{});
        std.process.exit(1);
    }

    try app.run(allocator, args[1]);
}
