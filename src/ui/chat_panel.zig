const std = @import("std");
const vaxis = @import("vaxis");
const theme = @import("theme.zig");
const markdown = @import("markdown.zig");
const session_manager = @import("../storage/session_manager.zig");
const SessionMessage = session_manager.Message;

const Style = vaxis.Style;
const Color = vaxis.Color;
const Segment = vaxis.Segment;
const ColorPalette = theme.ColorPalette;

pub const RoleColor = struct {
    fg: Color,
    bg: ?Color,
};

pub const MessageStatus = enum {
    pending,
    streaming,
    complete,
    failed,
    truncated,
};

pub const ToolCall = struct {
    name: []const u8,
    arguments: []const u8,
    output: ?[]const u8 = null,
};

pub const Message = struct {
    role: []const u8,
    content: []const u8,
    thinking_content: ?[]const u8 = null,
    tool_calls: std.ArrayList(ToolCall),
    status: MessageStatus = .complete,
    timestamp: i64 = 0,
    thinking_collapsed: bool = false,
    collapsed: bool = false,
    owns_content: bool = false,
    img_id: ?u32 = null,
    img_width: u16 = 0,
    img_height: u16 = 0,
};

fn roleColor(role: []const u8) Color {
    if (std.mem.eql(u8, role, "user")) {
        return .{ .index = 12 };
    } else if (std.mem.eql(u8, role, "assistant")) {
        return .{ .index = 10 };
    } else if (std.mem.eql(u8, role, "system")) {
        return .{ .index = 13 };
    } else if (std.mem.eql(u8, role, "tool")) {
        return .{ .index = 208 };
    }
    return .{ .index = 8 };
}

fn statusIndicator(status: MessageStatus) []const u8 {
    return switch (status) {
        .pending => "○",
        .streaming => "◐",
        .complete => "✓",
        .failed => "✗",
        .truncated => "↱",
    };
}

fn statusColor(status: MessageStatus) Color {
    return switch (status) {
        .pending => .{ .index = 8 },
        .streaming => .{ .index = 14 },
        .complete => .{ .index = 10 },
        .failed => .{ .index = 9 },
        .truncated => .{ .index = 11 },
    };
}

fn formatRelativeTime(ts: i64, now: i64, buf: []u8) []const u8 {
    if (ts <= 0) return "";
    const diff = now - ts;
    if (diff < 0) return "future";
    if (diff < 60) return "now";
    if (diff < 3600) return std.fmt.bufPrint(buf, "{d}m ago", .{@divTrunc(diff, 60)}) catch "";
    if (diff < 86400) return std.fmt.bufPrint(buf, "{d}h ago", .{@divTrunc(diff, 3600)}) catch "";

    const ts_day = @divTrunc(ts, 86400);
    const now_day = @divTrunc(now, 86400);
    const secs_of_day = @mod(ts, 86400);
    const hours = @divTrunc(secs_of_day, 3600);
    const minutes = @mod(@divTrunc(secs_of_day, 60), 60);

    if (ts_day == now_day) {
        return std.fmt.bufPrint(buf, "{d:0>2}:{d:0>2}", .{ @as(u32, @intCast(hours)), @as(u32, @intCast(minutes)) }) catch "";
    }
    if (ts_day == now_day - 1) {
        return std.fmt.bufPrint(buf, "Yesterday {d:0>2}:{d:0>2}", .{ @as(u32, @intCast(hours)), @as(u32, @intCast(minutes)) }) catch "";
    }
    if (diff < 7 * 86400) {
        const day_names = [_][]const u8{ "Sun", "Mon", "Tue", "Wed", "Thu", "Fri", "Sat" };
        // Unix epoch day 0 was Thursday, so calculate day of week
        const dow = @mod(ts_day + 4, 7);
        return std.fmt.bufPrint(buf, "{s} {d:0>2}:{d:0>2}", .{ day_names[@intCast(dow)], @as(u32, @intCast(hours)), @as(u32, @intCast(minutes)) }) catch "";
    }
    return std.fmt.bufPrint(buf, "{d:0>2}/{d:0>2}", .{ @as(u32, @intCast(hours)), @as(u32, @intCast(minutes)) }) catch "";
}

