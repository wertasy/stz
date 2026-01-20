//! 字符渲染系统
//! 负责将终端字符渲染到 SDL2 窗口

const std = @import("std");
const sdl = @import("sdl.zig");
const ft = @import("ft.zig");
const types = @import("types.zig");
const config = @import("config.zig");

const Glyph = types.Glyph;
const Term = types.Term;
const Window = @import("window.zig").Window;

pub const RendererError = error{
    CreateTextureFailed,
    RenderFailed,
    FontInitFailed,
    FontLoadFailed,
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

const CacheKey = struct {
    u: u21,
    bold: bool,
    italic: bool,
};

/// 渲染器结构
pub const Renderer = struct {
    window: *Window,
    allocator: std.mem.Allocator,

    // 字体纹理缓存
    font_texture: ?*sdl.SDL_Texture = null,
    char_width: u32 = 0,
    char_height: u32 = 0,

    ft_lib: ft.FT_Library = null,
    ft_face: ft.FT_Face = null,
    glyph_cache: std.AutoHashMap(CacheKey, *sdl.SDL_Texture),

    /// 初始化渲染器
    pub fn init(window: *Window, allocator: std.mem.Allocator) !Renderer {
        var renderer = Renderer{
            .window = window,
            .allocator = allocator,
            .char_width = window.cell_width,
            .char_height = window.cell_height,
            .glyph_cache = std.AutoHashMap(CacheKey, *sdl.SDL_Texture).init(allocator),
        };

        // 初始化 FreeType
        if (ft.FT_Init_FreeType(&renderer.ft_lib) != 0) {
            return error.FontInitFailed;
        }

        // 加载字体
        // 简单起见，这里先硬编码一个路径，实际应该用 FontConfig
        const font_path = "/usr/share/fonts/dejavu/DejaVuSansMono.ttf";
        if (ft.FT_New_Face(renderer.ft_lib, font_path, 0, &renderer.ft_face) != 0) {
            // 尝试备用字体
            if (ft.FT_New_Face(renderer.ft_lib, "/usr/share/fonts/liberation-mono/LiberationMono-Regular.ttf", 0, &renderer.ft_face) != 0) {
                std.log.err("Failed to load font: {s}\n", .{font_path});
                return error.FontLoadFailed;
            }
        }

        // 设置字体大小
        _ = ft.FT_Set_Pixel_Sizes(renderer.ft_face, 0, @intCast(config.Config.font.size));

        return renderer;
    }

    /// 清理渲染器
    pub fn deinit(self: *Renderer) void {
        var it = self.glyph_cache.iterator();
        while (it.next()) |entry| {
            sdl.SDL_DestroyTexture(entry.value_ptr.*);
        }
        self.glyph_cache.deinit();

        _ = ft.FT_Done_Face(self.ft_face);
        _ = ft.FT_Done_FreeType(self.ft_lib);

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
            // 暂时禁用 dirty 检查，强制重绘，以修复黑屏问题
            // if (term.dirty) |dirty| {
            //     if (y >= dirty.len or !dirty[y]) continue;
            // }

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

    /// 获取或创建字形纹理
    fn getGlyphTexture(self: *Renderer, u: u21, bold: bool, italic: bool) !?*sdl.SDL_Texture {
        const key = CacheKey{ .u = u, .bold = bold, .italic = italic };
        if (self.glyph_cache.get(key)) |tex| {
            return tex;
        }

        // 获取字符索引
        const index = ft.FT_Get_Char_Index(self.ft_face, u);

        // 加载字形
        // TODO: 处理粗体和斜体 (FT_Outline_Embolden / FT_Matrix)
        if (ft.FT_Load_Glyph(self.ft_face, index, ft.FT_LOAD_RENDER) != 0) {
            return null;
        }

        const bitmap = ft.getBitmap(self.ft_face);

        if (bitmap.width == 0 or bitmap.rows == 0) {
            return null;
        }

        // 创建临时缓冲区 (ARGB8888)
        const width = bitmap.width;
        const height = bitmap.rows;
        const size = width * height * 4;
        const buffer = try self.allocator.alloc(u8, size);
        defer self.allocator.free(buffer);

        // 转换位图 (Grayscale -> ARGB)
        for (0..height) |r| {
            for (0..width) |c_idx| {
                const src_idx = r * @as(usize, @intCast(bitmap.pitch)) + c_idx;
                const dst_idx = (r * width + c_idx) * 4;
                const alpha = bitmap.buffer[src_idx];

                buffer[dst_idx + 0] = 255; // B
                buffer[dst_idx + 1] = 255; // G
                buffer[dst_idx + 2] = 255; // R
                buffer[dst_idx + 3] = alpha; // A
            }
        }

        // 创建表面
        // rmask, gmask, bmask, amask for ARGB8888 (Little Endian: B G R A)
        // Buffer layout: Byte 0 = B, Byte 1 = G, Byte 2 = R, Byte 3 = A
        // Little Endian u32: 0xAARRGGBB
        const surface = sdl.SDL_CreateRGBSurfaceFrom(
            buffer.ptr,
            @intCast(width),
            @intCast(height),
            32,
            @intCast(width * 4),
            0x00FF0000, // R mask (Byte 2)
            0x0000FF00, // G mask (Byte 1)
            0x000000FF, // B mask (Byte 0)
            0xFF000000, // A mask (Byte 3)
        );
        if (surface == null) return error.CreateTextureFailed;
        defer sdl.SDL_FreeSurface(surface);

        // 创建纹理
        const texture = sdl.SDL_CreateTextureFromSurface(self.window.renderer, surface) orelse return error.CreateTextureFailed;

        // 设置混合模式
        _ = sdl.SDL_SetTextureBlendMode(texture, sdl.SDL_BLENDMODE_BLEND);

        // 缓存纹理
        try self.glyph_cache.put(key, texture);

        return texture;
    }

    /// 绘制单元格背景
    fn drawCellBg(self: *Renderer, x: i32, y: i32, rgb: [3]u8) !void {
        const renderer = self.window.renderer;

        const rect = sdl.SDL_Rect{
            .x = x,
            .y = y,
            .w = @intCast(self.char_width),
            .h = @intCast(self.char_height),
        };

        _ = sdl.SDL_SetRenderDrawColor(renderer, rgb[0], rgb[1], rgb[2], 255);
        _ = sdl.SDL_RenderFillRect(renderer, &rect);
    }

    /// 绘制字符
    fn drawGlyph(self: *Renderer, x: i32, y: i32, glyph: Glyph, rgb: [3]u8) !void {
        const renderer = self.window.renderer;

        // 获取字形纹理
        const tex_opt = try self.getGlyphTexture(glyph.u, glyph.attr.bold, glyph.attr.italic);
        if (tex_opt) |texture| {
            _ = sdl.SDL_SetTextureColorMod(texture, rgb[0], rgb[1], rgb[2]);

            var w: c_int = 0;
            var h: c_int = 0;
            _ = sdl.SDL_QueryTexture(texture, null, null, &w, &h);

            const cell_w = @as(c_int, @intCast(self.char_width));
            const cell_h = @as(c_int, @intCast(self.char_height));

            // 垂直居中
            const dst_x = x + @divTrunc(cell_w - w, 2);
            const dst_y = y + @divTrunc(cell_h - h, 2);

            const dst = sdl.SDL_Rect{
                .x = dst_x,
                .y = dst_y,
                .w = w,
                .h = h,
            };

            _ = sdl.SDL_RenderCopy(renderer, texture, null, &dst);
        }

        _ = sdl.SDL_SetRenderDrawColor(renderer, rgb[0], rgb[1], rgb[2], 255);

        if (glyph.attr.underline) {
            // 下划线
            const char_h: i32 = @intCast(self.char_height);
            const underline_y = y + char_h - 2;
            const underline_rect = sdl.SDL_Rect{
                .x = x,
                .y = underline_y,
                .w = @intCast(self.char_width),
                .h = 1,
            };
            _ = sdl.SDL_RenderFillRect(renderer, &underline_rect);
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
                _ = sdl.SDL_SetRenderDrawColor(self.window.renderer, cursor_color[0], cursor_color[1], cursor_color[2], 255);
                _ = sdl.SDL_RenderFillRect(self.window.renderer, &rect);
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
                _ = sdl.SDL_SetRenderDrawColor(self.window.renderer, cursor_color[0], cursor_color[1], cursor_color[2], 255);
                _ = sdl.SDL_RenderFillRect(self.window.renderer, &rect);
            },
            5, 6 => { // 闪烁竖线/稳定竖线
                const bar_width: i32 = @intCast(config.Config.cursor.thickness);
                const rect = sdl.SDL_Rect{
                    .x = x,
                    .y = y,
                    .w = bar_width,
                    .h = @intCast(self.char_height),
                };
                _ = sdl.SDL_SetRenderDrawColor(self.window.renderer, cursor_color[0], cursor_color[1], cursor_color[2], 255);
                _ = sdl.SDL_RenderFillRect(self.window.renderer, &rect);
            },
            else => {},
        }
    }
};
