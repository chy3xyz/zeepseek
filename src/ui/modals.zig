const std = @import("std");
const builtin = @import("builtin");
const vaxis = @import("vaxis");
const theme = @import("theme.zig");

fn klabel(comptime macos: []const u8, comptime other: []const u8) []const u8 {
    return if (builtin.os.tag == .macos) macos else other;
}

const Style = vaxis.Style;
const Color = vaxis.Color;
const Segment = vaxis.Segment;
const ColorPalette = theme.ColorPalette;

pub const ModalResult = union(enum) {
    none,
    close,
    /// Close help and deliver this key to the composer (typing while help was open).
    close_and_forward,
    approve_once,
    approve_all,
    deny,
};

fn clearModalSurface(box: vaxis.Window, palette: *const ColorPalette) void {
    box.fill(.{
        .char = .{ .grapheme = " " },
        .style = .{ .fg = palette.fg, .bg = palette.bg_alt },
    });
}

/// True when the key should go to the input area after dismissing help.
pub fn keyForwardsToComposer(key: vaxis.Key) bool {
    if (key.mods.ctrl or key.mods.alt or key.mods.super or key.mods.hyper) return false;
    if (key.text) |text| {
        if (text.len == 0) return false;
        return text[0] >= 0x20;
    }
    const cp = key.codepoint;
    if (cp < 0x20 or cp >= vaxis.Key.insert) return false;
    return true;
}

pub const KeyBinding = struct {
    keys: []const u8,
    action: []const u8,
};

pub const BindingGroup = struct {
    name: []const u8,
    bindings: []const KeyBinding,
};

const GLOBAL_BINDINGS = [_]KeyBinding{
    .{ .keys = "F1 / ? / Ctrl-/", .action = "Toggle help overlay" },
    .{ .keys = klabel("⌘+P", "Ctrl+P"), .action = "Open command palette" },
    .{ .keys = klabel("⌘+C", "Ctrl+C"), .action = "Cancel turn / dismiss modal / quit" },
    .{ .keys = klabel("⌘+T", "Ctrl+T"), .action = "Cycle theme" },
    .{ .keys = "Ctrl+L", .action = "Redraw screen" },
    .{ .keys = klabel("⌘+B", "Ctrl+B"), .action = "Show workspace status" },
    .{ .keys = klabel("⌘+N", "Ctrl+N"), .action = "Toggle subagent panel" },
    .{ .keys = klabel("⌘+Shift+E", "Ctrl+Shift+E"), .action = "Toggle file tree" },
    .{ .keys = klabel("⌘+Shift+M", "Ctrl+Shift+M"), .action = "Toggle user memory editor" },
    .{ .keys = klabel("⌘+Shift+S", "Ctrl+Shift+S"), .action = "Export chat to markdown" },
    .{ .keys = klabel("⌘+Shift+X", "Ctrl+Shift+X"), .action = "Open external editor" },
    .{ .keys = klabel("⌘+Shift+T", "Ctrl+Shift+T"), .action = "Toggle transcript overlay" },
    .{ .keys = "Ctrl+O", .action = "Open message detail" },
    .{ .keys = klabel("⌘+S", "Ctrl+S"), .action = "Stash/restore draft" },
    .{ .keys = klabel("⌘+R", "Ctrl+R"), .action = "Retry last failed response" },
    .{ .keys = klabel("⌘+Shift+C", "Ctrl+Shift+C"), .action = "Copy last message to clipboard" },
    .{ .keys = "Shift+Tab", .action = "Cycle reasoning effort (empty) / unindent (typing)" },
    .{ .keys = "Ctrl+I", .action = "Toggle context inspector" },
    .{ .keys = klabel("⌘+D", "Ctrl+D"), .action = "Backtrack from selected message" },
    .{ .keys = klabel("⌘+Shift+D", "Ctrl+Shift+D"), .action = "Delete selected message" },
    .{ .keys = "/rollback", .action = "Rollback workspace changes" },
    .{ .keys = klabel("⌘+F", "Ctrl+F"), .action = "Search messages" },
    .{ .keys = "Esc", .action = "Close modal / scroll to bottom" },
    .{ .keys = klabel("⌘+Esc", "Shift+Esc"), .action = "Quit application" },
};