pub const ChatPanel = struct {
    messages: std.ArrayList(Message),
    scroll_offset: u16 = 0,
    max_width: u16 = 0,
    alloc: std.mem.Allocator,
    render_arena: std.heap.ArenaAllocator,
    auto_scroll: bool = true,
    user_scrolled_up: bool = false,
    selected_msg_idx: ?usize = null,
    search_query: []const u8 = "",
    free_image_callback: ?*const fn (?*anyopaque, ?u32) void = null,
    free_image_ctx: ?*anyopaque = null,

    pub fn init(alloc: std.mem.Allocator) !ChatPanel {
        return .{
            .messages = try std.ArrayList(Message).initCapacity(alloc, 64),
            .scroll_offset = 0,
            .max_width = 0,
            .alloc = alloc,
            .render_arena = std.heap.ArenaAllocator.init(std.heap.page_allocator),
            .auto_scroll = true,
            .user_scrolled_up = false,
            .selected_msg_idx = null,
            .free_image_callback = null,
            .free_image_ctx = null,
        };
    }

    pub fn deinit(self: *ChatPanel) void {
        self.render_arena.deinit();
        for (self.messages.items) |*msg| {
            if (msg.owns_content and msg.content.len > 0) {
                self.alloc.free(msg.content);
            }
            if (msg.thinking_content) |tc| {
                self.alloc.free(tc);
            }
            msg.tool_calls.deinit(self.alloc);
        }
        self.messages.deinit(self.alloc);
    }

    pub fn addMessage(self: *ChatPanel, role: []const u8, content: []const u8) !void {
        var tool_calls = std.ArrayList(ToolCall).initCapacity(self.alloc, 4) catch return error.OutOfMemory;
        errdefer tool_calls.deinit(self.alloc);
        const owned_content = if (content.len > 0) try self.alloc.dupe(u8, content) else "";
        try self.messages.append(self.alloc, .{
            .role = role,
            .content = owned_content,
            .tool_calls = tool_calls,
            .status = .complete,
            .timestamp = session_manager.currentTimestamp(),
            .owns_content = content.len > 0,
        });
        if (self.auto_scroll) {
            self.scrollToBottom();
        }
    }

    pub fn startStreaming(self: *ChatPanel, role: []const u8) !usize {
        const idx = self.messages.items.len;
        var tool_calls = std.ArrayList(ToolCall).initCapacity(self.alloc, 4) catch return error.OutOfMemory;
        errdefer tool_calls.deinit(self.alloc);
        try self.messages.append(self.alloc, .{
            .role = role,
            .content = "",
            .tool_calls = tool_calls,
            .status = .streaming,
            .timestamp = session_manager.currentTimestamp(),
        });
        if (self.auto_scroll) {
            self.scrollToBottom();
        }
        return idx;
    }

    pub fn appendContent(self: *ChatPanel, idx: usize, content: []const u8) void {
        if (idx < self.messages.items.len) {
            const old = self.messages.items[idx].content;
            const new_content = std.mem.concat(self.alloc, u8, &.{ old, content }) catch {
                return;
            };
            if (self.messages.items[idx].owns_content and old.len > 0) {
                self.alloc.free(old);
            }
            self.messages.items[idx].content = new_content;
            self.messages.items[idx].owns_content = true;
            if (self.auto_scroll) {
                self.scrollToBottom();
            }
        }
    }

    pub fn setThinkingContent(self: *ChatPanel, idx: usize, content: []const u8) !void {
        if (idx < self.messages.items.len) {
            const old = self.messages.items[idx].thinking_content;
            const old_len = if (old) |o| o.len else 0;
            const total_len = old_len + content.len;
            
            const new_buf = try self.alloc.alloc(u8, total_len);
            @memcpy(new_buf[0..old_len], old orelse "");
            @memcpy(new_buf[old_len..total_len], content);
            
            if (old) |old_slice| {
                self.alloc.free(old_slice);
            }
            self.messages.items[idx].thinking_content = new_buf;
        }
    }

    pub fn setThinkingCollapsed(self: *ChatPanel, msg_idx: usize, collapsed: bool) void {
        if (msg_idx < self.messages.items.len) {
            self.messages.items[msg_idx].thinking_collapsed = collapsed;
        }
    }

    pub fn toggleThinkingCollapsed(self: *ChatPanel, msg_idx: usize) void {
        if (msg_idx < self.messages.items.len) {
            self.messages.items[msg_idx].thinking_collapsed = !self.messages.items[msg_idx].thinking_collapsed;
        }
    }

    pub fn addToolCall(self: *ChatPanel, msg_idx: usize, name: []const u8, args: []const u8) !usize {
        if (msg_idx >= self.messages.items.len) return error.InvalidIndex;
        const tool_call = ToolCall{
            .name = name,
            .arguments = args,
        };
        try self.messages.items[msg_idx].tool_calls.append(self.alloc, tool_call);
        return self.messages.items[msg_idx].tool_calls.items.len - 1;
    }

    pub fn setToolOutput(self: *ChatPanel, msg_idx: usize, call_idx: usize, output: []const u8) void {
        if (msg_idx < self.messages.items.len) {
            const tool_calls = &self.messages.items[msg_idx].tool_calls;
            if (call_idx < tool_calls.items.len) {
                tool_calls.items[call_idx].output = output;
            }
        }
    }

    pub fn finishStreaming(self: *ChatPanel, idx: usize) void {
        if (idx < self.messages.items.len) {
            self.messages.items[idx].status = .complete;
        }
    }

    pub fn setStatus(self: *ChatPanel, idx: usize, status: MessageStatus) void {
        if (idx < self.messages.items.len) {
            self.messages.items[idx].status = status;
        }
    }

    pub fn setError(self: *ChatPanel, idx: usize) void {
        if (idx < self.messages.items.len) {
            self.messages.items[idx].status = .failed;
        }
    }

    pub fn setTruncated(self: *ChatPanel, idx: usize) void {
        if (idx < self.messages.items.len) {
            self.messages.items[idx].status = .truncated;
        }
    }

    /// Remove all messages from `idx` to the end. Returns the content of the
    /// user message immediately preceding `idx`, if any.
    pub fn removeMessagesFrom(self: *ChatPanel, idx: usize) ?[]const u8 {
        if (idx >= self.messages.items.len) return null;

        // Find preceding user message content before we delete anything
        var user_input: ?[]const u8 = null;
        if (idx > 0) {
            var i = idx;
            while (i > 0) {
                i -= 1;
                if (std.mem.eql(u8, self.messages.items[i].role, "user")) {
                    user_input = self.messages.items[i].content;
                    break;
                }
            }
        }

        var j = self.messages.items.len;
        while (j > idx) {
            j -= 1;
            const msg = &self.messages.items[j];
            if (self.free_image_callback) |cb| {
                if (msg.img_id) |id| cb(self.free_image_ctx, id);
                msg.img_id = null;
            }
            if (msg.owns_content and msg.content.len > 0) {
                self.alloc.free(msg.content);
            }
            if (msg.thinking_content) |tc| {
                self.alloc.free(tc);
            }
            msg.tool_calls.deinit(self.alloc);
        }
        self.messages.shrinkRetainingCapacity(idx);
        // Scroll to show the last remaining message (newest)
        const max_scroll = if (self.messages.items.len > 0) self.messages.items.len - 1 else 0;
        self.scroll_offset = @intCast(max_scroll);
        self.auto_scroll = true;
        if (self.selected_msg_idx) |sel| {
            if (sel >= idx) self.selected_msg_idx = null;
        }
        return user_input;
    }

    /// Remove a single message at `idx`.
    pub fn removeMessageAt(self: *ChatPanel, idx: usize) void {
        if (idx >= self.messages.items.len) return;
        const msg = &self.messages.items[idx];
        if (self.free_image_callback) |cb| {
            if (msg.img_id) |id| cb(self.free_image_ctx, id);
            msg.img_id = null;
        }
        if (msg.owns_content and msg.content.len > 0) {
            self.alloc.free(msg.content);
        }
        if (msg.thinking_content) |tc| {
            self.alloc.free(tc);
        }
        msg.tool_calls.deinit(self.alloc);
        _ = self.messages.orderedRemove(idx);
        if (self.selected_msg_idx) |sel| {
            if (sel == idx) {
                self.selected_msg_idx = null;
            } else if (sel > idx and sel > 0) {
                self.selected_msg_idx = sel - 1;
            }
        }
        // Adjust scroll offset if the removed message was before the visible area
        if (self.scroll_offset > 0 and idx < self.scroll_offset) {
            self.scroll_offset -= 1;
        }
        // Ensure scroll_offset stays valid after removal
        const max_scroll = if (self.messages.items.len > 0) self.messages.items.len - 1 else 0;
        if (self.scroll_offset > max_scroll) {
            self.scroll_offset = @intCast(max_scroll);
        }
    }

    pub fn selectMessage(self: *ChatPanel, idx: usize) void {
        if (idx < self.messages.items.len) {
            self.selected_msg_idx = idx;
        }
    }

    pub fn selectPrev(self: *ChatPanel) void {
        if (self.messages.items.len == 0) return;
        if (self.selected_msg_idx) |sel| {
            if (sel > 0) self.selected_msg_idx = sel - 1;
        } else {
            self.selected_msg_idx = self.messages.items.len - 1;
        }
    }

    pub fn selectNext(self: *ChatPanel) void {
        if (self.messages.items.len == 0) return;
        if (self.selected_msg_idx) |sel| {
            if (sel + 1 < self.messages.items.len) self.selected_msg_idx = sel + 1;
        } else {
            self.selected_msg_idx = 0;
        }
    }

    pub fn clearSelection(self: *ChatPanel) void {
        self.selected_msg_idx = null;
    }

    pub fn getSelectedContent(self: *const ChatPanel) ?[]const u8 {
        const idx = self.selected_msg_idx orelse return null;
        if (idx >= self.messages.items.len) return null;
        return self.messages.items[idx].content;
    }

    pub fn clear(self: *ChatPanel) void {
        for (self.messages.items) |*msg| {
            if (self.free_image_callback) |cb| {
                if (msg.img_id) |id| cb(self.free_image_ctx, id);
            }
            if (msg.owns_content and msg.content.len > 0) {
                self.alloc.free(msg.content);
            }
            if (msg.thinking_content) |tc| {
                self.alloc.free(tc);
            }
            msg.tool_calls.deinit(self.alloc);
        }
        self.messages.clearRetainingCapacity();
        self.scroll_offset = 0;
        self.auto_scroll = true;
        self.user_scrolled_up = false;
        self.selected_msg_idx = null;
    }

    pub fn loadFromSession(self: *ChatPanel, session_messages: []const SessionMessage) !void {
        self.clear();
        for (session_messages) |msg| {
            try self.addMessage(msg.role, msg.content);
            if (self.messages.items.len > 0) {
                self.messages.items[self.messages.items.len - 1].timestamp = msg.timestamp;
            }
        }
    }

    pub fn scrollUp(self: *ChatPanel, lines: u16) void {
        if (self.scroll_offset < lines) {
            self.scroll_offset = 0;
        } else {
            self.scroll_offset -= lines;
        }
        self.user_scrolled_up = true;
        self.auto_scroll = false;
    }

    pub fn scrollDown(self: *ChatPanel, lines: u16) void {
        const max_scroll: u16 = if (self.messages.items.len > 0)
            @intCast(@min(self.messages.items.len - 1, std.math.maxInt(u16)))
        else
            0;
        const new_offset = @as(u32, self.scroll_offset) + @as(u32, lines);
        self.scroll_offset = @min(new_offset, max_scroll);
        if (self.scroll_offset >= max_scroll) {
            self.user_scrolled_up = false;
            self.auto_scroll = true;
        }
    }

    pub fn scrollToBottom(self: *ChatPanel) void {
        const max_scroll: u16 = if (self.messages.items.len > 0)
            @intCast(@min(self.messages.items.len - 1, std.math.maxInt(u16)))
        else
            0;
        self.scroll_offset = max_scroll;
        self.user_scrolled_up = false;
        self.auto_scroll = true;
    }

    pub fn scrollToTop(self: *ChatPanel) void {
        self.scroll_offset = 0;
        self.user_scrolled_up = true;
        self.auto_scroll = false;
    }

    pub fn checkAutoScroll(self: *ChatPanel) void {
        if (!self.user_scrolled_up) {
            self.auto_scroll = true;
        }
    }

    /// Render markdown-formatted text into a window area, returning the next available row
fn highlightSegment(
    alloc: std.mem.Allocator,
    seg: Segment,
    query: []const u8,
    hl_bg: vaxis.Color,
    out: *std.ArrayList(Segment),
) void {
    var remaining = seg.text;
    while (remaining.len > 0) {
        const match_start = std.mem.indexOf(u8, remaining, query) orelse {
            out.append(alloc, .{ .text = remaining, .style = seg.style }) catch {};
            return;
        };
        if (match_start > 0) {
            out.append(alloc, .{ .text = remaining[0..match_start], .style = seg.style }) catch {};
        }
        const match_end = match_start + query.len;
        var hl_style = seg.style;
        hl_style.bg = hl_bg;
        out.append(alloc, .{ .text = remaining[match_start..match_end], .style = hl_style }) catch {};
        remaining = remaining[match_end..];
    }
}

fn renderMarkdownContent(
    win: vaxis.Window,
    content: []const u8,
    width: u16,
    palette: *const ColorPalette,
    start_row: u16,
    visible_height: u16,
    alloc: std.mem.Allocator,
    search_query: ?[]const u8,
) u16 {
    if (content.len == 0) return start_row;
    const lines = markdown.renderText(alloc, content, width, palette) catch return start_row;
    // Note: defer cleanup skipped intentionally when using arena allocator —
    // the arena is reset by the caller (renderWithTheme) after all rendering completes.

    var row = start_row;
    for (lines.items) |line| {
        if (row >= visible_height) break;
        if (line.segments.items.len == 0) {
            row += 1;
            continue;
        }
        if (search_query) |query| {
            var segs = std.ArrayList(Segment).initCapacity(alloc, line.segments.items.len * 2) catch {
                _ = win.print(line.segments.items, .{
                    .row_offset = row,
                    .col_offset = 1,
                    .wrap = .none,
                    .commit = true,
                });
                row += 1;
                continue;
            };
            for (line.segments.items) |seg| {
                highlightSegment(alloc, seg, query, palette.bg_selected, &segs);
            }
            if (segs.items.len > 0) {
                _ = win.print(segs.items, .{
                    .row_offset = row,
                    .col_offset = 1,
                    .wrap = .none,
                    .commit = true,
                });
            }
        } else {
            _ = win.print(line.segments.items, .{
                .row_offset = row,
                .col_offset = 1,
                .wrap = .none,
                .commit = true,
            });
        }
        row += 1;
    }
    return row;
}

fn countContentLines(content: []const u8, width: u16) u16 {
        var lines: u16 = 0;
        var i: usize = 0;
        while (i < content.len) {
            const line_start = i;
            while (i < content.len and content[i] != '\n') {
                i += 1;
            }
            const line_len: u16 = @intCast(@min(std.math.maxInt(u16), i - line_start));
            if (line_len > 0) {
                const available_width = if (width >= 2) width - 2 else width;
                if (available_width > 0) {
                    lines += (line_len / available_width) + 1;
                } else {
                    lines += 1;
                }
            } else {
                lines += 1;
            }
            if (i < content.len and content[i] == '\n') {
                i += 1;
            }
        }
        return @max(1, lines);
    }

    pub fn renderWithTheme(self: *ChatPanel, win: vaxis.Window, palette: *const ColorPalette, thinking_visible: bool) void {
        win.clear();
        _ = self.render_arena.reset(.retain_capacity);

        const width = win.width;
        const visible_height = win.height;

        var current_row: u16 = 0;
        var msg_idx: usize = self.scroll_offset;
        if (msg_idx >= self.messages.items.len) {
            msg_idx = if (self.messages.items.len > 0) self.messages.items.len - 1 else 0;
            self.scroll_offset = @intCast(msg_idx);
        }

        while (msg_idx < self.messages.items.len) {
            if (current_row >= visible_height) break;

            const msg = self.messages.items[msg_idx];
            const is_selected = self.selected_msg_idx == msg_idx;

            const header_prefix = statusIndicator(msg.status);
            const role_col: Color = if (std.mem.eql(u8, msg.role, "user"))
                palette.user_msg_bg
            else if (std.mem.eql(u8, msg.role, "assistant"))
                palette.assistant_msg_bg
            else if (std.mem.eql(u8, msg.role, "system"))
                palette.system_msg_bg
            else if (std.mem.eql(u8, msg.role, "tool"))
                palette.tool_call
            else
                palette.fg_dim;

            const role_seg = Segment{
                .text = msg.role,
                .style = .{
                    .fg = role_col,
                    .bold = true,
                },
            };
            const status_seg = Segment{
                .text = header_prefix,
                .style = .{
                    .fg = statusColor(msg.status),
                    .bold = msg.status == .streaming,
                },
            };

            const now = session_manager.currentTimestamp();
            var time_buf: [32]u8 = undefined;
            const time_str: ?[]const u8 = if (msg.timestamp > 0)
                formatRelativeTime(msg.timestamp, now, &time_buf)
            else
                null;

            const sel_seg = Segment{
                .text = if (is_selected) "> " else "  ",
                .style = .{
                    .fg = if (is_selected) palette.fg_bright else palette.fg_dim,
                    .bold = is_selected,
                },
            };

            const search_match = self.search_query.len > 0 and
                (std.mem.indexOf(u8, msg.content, self.search_query) != null or
                 (msg.thinking_content != null and std.mem.indexOf(u8, msg.thinking_content.?, self.search_query) != null));
            const search_seg = Segment{
                .text = if (search_match) "★ " else "  ",
                .style = .{ .fg = palette.warning, .bold = true },
            };

            if (time_str) |ts| {
                _ = win.print(&.{
                    sel_seg,
                    search_seg,
                    status_seg,
                    .{ .text = " ", .style = .{} },
                    role_seg,
                    .{ .text = " ", .style = .{} },
                    .{ .text = ts, .style = .{ .fg = palette.fg_dim } },
                    .{ .text = ": ", .style = .{} },
                }, .{
                    .row_offset = current_row,
                    .col_offset = 0,
                    .wrap = .none,
                    .commit = true,
                });
            } else {
                _ = win.print(&.{
                    sel_seg,
                    search_seg,
                    status_seg,
                    .{ .text = " ", .style = .{} },
                    role_seg,
                    .{ .text = ": ", .style = .{} },
                }, .{
                    .row_offset = current_row,
                    .col_offset = 0,
                    .wrap = .none,
                    .commit = true,
                });
            }
            current_row += 1;

            if (current_row >= visible_height) break;

            // If message is collapsed, show summary and skip content
            if (msg.collapsed) {
                if (current_row < visible_height) {
                    const summary_len = @min(msg.content.len, 60);
                    const summary = if (msg.content.len > summary_len) msg.content[0..summary_len] else msg.content;
                    const ellipsis = if (msg.content.len > summary_len) "..." else "";
                    const role_icon = if (std.mem.eql(u8, msg.role, "user")) "👤" else if (std.mem.eql(u8, msg.role, "assistant")) "🤖" else "⚙";
                    const collapsed_text = std.fmt.allocPrint(self.alloc, "  {s} [▸ {s}] {s}{s}", .{ role_icon, msg.role, summary, ellipsis }) catch "  [▸] ...";
                    defer self.alloc.free(collapsed_text);
                    _ = win.print(&.{.{ .text = collapsed_text, .style = .{ .fg = palette.fg_dim } }}, .{
                        .row_offset = current_row,
                        .col_offset = 0,
                        .wrap = .none,
                        .commit = true,
                    });
                    current_row += 1;
                }
                msg_idx += 1;
                // Draw separator
                if (msg_idx < self.messages.items.len and current_row < visible_height) {
                    var sep_buf: [512]u8 = undefined;
                    const sep_len = @min(win.width, sep_buf.len);
                    if (sep_len >= 3) {
                        sep_buf[0] = 0xE2;
                        sep_buf[1] = 0x94;
                        sep_buf[2] = 0x9C;
                        var j: usize = 3;
                        while (j + 2 < sep_len) : (j += 3) {
                            sep_buf[j] = 0xE2;
                            sep_buf[j + 1] = 0x94;
                            sep_buf[j + 2] = 0x80;
                        }
                        while (j < sep_len) : (j += 1) {
                            sep_buf[j] = ' ';
                        }
                        _ = win.print(&.{.{ .text = sep_buf[0..sep_len], .style = .{ .fg = palette.fg_dim } }}, .{
                            .row_offset = current_row,
                            .col_offset = 0,
                            .wrap = .none,
                            .commit = true,
                        });
                        current_row += 1;
                    }
                    if (current_row >= visible_height) break;
                }
                continue;
            }

            if (thinking_visible and msg.thinking_content != null) {
                const thinking = msg.thinking_content.?;
                const thinking_prefix = if (msg.thinking_collapsed) "[▸ " else "[▾ ";

                const think_prefix_seg = Segment{
                    .text = thinking_prefix,
                    .style = .{
                        .fg = palette.thinking,
                        .italic = true,
                    },
                };

                _ = win.print(&.{think_prefix_seg}, .{
                    .row_offset = current_row,
                    .col_offset = 1,
                    .wrap = .none,
                    .commit = true,
                });
                current_row += 1;

                if (current_row >= visible_height) break;

                if (!msg.thinking_collapsed) {
                    const effective_width = if (width > 4) width - 4 else width;
                    const lines = countContentLines(thinking, effective_width);
                    var line_start: usize = 0;
                    var line_idx: u16 = 0;

                    while (line_idx < lines and current_row < visible_height) {
                        const prev_line_start = line_start;
                        while (line_start < thinking.len and thinking[line_start] != '\n') {
                            line_start += 1;
                        }
                        const line_content = thinking[prev_line_start..line_start];

                        if (line_content.len > 0) {
                            const base_style = vaxis.Style{
                                .fg = palette.fg_dim,
                                .italic = true,
                            };
                            if (self.search_query.len > 0) {
                                var segs = std.ArrayList(Segment).initCapacity(self.render_arena.allocator(), 3) catch {
                                    _ = win.print(&.{.{ .text = line_content, .style = base_style }}, .{
                                        .row_offset = current_row,
                                        .col_offset = 3,
                                        .wrap = .word,
                                        .commit = true,
                                    });
                                    current_row += 1;
                                    continue;
                                };
                                highlightSegment(self.render_arena.allocator(), .{ .text = line_content, .style = base_style }, self.search_query, palette.bg_selected, &segs);
                                _ = win.print(segs.items, .{
                                    .row_offset = current_row,
                                    .col_offset = 3,
                                    .wrap = .word,
                                    .commit = true,
                                });
                            } else {
                                _ = win.print(&.{.{ .text = line_content, .style = base_style }}, .{
                                    .row_offset = current_row,
                                    .col_offset = 3,
                                    .wrap = .word,
                                    .commit = true,
                                });
                            }
                            current_row += 1;
                        } else {
                            current_row += 1;
                        }

                        if (line_start < thinking.len and thinking[line_start] == '\n') {
                            line_start += 1;
                        }
                        line_idx += 1;

                        if (current_row >= visible_height) break;
                    }
                }

                if (current_row < visible_height) {
                    const think_suffix_seg = Segment{
                        .text = "...] ",
                        .style = .{
                            .fg = palette.thinking,
                            .italic = true,
                        },
                    };
                    _ = win.print(&.{think_suffix_seg}, .{
                        .row_offset = current_row,
                        .col_offset = 1,
                        .wrap = .none,
                        .commit = true,
                    });
                    current_row += 1;
                }

                if (current_row >= visible_height) break;
            }

            for (msg.tool_calls.items) |tool_call| {
                const tool_prefix = Segment{
                    .text = "🔧 ",
                    .style = .{
                        .fg = palette.tool_call,
                    },
                };
                const tool_name = Segment{
                    .text = tool_call.name,
                    .style = .{
                        .fg = palette.tool_call,
                        .bold = true,
                    },
                };
                _ = win.print(&.{ tool_prefix, tool_name }, .{
                    .row_offset = current_row,
                    .col_offset = 1,
                    .wrap = .none,
                    .commit = true,
                });
                current_row += 1;

                if (current_row >= visible_height) break;

                if (tool_call.arguments.len > 0) {
                    const args_seg = Segment{
                        .text = tool_call.arguments,
                        .style = .{
                            .fg = palette.fg_dim,
                        },
                    };
                    _ = win.print(&.{args_seg}, .{
                        .row_offset = current_row,
                        .col_offset = 3,
                        .wrap = .word,
                        .commit = true,
                    });
                    current_row += 1;
                }

                if (current_row >= visible_height) break;

                if (tool_call.output) |output| {
                    const output_arrow = Segment{
                        .text = "→ ",
                        .style = .{
                            .fg = palette.success,
                        },
                    };
                    const output_seg = Segment{
                        .text = output,
                        .style = .{
                            .fg = palette.fg,
                        },
                    };
                    _ = win.print(&.{ output_arrow, output_seg }, .{
                        .row_offset = current_row,
                        .col_offset = 3,
                        .wrap = .word,
                        .commit = true,
                    });
                    current_row += 1;
                }

                if (current_row >= visible_height) break;
            }

            if (msg.content.len > 0) {
                current_row = renderMarkdownContent(
                    win,
                    msg.content,
                    width,
                    palette,
                    current_row,
                    visible_height,
                    self.render_arena.allocator(),
                    if (self.search_query.len > 0) self.search_query else null,
                );
            }

            if (msg.status == .failed and current_row < visible_height) {
                const retry_seg = Segment{
                    .text = "  [Ctrl+R to retry]",
                    .style = .{
                        .fg = palette.fg_dim,
                        .italic = true,
                    },
                };
                _ = win.print(&.{retry_seg}, .{
                    .row_offset = current_row,
                    .col_offset = 0,
                    .wrap = .none,
                    .commit = true,
                });
                current_row += 1;
            }

            // Render image if present
            if (msg.img_id) |id| {
                if (current_row < visible_height) {
                    const img = vaxis.Image{ .id = id, .width = msg.img_width, .height = msg.img_height };
                    const img_height = @min(visible_height -| current_row -| 1, 20);
                    const img_win = win.child(.{
                        .x_off = 2,
                        .y_off = current_row,
                        .width = width -| 4,
                        .height = img_height,
                    });
                    img.draw(img_win, .{ .scale = .fit }) catch |err| {
                        std.debug.print("[IMAGE] draw failed: {}\n", .{err});
                    };
                    const cell_size = img.cellSize(img_win) catch vaxis.Image.CellSize{ .rows = 3, .cols = 10 };
                    current_row += cell_size.rows;
                }
            }

            if (current_row < visible_height) {
                current_row += 1;
            }
            msg_idx += 1;

            // Draw separator line between messages (except after last)
            if (msg_idx < self.messages.items.len and current_row < visible_height) {
                var sep_buf: [512]u8 = undefined;
                const sep_len = @min(win.width, sep_buf.len);
                // Use box-drawing chars: ├ (E2 94 9C) followed by ─ (E2 94 80) repeated
                if (sep_len >= 3) {
                    sep_buf[0] = 0xE2;
                    sep_buf[1] = 0x94;
                    sep_buf[2] = 0x9C;
                    var j: usize = 3;
                    while (j + 2 < sep_len) : (j += 3) {
                        sep_buf[j] = 0xE2;
                        sep_buf[j + 1] = 0x94;
                        sep_buf[j + 2] = 0x80;
                    }
                    // Fill remaining with spaces if any
                    while (j < sep_len) : (j += 1) {
                        sep_buf[j] = ' ';
                    }
                    const sep_line = sep_buf[0..sep_len];
                    _ = win.print(&.{.{ .text = sep_line, .style = .{ .fg = palette.fg_dim } }}, .{
                        .row_offset = current_row,
                        .col_offset = 0,
                        .wrap = .none,
                        .commit = true,
                    });
                    current_row += 1;
                }
                if (current_row >= visible_height) break;
            }
        }
    }

    pub fn render(self: *const ChatPanel, win: vaxis.Window) void {
        // Build a default palette from ANSI color indices for backward compatibility
        const default_palette = ColorPalette{
            .bg = .{ .index = 0 },
            .bg_alt = .{ .index = 8 },
            .bg_hover = .{ .index = 8 },
            .bg_active = .{ .index = 8 },
            .bg_selected = .{ .index = 8 },
            .fg = .{ .index = 15 },
            .fg_dim = .{ .index = 8 },
            .fg_bright = .{ .index = 15 },
            .fg_inverse = .{ .index = 0 },
            .user_msg_bg = .{ .index = 4 },
            .assistant_msg_bg = .{ .index = 2 },
            .system_msg_bg = .{ .index = 3 },
            .border = .{ .index = 8 },
            .border_focused = .{ .index = 14 },
            .scrollbar = .{ .index = 8 },
            .success = .{ .index = 10 },
            .warning = .{ .index = 11 },
            .error_color = .{ .index = 9 },
            .info = .{ .index = 14 },
            .link = .{ .index = 12 },
            .thinking = .{ .index = 14 },
            .tool_call = .{ .index = 208 },
            .prompt = .{ .index = 10 },
        };
        self.renderWithTheme(win, &default_palette, true);
    }
};

