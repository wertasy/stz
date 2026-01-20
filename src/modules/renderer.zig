//! 字符渲染系统
//! 负责将终端字符渲染到 SDL2 窗口

const std = @import("std");
const sdl = @import("sdl.zig");
const types = @import("types.zig");
const config = @import("config.zig");

const Glyph = types.Glyph;
const Term = types.Term;
const Window = @import("window.zig").Window;

pub const RendererError = error{
    CreateTextureFailed,
    RenderFailed,
};

/// 颜色映射表
const ColorTable = struct {
    /// 将颜色索引转换为 RGB
    pub fn getIndexColor(index: u32) [3]u8 {
        if (index <= 7) {
            // 标准颜色
            return colorToRgb(config.Config.colors.normal[index]);
        } else if (index <= 15) {
            // 高亮颜色
            return colorToRgb(config.Config.colors.bright[index - 8]);
        } else if (index == 256) {
            return colorToRgb(config.Config.colors.cursor);
        } else if (index == 258) {
            return colorToRgb(config.Config.colors.foreground);
        } else if (index == 259) {
            return colorToRgb(config.Config.colors.background);
        } else if (index >= 16 and index <= 255) {
            // 256 色模式 - 简化实现
            const c = index - 16;
            const r = (c / 36) * 51;
            const g = ((c % 36) / 6) * 51;
            const b = (c % 6) * 51;
            return .{
                @truncate(r),
                @truncate(g),
                @truncate(b),
            };
        } else if (index & 0x1000000 != 0) {
            // 真彩色模式
            return .{
                @truncate((index >> 16) & 0xFF),
                @truncate((index >> 8) & 0xFF),
                @truncate(index & 0xFF),
            };
        } else {
            // 默认
            return colorToRgb(config.Config.colors.foreground);
        }
    }

    /// 将 24位颜色转换为 RGB 数组
    fn colorToRgb(color: u32) [3]u8 {
        return .{
            @truncate((color >> 16) & 0xFF),
            @truncate((color >> 8) & 0xFF),
            @truncate(color & 0xFF),
        };
    }
};

