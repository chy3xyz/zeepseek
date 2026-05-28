const std = @import("std");
const builtin = @import("builtin");
const vaxis = @import("vaxis");

const Style = vaxis.Style;
const Color = vaxis.Color;
const Segment = vaxis.Segment;

pub const StatusBar = struct {
    cache_hit_rate: f64 = 0.0,
    cache_size: u64 = 0,
    model: []const u8 = "deepseek-chat",
    provider: []const u8 = "deepseek",
    memory_used: u64 = 0,
    memory_budget: u64 = 15 * 1024 * 1024,
    tokens_used: u64 = 0,
    ctx_max: u64 = 64000,
    folding_state: []const u8 = "none",
    turn: u32 = 0,
    streaming: bool = false,
    subagent_active: u32 = 0,
    subagent_total: u32 = 0,

    pub fn render(self: *const StatusBar, win: vaxis.Window) void {
        // Guard against division by zero
        const mem_pct = if (self.memory_budget > 0)
            @as(f64, @floatFromInt(self.memory_used)) / @as(f64, @floatFromInt(self.memory_budget)) * 100.0
        else
            0.0;
        const ctx_pct = if (self.ctx_max > 0)
            @as(f64, @floatFromInt(self.tokens_used)) / @as(f64, @floatFromInt(self.ctx_max)) * 100.0
        else
            0.0;
        const stream_indicator = if (self.streaming) " ⏳ " else " ";
        var buf: [512]u8 = undefined;

        // Tiered truncation based on available width
        const text = blk: {
            if (win.width >= 100) {
                if (self.subagent_total > 0) {
                    break :blk std.fmt.bufPrint(&buf, "{s}[{s}] turn={d} | model={s} | ctx={d:.0}/{d} ({d:.0}%) | cache={d:.0}% ({d}KB) | mem={d:.1}MB/{d}MB ({d:.0}%) | sub={d}/{d} | fold={s}", .{
                        stream_indicator, self.provider, self.turn, self.model,
                        self.tokens_used, self.ctx_max, ctx_pct,
                        self.cache_hit_rate * 100.0, self.cache_size / 1024,
                        self.memory_used / (1024 * 1024), self.memory_budget / (1024 * 1024), mem_pct,
                        self.subagent_active, self.subagent_total, self.folding_state,
                    }) catch return;
                } else {
                    break :blk std.fmt.bufPrint(&buf, "{s}[{s}] turn={d} | model={s} | ctx={d:.0}/{d} ({d:.0}%) | cache={d:.0}% ({d}KB) | mem={d:.1}MB/{d}MB ({d:.0}%) | fold={s}", .{
                        stream_indicator, self.provider, self.turn, self.model,
                        self.tokens_used, self.ctx_max, ctx_pct,
                        self.cache_hit_rate * 100.0, self.cache_size / 1024,
                        self.memory_used / (1024 * 1024), self.memory_budget / (1024 * 1024), mem_pct,
                        self.folding_state,
                    }) catch return;
                }
            } else if (win.width >= 60) {
                break :blk std.fmt.bufPrint(&buf, "{s}[{s}] turn={d} | model={s} | ctx={d:.0}% | sub={d}/{d}", .{
                    stream_indicator, self.provider, self.turn, self.model, ctx_pct,
                    self.subagent_active, self.subagent_total,
                }) catch return;
            } else if (win.width >= 35) {
                break :blk std.fmt.bufPrint(&buf, "{s}[{s}] {s}", .{
                    stream_indicator, self.provider, self.model,
                }) catch return;
            } else {
                break :blk std.fmt.bufPrint(&buf, "{s}[{s}]", .{
                    stream_indicator, self.provider,
                }) catch return;
            }
        };

        // Truncate text to fit window width to prevent overflow
        const display_text = if (text.len > win.width) text[0..win.width] else text;

        const hint_text = if (builtin.os.tag == .macos) " ? help  ⌘+P cmd " else " ? help  Ctrl+P cmd ";
        const hint_col = if (win.width > display_text.len + hint_text.len)
            @as(u16, @intCast(win.width - hint_text.len))
        else
            0;

        // Dynamic color: warn on high memory OR high context usage
        const status_fg = if (mem_pct > 80 or ctx_pct > 80)
            Color{ .index = 9 } // red
        else if (mem_pct > 60 or ctx_pct > 60)
            Color{ .index = 11 } // yellow
        else
            Color{ .index = 8 }; // default dim

        _ = win.print(&.{
            .{
                .text = display_text,
                .style = .{
                    .fg = status_fg,
                },
            },
        }, .{
            .row_offset = 0,
            .col_offset = 0,
            .wrap = .none,
            .commit = true,
        });

        if (hint_col > 0) {
            _ = win.print(&.{
                .{
                    .text = hint_text,
                    .style = .{
                        .fg = .{.index = 8},
                    },
                },
            }, .{
                .row_offset = 0,
                .col_offset = hint_col,
                .wrap = .none,
                .commit = true,
            });
        }
    }
};

test "status bar format" {
    _ = std.testing.allocator;
    const status = StatusBar{
        .cache_hit_rate = 0.85,
        .cache_size = 1024 * 500,
        .model = "deepseek-chat",
        .provider = "deepseek",
        .memory_used = 5 * 1024 * 1024,
        .tokens_used = 32000,
        .folding_state = "fold_normal",
        .turn = 42,
    };

    try std.testing.expect(status.cache_hit_rate == 0.85);
    try std.testing.expect(status.turn == 42);
}