const COMPOSER_BINDINGS = [_]KeyBinding{
    .{ .keys = "Enter", .action = "Send message" },
    .{ .keys = "Shift-Enter / Alt-Enter / Ctrl-J", .action = "Insert newline" },
    .{ .keys = "↑ / ↓", .action = "Cycle input history (scrolls chat when empty)" },
    .{ .keys = "Shift-↑ / Shift-↓", .action = "Scroll chat" },
    .{ .keys = "Alt-↑ / Alt-↓", .action = "Select message" },
    .{ .keys = "Alt-[ / Alt-]", .action = "Jump to previous/next tool block" },
    .{ .keys = "Alt-E", .action = "Edit selected user message" },
    .{ .keys = "Alt-T", .action = "Toggle thinking for selected message" },
    .{ .keys = "Alt-M", .action = "Collapse/expand selected message" },
    .{ .keys = "Alt-Q", .action = "Quote selected message" },
    .{ .keys = "Alt-C", .action = "Copy selected code block" },
    .{ .keys = "PgUp / PgDn", .action = "Scroll page up/down" },
    .{ .keys = "Ctrl-← / Ctrl-→", .action = "Move cursor by word" },
    .{ .keys = "Ctrl-U", .action = "Kill to start of line" },
    .{ .keys = "Ctrl-K", .action = "Kill to end of line" },
    .{ .keys = "Ctrl-Y", .action = "Yank (paste kill buffer)" },
    .{ .keys = "Alt-R", .action = "Search input history" },
    .{ .keys = "Alt-Backspace / Ctrl-W", .action = "Delete word backward" },
    .{ .keys = "Home / Ctrl-A", .action = "Move to start of line (scrolls chat top when empty)" },
    .{ .keys = "End / Ctrl-E", .action = "Move to end of line (scrolls chat bottom when empty)" },
    .{ .keys = "Backspace", .action = "Delete previous character" },
    .{ .keys = "Tab", .action = "Insert indent (typing) / toggle panel focus (empty)" },
};

const TRANSCRIPT_BINDINGS = [_]KeyBinding{
    .{ .keys = "g / Home", .action = "Jump to top" },
    .{ .keys = "G / End", .action = "Jump to bottom" },
    .{ .keys = "↑ / ↓", .action = "Scroll one line" },
    .{ .keys = "PgUp / PgDn", .action = "Scroll one page" },
};

const TOOL_BINDINGS = [_]KeyBinding{
    .{ .keys = "y", .action = "Approve tool execution (once)" },
    .{ .keys = "a", .action = "Approve all pending tools" },
    .{ .keys = "n", .action = "Deny tool execution" },
    .{ .keys = "e", .action = "Edit tool arguments" },
};

const SUBAGENT_BINDINGS = [_]KeyBinding{
    .{ .keys = "↑ / ↓  j / k", .action = "Navigate tasks / sections" },
    .{ .keys = "g / G", .action = "Aggregate results" },
    .{ .keys = "Enter / Space", .action = "Collapse/expand section" },
    .{ .keys = "x", .action = "Cancel selected task" },
    .{ .keys = "a / A", .action = "Cancel all tasks" },
    .{ .keys = "r / R", .action = "Refresh aggregate" },
    .{ .keys = "l / L", .action = "Back to list view" },
    .{ .keys = "q / Esc", .action = "Close results / defocus" },
};

const BINDING_GROUPS = [_]BindingGroup{
    .{ .name = "Global", .bindings = &GLOBAL_BINDINGS },
    .{ .name = "Composer", .bindings = &COMPOSER_BINDINGS },
    .{ .name = "Transcript", .bindings = &TRANSCRIPT_BINDINGS },
    .{ .name = "Subagent Panel", .bindings = &SUBAGENT_BINDINGS },
    .{ .name = "Tool Approval", .bindings = &TOOL_BINDINGS },
};

const max_help_lines: usize = 120;
const help_line_cap: usize = 160;

fn bindingLineCount() usize {
    var total: usize = 0;
    for (BINDING_GROUPS) |group| {
        total += 1 + group.bindings.len + 1;
    }
    return total;
}

fn writeHelpLine(
    line_bufs: *[max_help_lines][help_line_cap]u8,
    line_lens: *[max_help_lines]usize,
    line_idx: *usize,
    text: []const u8,
) void {
    if (line_idx.* >= line_bufs.len) return;
    const n = @min(text.len, help_line_cap);
    @memcpy(line_bufs[line_idx.*][0..n], text[0..n]);
    line_lens[line_idx.*] = n;
    line_idx.* += 1;
}

