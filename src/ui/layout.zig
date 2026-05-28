const std = @import("std");
const vaxis = @import("vaxis");

const Style = vaxis.Style;
const Color = vaxis.Color;
const Segment = vaxis.Segment;

pub const Panel = struct {
    x: u16,
    y: u16,
    width: u16,
    height: u16,
    visible: bool = true,
};

pub const Region = enum {
    chat,
    input,
    status,
    subagent,
    rlm,
};

pub const Layout = struct {
    width: u16,
    height: u16,
    panels: std.enums.EnumArray(Region, Panel),

    pub fn init(width: u16, height: u16) Layout {
        var layout = Layout{
            .width = width,
            .height = height,
            .panels = std.enums.EnumArray(Region, Panel).initDefault(.{
                .x = 0, .y = 0, .width = 0, .height = 0, .visible = true,
            }, .{}),
        };
        layout.recalculate();
        return layout;
    }

    pub fn resize(self: *Layout, width: u16, height: u16) void {
        self.width = width;
        self.height = height;
        self.recalculate();
    }

    fn recalculate(self: *Layout) void {
        const w = self.width;
        const h = self.height;

        const status_height: u16 = 1;
        const input_height: u16 = 5;
        const rlm_height: u16 = 8;
        const subagent_width: u16 = @min(30, w / 3);

        self.panels.set(.status, Panel{
            .x = 0,
            .y = 0,
            .width = w,
            .height = status_height,
        });

        self.panels.set(.rlm, Panel{
            .x = 0,
            .y = status_height,
            .width = subagent_width,
            .height = rlm_height,
        });

        self.panels.set(.subagent, Panel{
            .x = w -| subagent_width,
            .y = status_height,
            .width = subagent_width,
            .height = h -| status_height -| input_height,
        });

        self.panels.set(.chat, Panel{
            .x = 0,
            .y = status_height,
            .width = w -| subagent_width,
            .height = h -| status_height -| input_height,
        });

        self.panels.set(.input, Panel{
            .x = 0,
            .y = h -| input_height,
            .width = w,
            .height = input_height,
        });
    }

    pub fn get(self: *const Layout, region: Region) Panel {
        return self.panels.get(region);
    }

    pub fn getWindow(self: *const Layout, win: vaxis.Window, region: Region) vaxis.Window {
        const panel = self.get(region);
        return win.getWindow(.{
            .x_off = @intCast(panel.x),
            .y_off = @intCast(panel.y),
            .width = panel.width,
            .height = panel.height,
        });
    }
};

test "layout init" {
    var layout = Layout.init(80, 24);
    try std.testing.expect(layout.width == 80);
    try std.testing.expect(layout.height == 24);

    const chat = layout.get(.chat);
    try std.testing.expect(chat.width > 0);
    try std.testing.expect(chat.height > 0);
}

test "layout resize" {
    var layout = Layout.init(80, 24);
    layout.resize(120, 40);

    try std.testing.expect(layout.width == 120);
    try std.testing.expect(layout.height == 40);

    const chat = layout.get(.chat);
    try std.testing.expect(chat.width == 90);
}
