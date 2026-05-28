const std = @import("std");
const vaxis = @import("vaxis");
const theme = @import("theme.zig");

pub const ColorPalette = theme.ColorPalette;

pub const Shortcuts = struct {
    key: u21,
    modifiers: vaxis.Key.Modifiers = .{},
};

pub const Category = enum {
    navigation,
    editing,
    session,
    tools,
    settings,
    skills,
};

pub fn categoryName(cat: Category) []const u8 {
    return switch (cat) {
        .navigation => "Navigation",
        .editing => "Editing",
        .session => "Session",
        .tools => "Tools",
        .settings => "Settings",
        .skills => "Skills",
    };
}

pub const PaletteCommand = struct {
    id: []const u8,
    label: []const u8,
    description: []const u8,
    shortcut: ?Shortcuts,
    category: Category,
    handler_fn: ?*const fn (app: *anyopaque) void,
};

pub const Command = PaletteCommand;

fn makeCommand(
    id: []const u8,
    label: []const u8,
    description: []const u8,
    shortcut_key: ?u21,
    category: Category,
) PaletteCommand {
    return .{
        .id = id,
        .label = label,
        .description = description,
        .shortcut = if (shortcut_key) |k| Shortcuts{ .key = k, .modifiers = .{} } else null,
        .category = category,
        .handler_fn = null,
    };
}

const PALETTE_COMMANDS = [_]Command{
    makeCommand("goto_chat", "Go to Chat", "Focus the input area", vaxis.Key.escape, .navigation),
    makeCommand("goto_top", "Go to Top", "Scroll to top of chat", vaxis.Key.home, .navigation),
    makeCommand("goto_bottom", "Go to Bottom", "Scroll to bottom of chat", vaxis.Key.end, .navigation),
    makeCommand("scroll_up", "Scroll Up", "Scroll chat history up", vaxis.Key.page_up, .navigation),
    makeCommand("scroll_down", "Scroll Down", "Scroll chat history down", vaxis.Key.page_down, .navigation),
    makeCommand("new_session", "New Session", "Start a new chat session", 'n', .session),
    makeCommand("fork_session", "Fork Session", "Create a fork at current point", null, .session),
    makeCommand("clear_chat", "Clear Chat", "Clear all messages", null, .session),
    makeCommand("export_chat", "Export Chat", "Export chat history to file", null, .session),
    makeCommand("copy_conversation", "Copy Conversation", "Copy entire conversation to clipboard", null, .session),
    makeCommand("toggle_theme", "Cycle Theme", "Switch to next theme", 't', .settings),
    makeCommand("toggle_thinking", "Toggle Thinking", "Show/hide reasoning content", 'r', .settings),
    makeCommand("toggle_subagent", "Toggle SubAgent Panel", "Show/hide subagent panel", '\t', .settings),
    makeCommand("toggle_auto_mode", "Toggle Auto Mode", "Auto-select model per turn", 'a', .settings),
    makeCommand("settings", "Open Settings", "Configure zeepseek settings", null, .settings),
    makeCommand("toggle_file_tree", "Toggle File Tree", "Show/hide file tree panel", 'e', .tools),
    makeCommand("toggle_context_inspector", "Toggle Inspector", "Show/hide context inspector", 'i', .tools),
    makeCommand("toggle_transcript", "Toggle Transcript", "Show full transcript overlay", 't', .navigation),
    makeCommand("search_messages", "Search Messages", "Find text in chat history", 'f', .navigation),
    makeCommand("open_external_editor", "External Editor", "Open $EDITOR for input", 'x', .editing),
    makeCommand("approve_tool", "Approve Tool", "Approve pending tool execution", 'y', .tools),
    makeCommand("deny_tool", "Deny Tool", "Deny pending tool execution", 'n', .tools),
    makeCommand("show_skills", "Show Skills", "List available skills", null, .skills),
    makeCommand("install_skill", "Install Skill", "Install a new skill", null, .skills),
};