fn buildHelpLines(
    line_bufs: *[max_help_lines][help_line_cap]u8,
    line_lens: *[max_help_lines]usize,
) usize {
    var line_idx: usize = 0;
    var scratch: [help_line_cap]u8 = undefined;

    for (BINDING_GROUPS) |group| {
        writeHelpLine(line_bufs, line_lens, &line_idx, group.name);
        for (group.bindings) |binding| {
            const formatted = std.fmt.bufPrint(
                &scratch,
                "  {s:<22} {s}",
                .{ binding.keys, binding.action },
            ) catch continue;
            writeHelpLine(line_bufs, line_lens, &line_idx, formatted);
        }
        writeHelpLine(line_bufs, line_lens, &line_idx, "");
    }
    return line_idx;
}

pub const HelpModal = struct {
    scroll_offset: usize = 0,

    pub fn handleKey(self: *HelpModal, key: vaxis.Key) ModalResult {
        const max_scroll = bindingLineCount();
        if (key.mods.ctrl and key.codepoint == 3) return .close;
        if (key.codepoint == vaxis.Key.f1 or key.codepoint == '?' or
            (key.mods.ctrl and key.codepoint == '/'))
        {
            return .close;
        }
        switch (key.codepoint) {
            vaxis.Key.escape => return .close,
            'q', 'Q' => return .close,
            vaxis.Key.up, 'k' => {
                if (self.scroll_offset > 0) self.scroll_offset -= 1;
            },
            vaxis.Key.down, 'j' => {
                if (self.scroll_offset + 1 < max_scroll) self.scroll_offset += 1;
            },
            vaxis.Key.page_up => {
                if (self.scroll_offset > 10) self.scroll_offset -= 10 else self.scroll_offset = 0;
            },
            vaxis.Key.page_down => {
                self.scroll_offset = @min(self.scroll_offset + 10, max_scroll -| 1);
            },
            else => {
                if (keyForwardsToComposer(key)) return .close_and_forward;
            },
        }
        return .none;
    }

    pub fn render(self: *const HelpModal, win: vaxis.Window, palette: *const ColorPalette) void {
        const width: u16 = @min(70, win.width -| 4);
        const height: u16 = @min(24, win.height -| 2);
        if (width < 20 or height < 8) return;

        const start_x = @divTrunc(win.width - width, 2);
        const start_y = @divTrunc(win.height - height, 2);

        const box = win.child(.{
            .x_off = @intCast(start_x),
            .y_off = @intCast(start_y),
            .width = width,
            .height = height,
        });
        clearModalSurface(box, palette);

        const border_style = Style{ .fg = palette.border_focused };
        const title_style = Style{ .fg = palette.fg_bright, .bold = true };
        const group_style = Style{ .fg = palette.info, .bold = true };
        const key_style = Style{ .fg = palette.fg_bright };
        const action_style = Style{ .fg = palette.fg_dim };
        const hint_row: u16 = height - 2;
        const content_end: u16 = hint_row -| 1;

        _ = box.print(&.{.{ .text = "┌", .style = border_style }}, .{ .row_offset = 0, .col_offset = 0, .wrap = .none, .commit = true });
        var col: u16 = 1;
        while (col < width - 1) : (col += 1) {
            _ = box.print(&.{.{ .text = "─", .style = border_style }}, .{ .row_offset = 0, .col_offset = col, .wrap = .none, .commit = true });
        }
        _ = box.print(&.{.{ .text = "┐", .style = border_style }}, .{ .row_offset = 0, .col_offset = @intCast(width - 1), .wrap = .none, .commit = true });
        const title = " Key Bindings ";
        const title_x = @divTrunc(width - @as(u16, @intCast(title.len)), 2);
        _ = box.print(&.{.{ .text = title, .style = title_style }}, .{ .row_offset = 0, .col_offset = title_x, .wrap = .none, .commit = true });

        var side_row: u16 = 1;
        while (side_row < height - 1) : (side_row += 1) {
            _ = box.print(&.{.{ .text = "│", .style = border_style }}, .{ .row_offset = side_row, .col_offset = 0, .wrap = .none, .commit = true });
            _ = box.print(&.{.{ .text = "│", .style = border_style }}, .{ .row_offset = side_row, .col_offset = @intCast(width - 1), .wrap = .none, .commit = true });
        }

        _ = box.print(&.{.{ .text = "└", .style = border_style }}, .{ .row_offset = @intCast(height - 1), .col_offset = 0, .wrap = .none, .commit = true });
        col = 1;
        while (col < width - 1) : (col += 1) {
            _ = box.print(&.{.{ .text = "─", .style = border_style }}, .{ .row_offset = @intCast(height - 1), .col_offset = col, .wrap = .none, .commit = true });
        }
        _ = box.print(&.{.{ .text = "┘", .style = border_style }}, .{ .row_offset = @intCast(height - 1), .col_offset = @intCast(width - 1), .wrap = .none, .commit = true });

        var line_bufs: [max_help_lines][help_line_cap]u8 = undefined;
        var line_lens: [max_help_lines]usize = undefined;
        const total_lines = buildHelpLines(&line_bufs, &line_lens);

        var row: u16 = 1;
        var line_idx: usize = self.scroll_offset;
        while (line_idx < total_lines and row <= content_end) : (line_idx += 1) {
            const line = line_bufs[line_idx][0..line_lens[line_idx]];
            if (line.len == 0) {
                row += 1;
                continue;
            }
            const is_group = line.len > 0 and line[0] != ' ';
            const style = if (is_group) group_style else if (std.mem.startsWith(u8, line, "  ")) key_style else action_style;
            const max_cols = @as(usize, width - 4);
            const display = if (line.len > max_cols) line[0..max_cols] else line;
            _ = box.print(&.{.{ .text = display, .style = style }}, .{ .row_offset = row, .col_offset = 2, .wrap = .none, .commit = true });
            row += 1;
        }

        const hint = "?/F1/Esc close  j/k scroll";
        _ = box.print(&.{.{ .text = hint, .style = action_style }}, .{ .row_offset = hint_row, .col_offset = 2, .wrap = .none, .commit = true });
    }
};