/// 渲染器结构
pub const Renderer = struct {
    window: *Window,
    allocator: std.mem.Allocator,

    // 字体纹理缓存
    font_texture: ?*sdl.SDL_Texture = null,
    char_width: u32 = 0,
    char_height: u32 = 0,

    /// 初始化渲染器
    pub fn init(window: *Window, allocator: std.mem.Allocator) !Renderer {
        return Renderer{
            .window = window,
            .allocator = allocator,
            .char_width = window.cell_width,
            .char_height = window.cell_height,
        };
    }

    /// 清理渲染器
    pub fn deinit(self: *Renderer) void {
        if (self.font_texture) |tex| {
            sdl.SDL_DestroyTexture(tex);
        }
    }

    /// 渲染整个终端
    pub fn render(self: *Renderer, term: *Term) !void {
        // 清屏
        self.window.clear();

        const screen = if (term.mode.alt_screen) term.alt else term.line;
        if (screen == null) return;

        // 渲染每个字符
        for (0..@min(term.row, screen.?.len)) |y| {
            if (term.dirty) |dirty| {
                if (y >= dirty.len or !dirty[y]) continue;
            }

            for (0..@min(term.col, screen.?[y].len)) |x| {
                const glyph = screen.?[y][x];
                const screen_x: i32 = @intCast(x * self.char_width);
                const screen_y: i32 = @intCast(y * self.char_height);

                // 获取前景色和背景色
                const fg_rgb = ColorTable.getIndexColor(glyph.fg);
                const bg_rgb = ColorTable.getIndexColor(glyph.bg);

                // 绘制背景
                try self.drawCellBg(screen_x, screen_y, bg_rgb);

                // 绘制字符
                if (glyph.u != ' ' and !glyph.attr.hidden) {
                    try self.drawGlyph(screen_x, screen_y, glyph, fg_rgb);
                }
            }
        }
    }

    /// 绘制单元格背景
    fn drawCellBg(self: *Renderer, x: i32, y: i32, rgb: [3]u8) !void {
        const renderer = self.window.renderer orelse return;

        const rect = sdl.SDL_Rect{
            .x = x,
            .y = y,
            .w = @intCast(self.char_width),
            .h = @intCast(self.char_height),
        };

        _ = sdl.SDL_SetRenderDrawColor(renderer, rgb[0], rgb[1], rgb[2], 255);
        _ = sdl.SDL_RenderFillRect(renderer, &rect);
    }

    /// 绘制字符（简化版本 - 需要字体支持）
    fn drawGlyph(self: *Renderer, x: i32, y: i32, glyph: Glyph, rgb: [3]u8) !void {
        const renderer = self.window.renderer orelse return;

        _ = sdl.SDL_SetRenderDrawColor(renderer, rgb[0], rgb[1], rgb[2], 255);

        const char_w: i32 = @intCast(self.char_width);
        const char_h: i32 = @intCast(self.char_height);

        // 根据属性调整渲染
        if (glyph.attr.bold) {
            // 粗体：绘制稍大的矩形
            const bold_rect = sdl.SDL_Rect{
                .x = x - 1,
                .y = y - 1,
                .w = char_w + 2,
                .h = char_h + 2,
            };
            _ = sdl.SDL_RenderFillRect(renderer, &bold_rect);
        }

        if (glyph.attr.underline) {
            // 下划线
            const underline_y = y + char_h - 3;
            const underline_rect = sdl.SDL_Rect{
                .x = x,
                .y = underline_y,
                .w = char_w,
                .h = 3,
            };
            _ = sdl.SDL_RenderFillRect(renderer, &underline_rect);
        }

        // 绘制字符主体
        const char_rect = sdl.SDL_Rect{
            .x = x + 2,
            .y = y + 2,
            .w = char_w - 4,
            .h = char_h - 4,
        };
        _ = sdl.SDL_RenderFillRect(renderer, &char_rect);

        // 反色模式
        if (glyph.attr.reverse) {
            // 反色：交换前景和背景
            const rev_rect = sdl.SDL_Rect{
                .x = x,
                .y = y,
                .w = char_w,
                .h = char_h,
            };
            const rev_rgb = ColorTable.getIndexColor(glyph.bg);
            _ = sdl.SDL_SetRenderDrawColor(renderer, rev_rgb[0], rev_rgb[1], rev_rgb[2], 255);
            _ = sdl.SDL_RenderFillRect(renderer, &rev_rect);
        }
    }

    /// 渲染光标
    pub fn renderCursor(self: *Renderer, term: *Term) !void {
        const screen = if (term.mode.alt_screen) term.alt else term.line;
        if (screen == null) return;

        const x: i32 = @intCast(term.c.x * self.char_width);
        const y: i32 = @intCast(term.c.y * self.char_height);

        const cursor_color = ColorTable.getIndexColor(config.Config.colors.cursor);

        // 根据光标样式渲染
        switch (config.Config.cursor.style) {
            0, 1 => { // 闪烁块/稳定块
                const rect = sdl.SDL_Rect{
                    .x = x,
                    .y = y,
                    .w = @intCast(self.char_width),
                    .h = @intCast(self.char_height),
                };
                _ = sdl.SDL_SetRenderDrawColor(self.window.renderer.?, cursor_color[0], cursor_color[1], cursor_color[2], 255);
                _ = sdl.SDL_RenderFillRect(self.window.renderer.?, &rect);
            },
            3, 4 => { // 闪烁下划线/稳定下划线
                const char_h: i32 = @intCast(self.char_height);
                const underline_y = y + char_h - 3;
                const rect = sdl.SDL_Rect{
                    .x = x,
                    .y = underline_y,
                    .w = @intCast(self.char_width),
                    .h = 3,
                };
                _ = sdl.SDL_SetRenderDrawColor(self.window.renderer.?, cursor_color[0], cursor_color[1], cursor_color[2], 255);
                _ = sdl.SDL_RenderFillRect(self.window.renderer.?, &rect);
            },
            5, 6 => { // 闪烁竖线/稳定竖线
                const bar_width: i32 = @intCast(config.Config.cursor.cursorthickness);
                const rect = sdl.SDL_Rect{
                    .x = x,
                    .y = y,
                    .w = bar_width,
                    .h = @intCast(self.char_height),
                };
                _ = sdl.SDL_SetRenderDrawColor(self.window.renderer.?, cursor_color[0], cursor_color[1], cursor_color[2], 255);
                _ = sdl.SDL_RenderFillRect(self.window.renderer.?, &rect);
            },
            5, 6 => { // 闪烁竖线/稳定竖线
                const bar_width: i32 = @intCast(config.Config.cursor.cursorthickness);
                const rect = sdl.SDL_Rect{
                    .x = x,
                    .y = y,
                    .w = bar_width,
                    .h = @intCast(self.char_height),
                };
                _ = sdl.SDL_SetRenderDrawColor(self.window.renderer.?, cursor_color[0], cursor_color[1], cursor_color[2], 255);
                _ = sdl.SDL_RenderFillRect(self.window.renderer.?, &rect);
            },
            else => {},
        }
    }
};