pub const CommandPalette = struct {
    arena: std.heap.ArenaAllocator,
    active: bool,
    query: []u8,
    commands: []const PaletteCommand,
    filtered: []const PaletteCommand,
    selected: usize,
    scroll_offset: usize,
    app_ctx: ?*anyopaque,

    pub fn init(alloc: std.mem.Allocator) CommandPalette {
        const arena = std.heap.ArenaAllocator.init(alloc);
        return .{
            .arena = arena,
            .active = false,
            .query = &.{},
            .commands = &PALETTE_COMMANDS,
            .filtered = &PALETTE_COMMANDS,
            .selected = 0,
            .scroll_offset = 0,
            .app_ctx = null,
        };
    }

    pub fn deinit(self: *CommandPalette) void {
        self.arena.deinit();
    }

    pub fn setContext(self: *CommandPalette, ctx: *anyopaque) void {
        self.app_ctx = ctx;
    }

    pub fn setCommands(self: *CommandPalette, commands: []const PaletteCommand) void {
        self.commands = commands;
        self.filtered = commands;
        self.selected = 0;
        self.scroll_offset = 0;
    }

    pub fn open(self: *CommandPalette) void {
        self.active = true;
        self.query = self.arena.allocator().dupe(u8, self.query) catch &.{};
        self.selected = 0;
        self.scroll_offset = 0;
        self.applyFilter();
    }

    pub fn close(self: *CommandPalette) void {
        self.active = false;
        if (self.query.len > 0) {
            self.arena.allocator().free(self.query);
            self.query = &.{};
        }
    }

    pub fn toggle(self: *CommandPalette) void {
        if (self.active) {
            self.close();
        } else {
            self.open();
        }
    }

    pub fn appendQuery(self: *CommandPalette, ch: u8) void {
        const new_query = self.arena.allocator().dupe(u8, self.query) catch return;
        if (self.query.len > 0) {
            self.arena.allocator().free(self.query);
        }
        const extended = std.fmt.allocPrint(self.arena.allocator(), "{s}{c}", .{
            new_query, ch,
        }) catch {
            self.query = new_query;
            return;
        };
        self.query = extended;
        self.selected = 0;
        self.scroll_offset = 0;
        self.applyFilter();
    }

    pub fn deleteQueryChar(self: *CommandPalette) void {
        if (self.query.len == 0) return;
        const new_len = self.query.len - 1;
        const new_query = self.arena.allocator().dupe(u8, self.query[0..new_len]) catch return;
        if (self.query.len > 0) {
            self.arena.allocator().free(self.query);
        }
        self.query = new_query;
        self.selected = 0;
        self.scroll_offset = 0;
        self.applyFilter();
    }

    fn applyFilter(self: *CommandPalette) void {
        if (self.query.len == 0) {
            self.filtered = self.commands;
            return;
        }
        const q = self.query;
        var result: std.ArrayList(Command) = .empty;
        for (self.commands) |cmd| {
            if (fuzzyMatch(cmd.label, q) or fuzzyMatch(cmd.description, q)) {
                result.append(self.arena.allocator(), cmd) catch |err| {
                    std.debug.print("[PALETTE] filter append failed: {}\n", .{err});
                };
            }
        }
        self.filtered = result.toOwnedSlice(self.arena.allocator()) catch self.commands;
        if (self.selected >= self.filtered.len) {
            self.selected = if (self.filtered.len > 0) self.filtered.len - 1 else 0;
        }
    }

    pub fn selectNext(self: *CommandPalette) void {
        if (self.filtered.len == 0) return;
        self.selected += 1;
        if (self.selected >= self.filtered.len) {
            self.selected = 0;
        }
        self.ensureVisible();
    }

    pub fn selectPrev(self: *CommandPalette) void {
        if (self.filtered.len == 0) return;
        if (self.selected == 0) {
            self.selected = self.filtered.len - 1;
        } else {
            self.selected -= 1;
        }
        self.ensureVisible();
    }

    fn ensureVisible(self: *CommandPalette) void {
        const visible_rows: usize = 12;
        if (self.selected < self.scroll_offset) {
            self.scroll_offset = self.selected;
        } else if (self.selected >= self.scroll_offset + visible_rows) {
            self.scroll_offset = self.selected - visible_rows + 1;
        }
    }

    pub fn executeSelected(self: *CommandPalette) void {
        if (self.filtered.len == 0 or self.app_ctx == null) return;
        const cmd = self.filtered[self.selected];
        if (cmd.handler_fn) |handler| {
            handler(self.app_ctx.?);
        }
    }

    pub fn getSelectedId(self: *const CommandPalette) ?[]const u8 {
        if (self.filtered.len == 0) return null;
        return self.filtered[self.selected].id;
    }

    pub fn render(self: *CommandPalette, win: vaxis.Window, palette: *const ColorPalette) void {
        if (!self.active) return;

        const width: u16 = @min(60, win.width - 4);
        const height: u16 = @min(15, win.height - 2);
        const start_x: i32 = @divTrunc(@as(i32, @intCast(win.width)) - @as(i32, @intCast(width)), 2);
        const start_y: i32 = @divTrunc(@as(i32, @intCast(win.height)) - @as(i32, @intCast(height)), 2);

        const box_win = win.child(.{
            .x_off = @intCast(@max(0, start_x)),
            .y_off = @intCast(@max(0, start_y)),
            .width = width,
            .height = height,
        });

        box_win.clear();

        const border_style = vaxis.Style{ .fg = palette.border_focused };
        const fg_style = vaxis.Style{ .fg = palette.fg };
        const dim_style = vaxis.Style{ .fg = palette.fg_dim };
        const selected_bg = vaxis.Style{ .bg = palette.bg_selected };
        const label_style = vaxis.Style{ .fg = palette.fg };
        const cat_style = vaxis.Style{ .fg = palette.info };

        const inner_w = width - 2;
        _ = box_win.print(&.{.{ .text = "┌", .style = border_style }}, .{
            .row_offset = 0, .col_offset = 0, .wrap = .none, .commit = true,
        });
        var col: u16 = 1;
        while (col < inner_w) : (col += 1) {
            _ = box_win.print(&.{.{ .text = "─", .style = border_style }}, .{
                .row_offset = 0, .col_offset = col, .wrap = .none, .commit = true,
            });
        }
        _ = box_win.print(&.{.{ .text = "┐", .style = border_style }}, .{
            .row_offset = 0, .col_offset = @intCast(inner_w), .wrap = .none, .commit = true,
        });

        _ = box_win.print(&.{.{ .text = "│", .style = border_style }}, .{
            .row_offset = height - 1, .col_offset = 0, .wrap = .none, .commit = true,
        });
        _ = box_win.print(&.{.{ .text = "│", .style = border_style }}, .{
            .row_offset = height - 1, .col_offset = @intCast(inner_w + 1), .wrap = .none, .commit = true,
        });

        var r: u16 = 1;
        while (r < height - 1) : (r += 1) {
            _ = box_win.print(&.{.{ .text = "│", .style = border_style }}, .{
                .row_offset = r, .col_offset = 0, .wrap = .none, .commit = true,
            });
            _ = box_win.print(&.{.{ .text = "│", .style = border_style }}, .{
                .row_offset = r, .col_offset = @intCast(inner_w + 1), .wrap = .none, .commit = true,
            });
        }

        _ = box_win.print(&.{.{ .text = "└", .style = border_style }}, .{
            .row_offset = height - 1, .col_offset = 0, .wrap = .none, .commit = true,
        });
        col = 1;
        while (col < inner_w) : (col += 1) {
            _ = box_win.print(&.{.{ .text = "─", .style = border_style }}, .{
                .row_offset = height - 1, .col_offset = col, .wrap = .none, .commit = true,
            });
        }
        _ = box_win.print(&.{.{ .text = "┘", .style = border_style }}, .{
            .row_offset = height - 1, .col_offset = @intCast(inner_w), .wrap = .none, .commit = true,
        });

        const title_text = "Command Palette";
        const title_x = @divTrunc(@as(i32, @intCast(inner_w)) - @as(i32, @intCast(title_text.len)), 2);
        _ = box_win.print(&.{.{ .text = title_text, .style = vaxis.Style{ .fg = palette.fg, .bold = true } }}, .{
            .row_offset = 0, .col_offset = @intCast(@max(1, title_x)), .wrap = .none, .commit = true,
        });

        _ = box_win.print(&.{.{ .text = ">", .style = vaxis.Style{ .fg = palette.fg, .bold = true } }}, .{
            .row_offset = 1, .col_offset = 1, .wrap = .none, .commit = true,
        });
        if (self.query.len > 0) {
            _ = box_win.print(&.{.{ .text = self.query, .style = fg_style }}, .{
                .row_offset = 1, .col_offset = 3, .wrap = .none, .commit = true,
            });
        } else {
            _ = box_win.print(&.{.{ .text = "Type to search...", .style = vaxis.Style{ .fg = palette.fg_dim, .italic = true } }}, .{
                .row_offset = 1, .col_offset = 3, .wrap = .none, .commit = true,
            });
        }

        _ = box_win.print(&.{.{ .text = "─", .style = border_style }}, .{
            .row_offset = 2, .col_offset = 1, .wrap = .none, .commit = true,
        });
        var cw: u16 = 2;
        while (cw < inner_w) : (cw += 1) {
            _ = box_win.print(&.{.{ .text = "─", .style = border_style }}, .{
                .row_offset = 2, .col_offset = cw, .wrap = .none, .commit = true,
            });
        }

        const list_start: u16 = 3;
        const list_height = height - 4;
        const visible_cmds = self.filtered[self.scroll_offset..];
        var row_idx: u16 = 0;
        for (visible_cmds, 0..) |cmd, i| {
            if (row_idx >= list_height) break;
            const global_idx = self.scroll_offset + i;
            const is_selected = (global_idx == self.selected);
            const y: u16 = list_start + row_idx;

            if (is_selected) {
                _ = box_win.print(&.{.{ .text = " ", .style = selected_bg }}, .{
                    .row_offset = y, .col_offset = 1, .wrap = .none, .commit = true,
                });
                var cw2: u16 = 2;
                while (cw2 < inner_w) : (cw2 += 1) {
                    _ = box_win.print(&.{.{ .text = " ", .style = selected_bg }}, .{
                        .row_offset = y, .col_offset = cw2, .wrap = .none, .commit = true,
                    });
                }
                _ = box_win.print(&.{.{ .text = "▶", .style = vaxis.Style{ .fg = palette.fg, .bold = true } }}, .{
                    .row_offset = y, .col_offset = 1, .wrap = .none, .commit = true,
                });
            }

            const max_label_len = @min(cmd.label.len, 16);
            _ = box_win.print(&.{.{ .text = cmd.label[0..max_label_len], .style = label_style }}, .{
                .row_offset = y, .col_offset = 3, .wrap = .none, .commit = true,
            });

            if (cmd.shortcut) |sc| {
                var key_buf: [8]u8 = undefined;
                const key_text = keyToString(sc.key, &key_buf);
                const shortcut_x = @as(u16, @intCast(inner_w)) - @as(u16, @intCast(key_text.len)) - 2;
                _ = box_win.print(&.{.{ .text = "[", .style = dim_style }}, .{
                    .row_offset = y, .col_offset = @max(3, shortcut_x - 1), .wrap = .none, .commit = true,
                });
                _ = box_win.print(&.{.{ .text = key_text, .style = cat_style }}, .{
                    .row_offset = y, .col_offset = @max(4, shortcut_x), .wrap = .none, .commit = true,
                });
                _ = box_win.print(&.{.{ .text = "]", .style = dim_style }}, .{
                    .row_offset = y, .col_offset = @intCast(@max(5, shortcut_x + 1) + key_text.len), .wrap = .none, .commit = true,
                });
            }

            row_idx += 1;
        }

        if (self.filtered.len == 0) {
            _ = box_win.print(&.{.{ .text = "No commands found", .style = vaxis.Style{ .fg = palette.fg_dim, .italic = true } }}, .{
                .row_offset = list_start, .col_offset = 3, .wrap = .none, .commit = true,
            });
        }

        const hint_text = "↑↓ navigate  Enter execute  Esc close";
        _ = box_win.print(&.{.{ .text = hint_text, .style = dim_style }}, .{
            .row_offset = height - 2, .col_offset = 1, .wrap = .none, .commit = true,
        });
    }
};

