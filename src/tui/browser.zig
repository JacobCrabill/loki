const std = @import("std");
const zz = @import("zigzag");
const IndexEntry = @import("../store/index.zig").IndexEntry;

/// Left pane: scrollable list of entry titles.
/// Each list item carries the entry's 20-byte ID as its value.
pub const Browser = struct {
    list: zz.List([20]u8),
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator) Browser {
        var list = zz.List([20]u8).init(allocator);
        list.height = 20; // updated each frame in view()
        list.cursor_symbol = "> ";
        return .{ .list = list, .allocator = allocator };
    }

    pub fn deinit(self: *Browser) void {
        self.list.deinit();
    }

    /// Replace the list contents with `entries`, sorted by path then title.
    pub fn populate(self: *Browser, entries: []const IndexEntry) !void {
        // Sort a copy by (path, title).
        var sorted: std.ArrayList(IndexEntry) = .{};
        defer sorted.deinit(self.allocator);
        try sorted.appendSlice(self.allocator, entries);
        std.mem.sort(IndexEntry, sorted.items, {}, struct {
            fn lessThan(_: void, a: IndexEntry, b: IndexEntry) bool {
                const pc = std.mem.order(u8, a.path, b.path);
                if (pc != .eq) return pc == .lt;
                return std.mem.order(u8, a.title, b.title) == .lt;
            }
        }.lessThan);

        var items: std.ArrayList(zz.List([20]u8).Item) = .{};
        defer items.deinit(self.allocator);
        for (sorted.items) |e| {
            const item = if (e.path.len > 0)
                zz.List([20]u8).Item.withDescription(e.entry_id, e.title, e.path)
            else
                zz.List([20]u8).Item.init(e.entry_id, e.title);
            try items.append(self.allocator, item);
        }
        try self.list.setItems(items.items);
    }

    pub fn handleKey(self: *Browser, key: zz.KeyEvent) void {
        self.list.handleKey(key);
    }

    pub fn selectedEntryId(self: *const Browser) ?[20]u8 {
        return self.list.selectedValue();
    }

    /// Render the browser pane. Updates list.height based on available height.
    pub fn view(self: *Browser, allocator: std.mem.Allocator, pane_width: u16, pane_height: u16) ![]const u8 {
        // Reserve 2 rows for border and 1 for title line inside the border.
        const list_height: u16 = if (pane_height > 4) pane_height - 4 else 1;
        self.list.height = list_height;

        const list_str = try self.list.view(allocator);

        const title = "Entries\n";
        const content = try std.fmt.allocPrint(allocator, "{s}{s}", .{ title, list_str });

        var s = zz.Style{};
        s = s.borderAll(zz.Border.rounded);
        s = s.paddingLeft(1);
        s = s.width(pane_width);
        s = s.height(pane_height);
        return s.render(allocator, content);
    }
};
