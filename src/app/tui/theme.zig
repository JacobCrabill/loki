//! Terminal color themes applied via OSC escape sequences.
//!
//! Three OSC sequences are used:
//!   OSC 10  — sets the terminal default foreground color.
//!   OSC 11  — sets the terminal default background color.
//!   OSC  4  — sets individual entries in the 16-color ANSI palette.
//!
//! On exit use `Theme.reset()` to restore the terminal's original colors.
//! The reset sequences (OSC 110/111/104) tell the terminal to revert each
//! setting to its user-configured default without needing to save/restore
//! the original values explicitly.
//!
//! TODO: This is AI slop. Cleanup.

const std = @import("std");

pub const Theme = struct {
    name: []const u8,
    /// Default foreground color (#RRGGBB) — applied via OSC 10.
    default_fg: []const u8,
    /// Default background color (#RRGGBB) — applied via OSC 11.
    /// This also controls the fill color used by `\x1b[K` (erase-to-right),
    /// which the zigzag renderer emits after every rendered line.
    default_bg: []const u8,
    /// The 16 ANSI palette colors (indices 0–15), each as a #RRGGBB string.
    /// These map to the named colors used in zigzag styles:
    ///   0=black  1=red    2=green  3=yellow  4=blue  5=magenta  6=cyan  7=white
    ///   8=brBlack 9=brRed 10=brGreen 11=brYellow 12=brBlue 13=brMagenta 14=brCyan 15=brWhite
    palette: [16][]const u8,

    /// Apply this theme to the terminal by emitting OSC escape sequences.
    /// Call this once before starting the TUI event loop.
    pub fn apply(self: Theme) !void {
        // Build the full sequence into a stack buffer to make a single write
        // call.  Each OSC 4 entry is at most ~20 bytes; 16 entries + OSC 10/11
        // comfortably fits in 512 bytes.
        var buf: [512]u8 = undefined;
        var stream = std.io.fixedBufferStream(&buf);
        const w = stream.writer();
        // Default foreground (OSC 10) and background (OSC 11).
        try w.print("\x1b]10;{s}\x07", .{self.default_fg});
        try w.print("\x1b]11;{s}\x07", .{self.default_bg});
        // ANSI palette entries (OSC 4, indices 0–15).
        for (self.palette, 0..) |color, i| {
            try w.print("\x1b]4;{d};{s}\x07", .{ i, color });
        }
        try std.fs.File.stdout().writeAll(stream.getWritten());
    }

    /// Reset terminal colors back to the user's configured defaults.
    /// Call this (via defer) after the TUI event loop exits.
    pub fn reset() !void {
        try std.fs.File.stdout().writeAll(
            "\x1b]110\x07" ++ // Reset default foreground.
                "\x1b]111\x07" ++ // Reset default background.
                "\x1b]104\x07", // Reset entire ANSI palette.
        );
    }
};

// =============================================================================
// Built-in themes
// =============================================================================

/// Catppuccin Mocha — a warm, dark theme.
/// Palette sourced from https://catppuccin.com/palette
pub const catppuccin_mocha = Theme{
    .name = "Catppuccin Mocha",
    .default_fg = "#cdd6f4", // Text
    .default_bg = "#1e1e2e", // Base
    .palette = .{
        "#45475a", //  0  black          → Surface1
        "#f38ba8", //  1  red            → Red
        "#a6e3a1", //  2  green          → Green
        "#f9e2af", //  3  yellow         → Yellow
        "#89b4fa", //  4  blue           → Blue
        "#cba6f7", //  5  magenta        → Mauve
        "#94e2d5", //  6  cyan           → Teal
        "#bac2de", //  7  white          → Subtext1
        "#585b70", //  8  bright black   → Surface2
        "#f38ba8", //  9  bright red     → Red
        "#a6e3a1", // 10  bright green   → Green
        "#f9e2af", // 11  bright yellow  → Yellow
        "#b4befe", // 12  bright blue    → Lavender
        "#cba6f7", // 13  bright magenta → Mauve
        "#89dceb", // 14  bright cyan    → Sky
        "#cdd6f4", // 15  bright white   → Text
    },
};