pub const ApprovalModal = struct {
    tool_name: []const u8 = "",
    arguments: []const u8 = "",
    risk_level: []const u8 = "medium",

    pub fn handleKey(_: *ApprovalModal, key: vaxis.Key) ModalResult {
        switch (key.codepoint) {
            'y', 'Y' => return .approve_once,
            'a', 'A' => return .approve_all,
            'n', 'N' => return .deny,
            vaxis.Key.escape => return .deny,
            else => {},
        }
        return .none;
    }

    pub fn render(self: *const ApprovalModal, win: vaxis.Window, palette: *const ColorPalette) void {
        const width: u16 = @min(60, win.width -| 4);
        const height: u16 = @min(16, win.height -| 2);
        if (width < 30 or height < 10) return;

        const start_x = @divTrunc(win.width - width, 2);
        const start_y = @divTrunc(win.height - height, 2);

        const box = win.child(.{
            .x_off = @intCast(start_x),
            .y_off = @intCast(start_y),
            .width = width,
            .height = height,
        });

        clearModalSurface(box, palette);

        const border_style = Style{ .fg = palette.warning };
        const title_style = Style{ .fg = palette.warning, .bold = true };
        const label_style = Style{ .fg = palette.fg_bright };
        const value_style = Style{ .fg = palette.fg };
        const hint_style = Style{ .fg = palette.fg_dim };

        // Border
        _ = box.print(&.{.{ .text = "┌", .style = border_style }}, .{ .row_offset = 0, .col_offset = 0, .wrap = .none, .commit = true });
        var col: u16 = 1;
        while (col < width - 1) : (col += 1) {
            _ = box.print(&.{.{ .text = "─", .style = border_style }}, .{ .row_offset = 0, .col_offset = col, .wrap = .none, .commit = true });
        }
        _ = box.print(&.{.{ .text = "┐", .style = border_style }}, .{ .row_offset = 0, .col_offset = @intCast(width - 1), .wrap = .none, .commit = true });

        var r: u16 = 1;
        while (r < height - 1) : (r += 1) {
            _ = box.print(&.{.{ .text = "│", .style = border_style }}, .{ .row_offset = r, .col_offset = 0, .wrap = .none, .commit = true });
            _ = box.print(&.{.{ .text = "│", .style = border_style }}, .{ .row_offset = r, .col_offset = @intCast(width - 1), .wrap = .none, .commit = true });
        }

        _ = box.print(&.{.{ .text = "└", .style = border_style }}, .{ .row_offset = @intCast(height - 1), .col_offset = 0, .wrap = .none, .commit = true });
        col = 1;
        while (col < width - 1) : (col += 1) {
            _ = box.print(&.{.{ .text = "─", .style = border_style }}, .{ .row_offset = @intCast(height - 1), .col_offset = col, .wrap = .none, .commit = true });
        }
        _ = box.print(&.{.{ .text = "┘", .style = border_style }}, .{ .row_offset = @intCast(height - 1), .col_offset = @intCast(width - 1), .wrap = .none, .commit = true });

        // Title
        const title = " ⚠ Tool Approval Required ";
        const title_x = @divTrunc(width - @as(u16, @intCast(title.len)), 2);
        _ = box.print(&.{.{ .text = title, .style = title_style }}, .{ .row_offset = 1, .col_offset = title_x, .wrap = .none, .commit = true });

        // Tool name
        _ = box.print(&.{.{ .text = "Tool:", .style = label_style }}, .{ .row_offset = 3, .col_offset = 2, .wrap = .none, .commit = true });
        _ = box.print(&.{.{ .text = self.tool_name, .style = value_style }}, .{ .row_offset = 3, .col_offset = 10, .wrap = .none, .commit = true });

        // Risk level
        const risk_color = if (std.mem.eql(u8, self.risk_level, "critical"))
            palette.error_color
        else if (std.mem.eql(u8, self.risk_level, "high"))
            palette.warning
        else
            palette.info;
        _ = box.print(&.{.{ .text = "Risk:", .style = label_style }}, .{ .row_offset = 4, .col_offset = 2, .wrap = .none, .commit = true });
        _ = box.print(&.{.{ .text = self.risk_level, .style = .{ .fg = risk_color, .bold = true } }}, .{ .row_offset = 4, .col_offset = 10, .wrap = .none, .commit = true });

        // Arguments preview
        _ = box.print(&.{.{ .text = "Arguments:", .style = label_style }}, .{ .row_offset = 5, .col_offset = 2, .wrap = .none, .commit = true });
        const args_preview = if (self.arguments.len > width - 6)
            self.arguments[0 .. width - 9]
        else
            self.arguments;
        _ = box.print(&.{.{ .text = args_preview, .style = value_style }}, .{ .row_offset = 6, .col_offset = 4, .wrap = .none, .commit = true });
        if (self.arguments.len > width - 6) {
            _ = box.print(&.{.{ .text = "...", .style = hint_style }}, .{ .row_offset = 7, .col_offset = 4, .wrap = .none, .commit = true });
        }

        // Actions hint
        _ = box.print(&.{.{ .text = "Actions:", .style = label_style }}, .{ .row_offset = 9, .col_offset = 2, .wrap = .none, .commit = true });
        _ = box.print(&.{.{ .text = "[y] approve once  [a] approve all  [n] deny  [e] edit", .style = hint_style }}, .{ .row_offset = 10, .col_offset = 2, .wrap = .none, .commit = true });

        // Separator
        col = 2;
        while (col < width - 2) : (col += 1) {
            _ = box.print(&.{.{ .text = "─", .style = border_style }}, .{ .row_offset = @intCast(height - 3), .col_offset = col, .wrap = .none, .commit = true });
        }
    }
};