fn fuzzyMatch(text: []const u8, pattern: []const u8) bool {
    if (pattern.len == 0) return true;
    var pi: usize = 0;
    for (text) |ch| {
        if (std.ascii.toLower(ch) == std.ascii.toLower(pattern[pi])) {
            pi += 1;
            if (pi >= pattern.len) return true;
        }
    }
    return false;
}

fn keyToString(key: u21, buf: *[8]u8) []const u8 {
    if (key == vaxis.Key.escape) return "Esc";
    if (key == vaxis.Key.enter) return "Enter";
    if (key == vaxis.Key.backspace) return "Backspace";
    if (key == vaxis.Key.delete) return "Del";
    if (key == vaxis.Key.tab) return "Tab";
    if (key == vaxis.Key.up) return "↑";
    if (key == vaxis.Key.down) return "↓";
    if (key == vaxis.Key.left) return "←";
    if (key == vaxis.Key.right) return "→";
    if (key == vaxis.Key.home) return "Home";
    if (key == vaxis.Key.end) return "End";
    if (key == vaxis.Key.page_up) return "PgUp";
    if (key == vaxis.Key.page_down) return "PgDn";
    if (key > 0 and key < 128) {
        buf[0] = @truncate(key);
        return buf[0..1];
    }
    return "?";
}

