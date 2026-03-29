const std = @import("std");
const zz = @import("zigzag");

/// Signal returned by `handleKey`.
pub const Signal = enum {
    /// No action required by the caller.
    none,
    /// User pressed Escape: close the search pane and clear the filter.
    dismissed,
};

/// Height (rows) of the rendered search pane, including its border.
pub const PANE_HEIGHT: u16 = 3;

/// Standalone search pane rendered below the browser by MainScreen.
/// The pane owns its TextInput; the current query is read by MainScreen
/// and pushed to Browser via `Browser.setFilter`.
pub const SearchPane = struct {
    input: zz.TextInput,

    pub fn init(allocator: std.mem.Allocator) SearchPane {
        var inp = zz.TextInput.init(allocator);
        inp.setPlaceholder("search…");
        return .{ .input = inp };
    }

    pub fn deinit(self: *SearchPane) void {
        self.input.deinit();
    }

    /// Focus the text input. Call when the search pane gains focus.
    pub fn focus(self: *SearchPane) void {
        self.input.focus();
    }

    /// Blur the text input. Call when the search pane loses focus.
    pub fn blur(self: *SearchPane) void {
        self.input.blur();
    }

    /// Blur and clear. Call when the search pane is being closed entirely.
    pub fn close(self: *SearchPane) void {
        self.input.blur();
        self.input.setValue("") catch {};
    }

    /// The current search query, valid until the next mutation.
    pub fn getQuery(self: *const SearchPane) []const u8 {
        return self.input.getValue();
    }

    pub fn handleKey(self: *SearchPane, key: zz.KeyEvent) Signal {
        // Escape closes the search pane.
        if (key.key == .escape) return .dismissed;
        // Tab is intercepted by MainScreen before reaching here (pane switching).
        if (key.key == .tab) return .none;
        self.input.handleKey(key);
        return .none;
    }

    pub fn getHints(self: *const SearchPane) []const u8 {
        _ = self;
        return "Type to search  Tab: switch pane  Esc: close search";
    }

    /// Render the search pane as a PANE_HEIGHT-row box matching `pane_width`.
    /// `focused` controls whether the border uses the active (double/cyan) style.
    pub fn view(
        self: *SearchPane,
        allocator: std.mem.Allocator,
        pane_width: u16,
        focused: bool,
    ) ![]const u8 {
        // Mirror the browser's content-width formula so the two boxes align.
        const content_w: u16 = pane_width -| 3; // 1 left-pad + 2 borders

        var prompt_s = zz.Style{};
        prompt_s = prompt_s.fg(zz.Color.cyan()).bold(true).inline_style(true);

        const input_view = try self.input.view(allocator);
        const content = try std.fmt.allocPrint(allocator, "{s}{s}", .{
            try prompt_s.render(allocator, "/ "),
            input_view,
        });

        var box_s = zz.Style{};
        if (focused) {
            box_s = box_s.borderAll(zz.Border.double).borderForeground(zz.Color.cyan());
        } else {
            box_s = box_s.borderAll(zz.Border.rounded).borderForeground(zz.Color.yellow());
        }
        box_s = box_s.paddingLeft(1).width(content_w);
        return box_s.render(allocator, content);
    }
};