pub const Modal = union(enum) {
    help: HelpModal,
    approval: ApprovalModal,

    pub fn handleKey(self: *Modal, key: vaxis.Key) ModalResult {
        switch (self.*) {
            .help => |*m| return m.handleKey(key),
            .approval => |*m| return m.handleKey(key),
        }
    }

    pub fn render(self: Modal, win: vaxis.Window, palette: *const ColorPalette) void {
        switch (self) {
            .help => |m| m.render(win, palette),
            .approval => |m| m.render(win, palette),
        }
    }
};

test "help modal key handling" {
    var modal = HelpModal{};
    const result = modal.handleKey(.{ .codepoint = vaxis.Key.escape });
    try std.testing.expectEqual(ModalResult.close, result);

    const forward = modal.handleKey(.{ .codepoint = 'a' });
    try std.testing.expectEqual(ModalResult.close_and_forward, forward);
}

test "key forwards to composer" {
    try std.testing.expect(keyForwardsToComposer(.{ .codepoint = 'x' }));
    try std.testing.expect(!keyForwardsToComposer(.{ .codepoint = vaxis.Key.escape }));
    try std.testing.expect(!keyForwardsToComposer(.{ .codepoint = 'a', .mods = .{ .ctrl = true } }));
}

test "approval modal key handling" {
    var modal = ApprovalModal{};
    try std.testing.expectEqual(ModalResult.approve_once, modal.handleKey(.{ .codepoint = 'y' }));
    try std.testing.expectEqual(ModalResult.approve_all, modal.handleKey(.{ .codepoint = 'a' }));
    try std.testing.expectEqual(ModalResult.deny, modal.handleKey(.{ .codepoint = 'n' }));
    try std.testing.expectEqual(ModalResult.deny, modal.handleKey(.{ .codepoint = vaxis.Key.escape }));
}