test "chat panel add message" {
    const alloc = std.testing.allocator;
    var panel = ChatPanel.init(alloc);
    defer panel.deinit();

    try panel.addMessage("user", "Hello");
    try panel.addMessage("assistant", "Hi there!");

    try std.testing.expectEqual(@as(usize, 2), panel.messages.items.len);
    try std.testing.expectEqualSlices(u8, "Hello", panel.messages.items[0].content);
    try std.testing.expectEqualSlices(u8, "Hi there!", panel.messages.items[1].content);
    try std.testing.expectEqual(MessageStatus.complete, panel.messages.items[0].status);
}

test "chat panel streaming" {
    const alloc = std.testing.allocator;
    var panel = ChatPanel.init(alloc);
    defer panel.deinit();

    const idx = try panel.startStreaming("assistant");
    try std.testing.expectEqual(@as(usize, 0), idx);
    try std.testing.expectEqual(MessageStatus.streaming, panel.messages.items[idx].status);

    panel.appendContent(idx, "Hello");
    panel.appendContent(idx, " World");

    try std.testing.expectEqualSlices(u8, "Hello World", panel.messages.items[idx].content);

    panel.finishStreaming(idx);
    try std.testing.expectEqual(MessageStatus.complete, panel.messages.items[idx].status);
}