test "command palette init" {
    const alloc = std.testing.allocator;
    var cp = CommandPalette.init(alloc);
    defer cp.deinit();
    try std.testing.expect(!cp.active);
    try std.testing.expect(cp.filtered.len > 0);
}

test "command palette open close" {
    const alloc = std.testing.allocator;
    var cp = CommandPalette.init(alloc);
    defer cp.deinit();
    cp.open();
    try std.testing.expect(cp.active);
    cp.close();
    try std.testing.expect(!cp.active);
}

test "command palette select next prev" {
    const alloc = std.testing.allocator;
    var cp = CommandPalette.init(alloc);
    defer cp.deinit();
    try std.testing.expect(cp.filtered.len > 0);
    const first = cp.filtered[0].id;
    cp.selectNext();
    try std.testing.expect(!std.mem.eql(u8, cp.filtered[cp.selected].id, first));
    cp.selectPrev();
    try std.testing.expect(std.mem.eql(u8, cp.filtered[cp.selected].id, first));
}

test "fuzzy match" {
    try std.testing.expect(fuzzyMatch("New Session", "ns"));
    try std.testing.expect(fuzzyMatch("New Session", "new"));
    try std.testing.expect(fuzzyMatch("New Session", "sess"));
    try std.testing.expect(!fuzzyMatch("New Session", "xyz"));
}
