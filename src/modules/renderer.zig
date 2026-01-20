//! 字符渲染系统 (Xft 实现)
const std = @import("std");
const x11 = @import("x11.zig");
const types = @import("types.zig");
const config = @import("config.zig");
const Window = @import("window.zig").Window;

const Glyph = types.Glyph;
const Term = types.Term;

pub const RendererError = error{
    XftDrawCreateFailed,
    FontLoadFailed,
    ColorAllocFailed,
};

pub const Renderer = struct {
    window: *Window,
    allocator: std.mem.Allocator,
    draw: *x11.XftDraw,
    font: *x11.XftFont,

    char_width: u32,
    char_height: u32,
    ascent: i32,
    descent: i32,

    // Color cache
    colors: [260]x11.XftColor,
    loaded_colors: [260]bool,

    pub fn init(window: *Window, allocator: std.mem.Allocator) !Renderer {
        // Initialize buffer in window if not already
        window.resizeBuffer(window.width, window.height);

        const draw = x11.XftDrawCreate(window.dpy, window.buf, window.vis, window.cmap);
        if (draw == null) return error.XftDrawCreateFailed;

        // Load font
        const font_name = config.Config.font.name; // e.g., "Monospace:size=12"
        _ = font_name;
        // For simplicity, use a simpler default if config is complex
        const default_font = "Monospace:pixelsize=20";

        var font = x11.XftFontOpenName(window.dpy, window.screen, default_font);
        if (font == null) {
            std.log.err("Failed to load font: {s}, trying backup\n", .{default_font});
            font = x11.XftFontOpenName(window.dpy, window.screen, "fixed");
            if (font == null) return error.FontLoadFailed;
        }

        const char_width = @as(u32, @intCast(font.*.max_advance_width));
        const char_height = @as(u32, @intCast(font.*.height));
        const ascent = font.*.ascent;
        const descent = font.*.descent;

        // Update window metrics
        window.cell_width = char_width;
        window.cell_height = char_height;

        return Renderer{
            .window = window,
            .allocator = allocator,
            .draw = draw.?,
            .font = font.?,
            .char_width = char_width,
            .char_height = char_height,
            .ascent = ascent,
            .descent = descent,
            .colors = undefined,
            .loaded_colors = [_]bool{false} ** 260,
        };
    }

    pub fn deinit(self: *Renderer) void {
        x11.XftDrawDestroy(self.draw);
        x11.XftFontClose(self.window.dpy, self.font);
        // Free colors...
    }

    fn getColor(self: *Renderer, index: u32) !*x11.XftColor {
        if (index >= 260) return error.ColorAllocFailed;

        if (self.loaded_colors[index]) {
            return &self.colors[index];
        }

        // Allocate color
        // Map index to RGB
        const rgb = self.getIndexColor(index);
        const render_color = x11.XRenderColor{
            .red = @as(u16, rgb[0]) * 257,
            .green = @as(u16, rgb[1]) * 257,
            .blue = @as(u16, rgb[2]) * 257,
            .alpha = 0xFFFF,
        };

        if (x11.XftColorAllocValue(self.window.dpy, self.window.vis, self.window.cmap, &render_color, &self.colors[index]) == 0) {
            return error.ColorAllocFailed;
        }

        self.loaded_colors[index] = true;
        return &self.colors[index];
    }

    fn getIndexColor(self: *Renderer, index: u32) [3]u8 {
        _ = self;
        // TODO: Use the logic from previous renderer to map index to RGB
        if (index < 8) return u32ToRgb(config.Config.colors.normal[index]); // Note: Config colors are u32 0xRRGGBB
        if (index < 16) return u32ToRgb(config.Config.colors.bright[index - 8]);
        if (index == 256) return u32ToRgb(config.Config.colors.cursor);
        if (index == 258) return u32ToRgb(config.Config.colors.foreground);
        if (index == 259) return u32ToRgb(config.Config.colors.background);

        // Default white
        return .{ 0xFF, 0xFF, 0xFF };
    }

    pub fn render(self: *Renderer, term: *Term) !void {
        // Clear buffer
        const bg = try self.getColor(259); // Background
        x11.XftDrawRect(self.draw, bg, 0, 0, @intCast(self.window.width), @intCast(self.window.height));

        const screen = if (term.mode.alt_screen) term.alt else term.line;
        if (screen == null) return;

        for (0..@min(term.row, screen.?.len)) |y| {
            for (0..@min(term.col, screen.?[y].len)) |x| {
                const glyph = screen.?[y][x];

                const x_pos = @as(i32, @intCast(x * self.char_width));
                const y_pos = @as(i32, @intCast(y * self.char_height));

                // Draw background if not default
                if (glyph.bg != 259) { // Optimization
                    const bg_col = try self.getColor(glyph.bg);
                    x11.XftDrawRect(self.draw, bg_col, x_pos, y_pos, @intCast(self.char_width), @intCast(self.char_height));
                }

                if (glyph.u != ' ' and glyph.u != 0) {
                    const fg = try self.getColor(glyph.fg);
                    // XftDrawString32 expects u32* (FcChar32*)
                    const char = @as(u32, glyph.u);
                    x11.XftDrawString32(self.draw, fg, self.font, x_pos, y_pos + self.ascent, &char, 1);
                }
            }
        }
    }

    pub fn renderCursor(self: *Renderer, term: *Term) !void {
        const cx = term.c.x;
        const cy = term.c.y;

        const x_pos = @as(i32, @intCast(cx * self.char_width));
        const y_pos = @as(i32, @intCast(cy * self.char_height));

        // Draw cursor rect
        const cursor_col = try self.getColor(256);
        x11.XftDrawRect(self.draw, cursor_col, x_pos, y_pos, @intCast(self.char_width), @intCast(self.char_height));

        // Draw character under cursor (inverted)
        // ... implementation details omitted for brevity
    }
};

fn u32ToRgb(color: u32) [3]u8 {
    return .{
        @truncate((color >> 16) & 0xFF),
        @truncate((color >> 8) & 0xFF),
        @truncate(color & 0xFF),
    };
}