test "message status enum" {
    try std.testing.expectEqual(@as(u8, 0), @intFromEnum(MessageStatus.pending));
    try std.testing.expectEqual(@as(u8, 1), @intFromEnum(MessageStatus.streaming));
    try std.testing.expectEqual(@as(u8, 2), @intFromEnum(MessageStatus.complete));
    try std.testing.expectEqual(@as(u8, 3), @intFromEnum(MessageStatus.failed));
    try std.testing.expectEqual(@as(u8, 4), @intFromEnum(MessageStatus.truncated));
}

test "tool calls" {
    const alloc = std.testing.allocator;
    var panel = ChatPanel.init(alloc);
    defer panel.deinit();

    const idx = try panel.startStreaming("assistant");

    const call_idx = try panel.addToolCall(idx, "bash", "{ \"command\": \"ls -la\" }");
    try std.testing.expectEqual(@as(usize, 0), call_idx);

    panel.setToolOutput(idx, call_idx, "total 32\ndrwxrwxr-xr-x  5 user  staff   160 May 19 14:00 .\ndrwxr-xr-x  9 user  staff   288 May 19 14:00 ..");

    try std.testing.expectEqual(@as(usize, 1), panel.messages.items[idx].tool_calls.items.len);
    try std.testing.expectEqualSlices(u8, "bash", panel.messages.items[idx].tool_calls.items[0].name);
    try std.testing.expectEqualSlices(u8, "{ \"command\": \"ls -la\" }", panel.messages.items[idx].tool_calls.items[0].arguments);
    try std.testing.expect(panel.messages.items[idx].tool_calls.items[0].output != null);
}

test "thinking content" {
    const alloc = std.testing.allocator;
    var panel = ChatPanel.init(alloc);
    defer panel.deinit();

    try panel.addMessage("assistant", "The answer is 42.");

    try panel.setThinkingContent(0, "Let me think about this...");
    try panel.setThinkingContent(0, " I've analyzed the problem.");

    try std.testing.expect(panel.messages.items[0].thinking_content != null);
    const thinking = panel.messages.items[0].thinking_content.?;
    try std.testing.expectEqualSlices(u8, "Let me think about this... I've analyzed the problem.", thinking);

    try std.testing.expectEqual(false, panel.messages.items[0].thinking_collapsed);
    panel.toggleThinkingCollapsed(0);
    try std.testing.expectEqual(true, panel.messages.items[0].thinking_collapsed);
}

test "auto scroll" {
    const alloc = std.testing.allocator;
    var panel = ChatPanel.init(alloc);
    defer panel.deinit();

    try std.testing.expectEqual(true, panel.auto_scroll);
    try std.testing.expectEqual(false, panel.user_scrolled_up);

    panel.scrollUp(5);
    try std.testing.expectEqual(false, panel.auto_scroll);
    try std.testing.expectEqual(true, panel.user_scrolled_up);

    panel.scrollToBottom();
    try std.testing.expectEqual(true, panel.auto_scroll);
    try std.testing.expectEqual(false, panel.user_scrolled_up);
}

test "error and truncated status" {
    const alloc = std.testing.allocator;
    var panel = ChatPanel.init(alloc);
    defer panel.deinit();

    const idx = try panel.startStreaming("assistant");
    try std.testing.expectEqual(MessageStatus.streaming, panel.messages.items[idx].status);

    panel.setError(idx);
    try std.testing.expectEqual(MessageStatus.failed, panel.messages.items[idx].status);

    const idx2 = try panel.startStreaming("assistant");
    panel.setTruncated(idx2);
    try std.testing.expectEqual(MessageStatus.truncated, panel.messages.items[idx2].status);
}

test "status indicators" {
    try std.testing.expectEqualSlices(u8, "○", statusIndicator(.pending));
    try std.testing.expectEqualSlices(u8, "◐", statusIndicator(.streaming));
    try std.testing.expectEqualSlices(u8, "✓", statusIndicator(.complete));
    try std.testing.expectEqualSlices(u8, "✗", statusIndicator(.failed));
    try std.testing.expectEqualSlices(u8, "↱", statusIndicator(.truncated));
}
