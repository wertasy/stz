//! 字符渲染系统 (Xft 实现)
//!
//! 渲染器负责将终端屏幕缓冲区中的字符绘制到 X11 窗口上。
//!
//! 核心功能：
//! - 字体加载和管理：主字体、斜体、粗体、斜体粗体、回退字体
//! - 字符宽度计算：计算字符的单元格宽度（1列或2列）
//! - 颜色管理：加载和缓存颜色（256色、真彩色）
//! - 字符绘制：使用 Xft 绘制字符到 Pixmap
//! - 光标渲染：绘制光标（块状、下划线、竖线等）
//! - 双缓冲：先渲染到 Pixmap，然后一次性显示到窗口
//!
//! 渲染流程：
//! 1. 检查脏标记，只重新渲染变化的行
//! 2. 对每个脏行，遍历所有字符
//! 3. 检查字符属性（前景色、背景色、粗体、斜体等）
//! 4. 加载对应的字体（主字体/粗体/斜体）
//! 5. 绘制字符背景矩形
//! 6. 绘制字符本身（使用 XftDrawString32）
//! 7. 特殊处理：制表符使用内置绘制逻辑
//!
//! 字体回退机制：
//! - 如果主字体不支持某个字符（如中文），遍历回退字体列表
//! - 如果所有字体都不支持，使用默认字符（通常是方框）
//! - 回退字体列表可以在配置中指定
//!
//! 颜色缓存：
//! - 预加载 256 种标准颜色和 4 种特殊颜色
//! - 使用 XftColorAllocName 分配颜色
//! - 使用 truecolor_cache 缓存真彩色 (RGB)
//!
//! 双缓冲机制：
//! - Pixmap: 离屏缓冲区，所有绘图操作都在 Pixmap 上完成
//! - XCopyArea: 最后一次性将 Pixmap 复制到窗口
//! - 优点：避免闪烁、提高性能
//!
//! 光标渲染：
//! - 光标样式：块状、下划线、竖线、空心框等
//! - 闪烁：周期性显示/隐藏光标（可配置）
//! - 反色：在光标位置交换前景色和背景色
//!
//! 性能优化：
//! - 只渲染脏行（dirty 标记）
//! - 颜色缓存避免重复分配
//! - 字体缓存避免重复加载
//! - 批量渲染减少 X11 调用

const std = @import("std");
const x11 = @import("x11.zig");
const types = @import("types.zig");
const config = @import("config.zig");
const selection = @import("selection.zig");
const boxdraw = @import("boxdraw.zig");
const boxdraw_data = @import("boxdraw_data.zig");
const screen_mod = @import("screen.zig");
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
    draw: *x11.c.XftDraw,
    font: *x11.c.XftFont,
    font_italic: *x11.c.XftFont,
    font_bold: *x11.c.XftFont,
    font_italic_bold: *x11.c.XftFont,
    fallbacks: std.ArrayList(*x11.c.XftFont),

    char_width: u32,
    char_height: u32,
    ascent: i32,
    descent: i32,

    current_font_size: u32,
    original_font_size: u32,

    // Cursor blink state
    cursor_blink_state: bool = true,
    last_blink_time: i64 = 0,

    // Color cache (256 indexed + 4 special + some margin)
    colors: [300]x11.c.XftColor,
    loaded_colors: [300]bool,
    truecolor_cache: std.AutoArrayHashMap(u32, x11.c.XftColor),

    pub fn init(window: *Window, allocator: std.mem.Allocator) !Renderer {
        // Initialize buffer in window if not already
        window.resizeBuffer(window.width, window.height);

        const draw = x11.c.XftDrawCreate(window.dpy, window.buf, window.vis, window.cmap);
        if (draw == null) return error.XftDrawCreateFailed;

        // Load font
        var font_name: [:0]const u8 = config.Config.font.name; // e.g., "Monospace:size=12"

        // Try loading configured font

        var font = x11.c.XftFontOpenName(window.dpy, window.screen, font_name);

        if (font == null) {
            std.log.warn("Failed to load configured font: {s}, trying default 'Monospace:pixelsize=14'\n", .{font_name});
            font_name = "Monospace:pixelsize=14";
            font = x11.c.XftFontOpenName(window.dpy, window.screen, font_name);
        }

        if (font == null) {
            std.log.warn("Failed to load default font, trying backup 'fixed'\n", .{});
            font = x11.c.XftFontOpenName(window.dpy, window.screen, "fixed");
            if (font == null) return error.FontLoadFailed;
        }

        // Calculate average character width from ASCII printable characters
        var width_sum: u32 = 0;
        var count: u32 = 0;
        var ascii_char: u8 = ' ';
        while (ascii_char <= '~') : (ascii_char += 1) {
            if (x11.c.XftCharExists(window.dpy, font, ascii_char) != 0) {
                var extents: x11.c.XGlyphInfo = undefined;
                x11.c.XftTextExtents32(window.dpy, font, &@as(u32, ascii_char), 1, &extents);
                width_sum += @intCast(extents.xOff);
                count += 1;
            }
        }

        const avg_width = if (count > 0) @as(f32, @floatFromInt(width_sum)) / @as(f32, @floatFromInt(count)) else @as(f32, @floatFromInt(font.*.max_advance_width));
        const char_width = @as(u32, @intFromFloat(@ceil(avg_width * config.Config.font.cwscale)));
        const char_height = @as(u32, @intFromFloat(@ceil(@as(f32, @floatFromInt(font.*.ascent + font.*.descent)) * config.Config.font.chscale)));
        const ascent = font.*.ascent;
        const descent = font.*.descent;

        // Load font variants
        const pattern = x11.c.FcPatternDuplicate(font.*.pattern);

        // Italic
        const italic_pattern = x11.c.FcPatternDuplicate(pattern);
        _ = x11.c.FcPatternDel(italic_pattern, x11.c.FC_SLANT);
        _ = x11.c.FcPatternAddInteger(italic_pattern, x11.c.FC_SLANT, x11.c.FC_SLANT_ITALIC);
        var font_italic = x11.c.XftFontOpenPattern(window.dpy, italic_pattern);
        if (font_italic == null) font_italic = font;

        // Bold
        const bold_pattern = x11.c.FcPatternDuplicate(pattern);
        _ = x11.c.FcPatternDel(bold_pattern, x11.c.FC_WEIGHT);
        _ = x11.c.FcPatternAddInteger(bold_pattern, x11.c.FC_WEIGHT, x11.c.FC_WEIGHT_BOLD);
        var font_bold = x11.c.XftFontOpenPattern(window.dpy, bold_pattern);
        if (font_bold == null) font_bold = font;

        // Italic Bold
        const ib_pattern = x11.c.FcPatternDuplicate(pattern);
        _ = x11.c.FcPatternDel(ib_pattern, x11.c.FC_SLANT);
        _ = x11.c.FcPatternAddInteger(ib_pattern, x11.c.FC_SLANT, x11.c.FC_SLANT_ITALIC);
        _ = x11.c.FcPatternDel(ib_pattern, x11.c.FC_WEIGHT);
        _ = x11.c.FcPatternAddInteger(ib_pattern, x11.c.FC_WEIGHT, x11.c.FC_WEIGHT_BOLD);
        var font_italic_bold = x11.c.XftFontOpenPattern(window.dpy, ib_pattern);
        if (font_italic_bold == null) font_italic_bold = font;

        x11.c.FcPatternDestroy(pattern);

        // Update window metrics
        window.cell_width = char_width;
        window.cell_height = char_height;

        var fallbacks = try std.ArrayList(*x11.c.XftFont).initCapacity(allocator, 4);
        errdefer {
            for (fallbacks.items) |f| x11.c.XftFontClose(window.dpy, f);
            fallbacks.deinit(allocator);
        }

        // 加载常见备用字体 (CJK, Emoji, Symbols)
        const fallback_names = [_][:0]const u8{
            "DejaVu Sans Mono:pixelsize=20",
            "Noto Sans Mono CJK SC:pixelsize=20",
            "WenQuanYi Micro Hei:pixelsize=20",
            "Noto Color Emoji:pixelsize=20",
            "Symbola:pixelsize=20",
        };

        for (fallback_names) |name| {
            if (x11.c.XftFontOpenName(window.dpy, window.screen, name)) |f| {
                try fallbacks.append(allocator, f);
            }
        }

        return Renderer{
            .window = window,
            .allocator = allocator,
            .draw = draw.?,
            .font = font.?,
            .font_italic = font_italic.?,
            .font_bold = font_bold.?,
            .font_italic_bold = font_italic_bold.?,
            .fallbacks = fallbacks,
            .char_width = char_width,
            .char_height = char_height,
            .ascent = ascent,
            .descent = descent,
            .current_font_size = config.Config.font.size,
            .original_font_size = config.Config.font.size,
            .cursor_blink_state = true,
            .last_blink_time = std.time.milliTimestamp(),
            .colors = undefined,
            .loaded_colors = [_]bool{false} ** 300,
            .truecolor_cache = std.AutoArrayHashMap(u32, x11.c.XftColor).init(allocator),
        };
    }

    pub fn zoom(self: *Renderer, zoom_in: bool) !void {
        const step: u32 = 1;
        var new_size = self.current_font_size;

        if (zoom_in) {
            new_size += step;
        } else {
            if (new_size > 1) new_size -= step;
        }

        if (new_size == self.current_font_size) return;

        // Reload font with new size
        try self.reloadFont(new_size);
    }

    pub fn resetZoom(self: *Renderer) !void {
        if (self.current_font_size == self.original_font_size) return;
        try self.reloadFont(self.original_font_size);
    }

    fn reloadFont(self: *Renderer, size: u32) !void {
        // Construct new font name with size
        // We need to parse base name from config or store it.
        // Simplified: assumes config.font.name format "Name:pixelsize=..."
        // Ideally we should use FcPattern to modify size.

        const pattern = x11.c.FcPatternDuplicate(self.font.*.pattern);
        defer x11.c.FcPatternDestroy(pattern);

        // Remove existing size
        _ = x11.c.FcPatternDel(pattern, x11.c.FC_PIXEL_SIZE);
        _ = x11.c.FcPatternDel(pattern, x11.c.FC_SIZE);

        // Add new size
        _ = x11.c.FcPatternAddInteger(pattern, x11.c.FC_PIXEL_SIZE, @intCast(size));

        const new_font = x11.c.XftFontOpenPattern(self.window.dpy, pattern);
        if (new_font == null) return; // Failed to load

        // Update successful, close old fonts and replace
        x11.c.XftFontClose(self.window.dpy, self.font);
        if (self.font_italic != self.font) x11.c.XftFontClose(self.window.dpy, self.font_italic);
        if (self.font_bold != self.font) x11.c.XftFontClose(self.window.dpy, self.font_bold);
        if (self.font_italic_bold != self.font) x11.c.XftFontClose(self.window.dpy, self.font_italic_bold);

        self.font = new_font.?;
        self.current_font_size = size;

        // Reload variants
        // Italic
        const italic_pattern = x11.c.FcPatternDuplicate(pattern);
        _ = x11.c.FcPatternDel(italic_pattern, x11.c.FC_SLANT);
        _ = x11.c.FcPatternAddInteger(italic_pattern, x11.c.FC_SLANT, x11.c.FC_SLANT_ITALIC);
        var font_italic = x11.c.XftFontOpenPattern(self.window.dpy, italic_pattern);
        if (font_italic == null) font_italic = self.font;
        self.font_italic = font_italic.?;

        // Bold
        const bold_pattern = x11.c.FcPatternDuplicate(pattern);
        _ = x11.c.FcPatternDel(bold_pattern, x11.c.FC_WEIGHT);
        _ = x11.c.FcPatternAddInteger(bold_pattern, x11.c.FC_WEIGHT, x11.c.FC_WEIGHT_BOLD);
        var font_bold = x11.c.XftFontOpenPattern(self.window.dpy, bold_pattern);
        if (font_bold == null) font_bold = self.font;
        self.font_bold = font_bold.?;

        // Italic Bold
        const ib_pattern = x11.c.FcPatternDuplicate(pattern);
        _ = x11.c.FcPatternDel(ib_pattern, x11.c.FC_SLANT);
        _ = x11.c.FcPatternAddInteger(ib_pattern, x11.c.FC_SLANT, x11.c.FC_SLANT_ITALIC);
        _ = x11.c.FcPatternDel(ib_pattern, x11.c.FC_WEIGHT);
        _ = x11.c.FcPatternAddInteger(ib_pattern, x11.c.FC_WEIGHT, x11.c.FC_WEIGHT_BOLD);
        var font_italic_bold = x11.c.XftFontOpenPattern(self.window.dpy, ib_pattern);
        if (font_italic_bold == null) font_italic_bold = self.font;
        self.font_italic_bold = font_italic_bold.?;

        // Recalculate metrics
        var width_sum: u32 = 0;
        var count: u32 = 0;
        var ascii_char: u8 = ' ';
        while (ascii_char <= '~') : (ascii_char += 1) {
            if (x11.c.XftCharExists(self.window.dpy, self.font, ascii_char) != 0) {
                var extents: x11.c.XGlyphInfo = undefined;
                x11.c.XftTextExtents32(self.window.dpy, self.font, &@as(u32, ascii_char), 1, &extents);
                width_sum += @intCast(extents.xOff);
                count += 1;
            }
        }

        const avg_width = if (count > 0) @as(f32, @floatFromInt(width_sum)) / @as(f32, @floatFromInt(count)) else @as(f32, @floatFromInt(self.font.*.max_advance_width));
        self.char_width = @as(u32, @intFromFloat(@ceil(avg_width * config.Config.font.cwscale)));
        self.char_height = @as(u32, @intFromFloat(@ceil(@as(f32, @floatFromInt(self.font.*.ascent + self.font.*.descent)) * config.Config.font.chscale)));
        self.ascent = self.font.*.ascent;
        self.descent = self.font.*.descent;

        // Update window metrics
        self.window.cell_width = self.char_width;
        self.window.cell_height = self.char_height;
    }

    pub fn deinit(self: *Renderer) void {
        x11.c.XftDrawDestroy(self.draw);
        if (self.font_italic != self.font) x11.c.XftFontClose(self.window.dpy, self.font_italic);
        if (self.font_bold != self.font) x11.c.XftFontClose(self.window.dpy, self.font_bold);
        if (self.font_italic_bold != self.font) x11.c.XftFontClose(self.window.dpy, self.font_italic_bold);
        x11.c.XftFontClose(self.window.dpy, self.font);
        for (self.fallbacks.items) |f| {
            x11.c.XftFontClose(self.window.dpy, f);
        }
        self.fallbacks.deinit(self.allocator);
        // Free indexed colors
        for (0..300) |i| {
            if (self.loaded_colors[i]) {
                x11.c.XftColorFree(self.window.dpy, self.window.vis, self.window.cmap, &self.colors[i]);
            }
        }
        // Free truecolors
        var it = self.truecolor_cache.iterator();
        while (it.next()) |entry| {
            x11.c.XftColorFree(self.window.dpy, self.window.vis, self.window.cmap, entry.value_ptr);
        }
        self.truecolor_cache.deinit();
    }

    fn getColor(self: *Renderer, term: *Term, index: u32) !x11.c.XftColor {
        // 24位真彩色使用缓存
        if (index >= 0x10000000) {
            if (self.truecolor_cache.get(index)) |color| {
                return color;
            }

            // 限制缓存大小，防止内存溢出
            if (self.truecolor_cache.count() > 128) {
                // 简单的 FIFO 清理
                const first_key = self.truecolor_cache.keys()[0];
                var entry = self.truecolor_cache.fetchOrderedRemove(first_key).?;
                x11.c.XftColorFree(self.window.dpy, self.window.vis, self.window.cmap, &entry.value);
            }

            var temp_color: x11.c.XftColor = undefined;
            const rgb = self.getIndexColor(term, index);
            const render_color = x11.c.XRenderColor{
                .red = @as(u16, rgb[0]) * 257,
                .green = @as(u16, rgb[1]) * 257,
                .blue = @as(u16, rgb[2]) * 257,
                .alpha = 0xFFFF,
            };
            if (x11.c.XftColorAllocValue(self.window.dpy, self.window.vis, self.window.cmap, &render_color, &temp_color) == 0) {
                return error.ColorAllocFailed;
            }
            try self.truecolor_cache.put(index, temp_color);
            return temp_color;
        }

        if (index >= 300) return error.ColorAllocFailed;

        if (self.loaded_colors[index]) {
            return self.colors[index];
        }

        // Allocate color
        // Map index to RGB
        const rgb = self.getIndexColor(term, index);
        const render_color = x11.c.XRenderColor{
            .red = @as(u16, rgb[0]) * 257,
            .green = @as(u16, rgb[1]) * 257,
            .blue = @as(u16, rgb[2]) * 257,
            .alpha = 0xFFFF,
        };

        if (x11.c.XftColorAllocValue(self.window.dpy, self.window.vis, self.window.cmap, &render_color, &self.colors[index]) == 0) {
            return error.ColorAllocFailed;
        }

        self.loaded_colors[index] = true;
        return self.colors[index];
    }

    fn getIndexColor(self: *Renderer, term: *Term, index: u32) [3]u8 {
        _ = self;

        // 24 位真彩色 (0xFFRRGGBB 格式)
        if (index >= 0x10000000) {
            const r = @as(u8, @truncate((index >> 16) & 0xFF));
            const g = @as(u8, @truncate((index >> 8) & 0xFF));
            const b = @as(u8, @truncate(index & 0xFF));
            return .{ r, g, b };
        }

        // 标准颜色 (0-7)
        if (index < 8) return u32ToRgb(config.Config.colors.normal[index]); // Note: Config colors are u32 0xRRGGBB
        // 明亮颜色 (8-15)
        if (index < 16) return u32ToRgb(config.Config.colors.bright[index - 8]);
        // 256 色扩展 (16-255)
        if (index < 256) {
            // 从调色板读取 RGB 值
            return u32ToRgb(term.palette[index]);
        }
        // 光标颜色
        if (index == config.Config.colors.default_cursor) return u32ToRgb(term.default_cs);
        // 前景色
        if (index == config.Config.colors.default_foreground) return u32ToRgb(term.default_fg);
        // 背景色
        if (index == config.Config.colors.default_background) return u32ToRgb(term.default_bg);

        // 默认白色
        return .{ 0xFF, 0xFF, 0xFF };
    }

    fn getFontForGlyph(self: *Renderer, u: u21, attr: types.GlyphAttr) *x11.c.XftFont {
        var f = self.font;
        if (attr.bold and attr.italic) {
            f = self.font_italic_bold;
        } else if (attr.bold) {
            f = self.font_bold;
        } else if (attr.italic) {
            f = self.font_italic;
        }

        if (x11.c.XftCharExists(self.window.dpy, f, u) != 0) {
            return f;
        }

        for (self.fallbacks.items) |fb| {
            if (x11.c.XftCharExists(self.window.dpy, fb, u) != 0) {
                return fb;
            }
        }

        // Dynamic fallback via FontConfig
        const fc_charset = x11.c.FcCharSetCreate();
        defer x11.c.FcCharSetDestroy(fc_charset);
        if (x11.c.FcCharSetAddChar(fc_charset, u) == 0) return f;

        const pattern = x11.c.FcPatternDuplicate(self.font.pattern);
        if (pattern == null) return f;
        defer x11.c.FcPatternDestroy(pattern);

        _ = x11.c.FcPatternAddCharSet(pattern, x11.c.FC_CHARSET, fc_charset);

        // Add style attributes
        if (attr.italic) {
            _ = x11.c.FcPatternDel(pattern, x11.c.FC_SLANT);
            _ = x11.c.FcPatternAddInteger(pattern, x11.c.FC_SLANT, x11.c.FC_SLANT_ITALIC);
        }
        if (attr.bold) {
            _ = x11.c.FcPatternDel(pattern, x11.c.FC_WEIGHT);
            _ = x11.c.FcPatternAddInteger(pattern, x11.c.FC_WEIGHT, x11.c.FC_WEIGHT_BOLD);
        }

        _ = x11.c.FcConfigSubstitute(null, pattern, x11.c.FcMatchPattern);
        _ = x11.c.XftDefaultSubstitute(self.window.dpy, self.window.screen, pattern);

        var result: x11.c.FcResult = undefined;
        const match = x11.c.FcFontMatch(null, pattern, &result);

        if (match) |m| {
            // Check if we already have this font open to avoid duplicates?
            // Ideally yes, but XftFont structure comparison is tricky.
            // For now, just open it.
            const font_open = x11.c.XftFontOpenPattern(self.window.dpy, m);
            if (font_open) |new_font| {
                if (x11.c.XftCharExists(self.window.dpy, new_font, u) != 0) {
                    self.fallbacks.append(self.allocator, new_font) catch {
                        x11.c.XftFontClose(self.window.dpy, new_font);
                        return f;
                    };
                    return new_font;
                }
                x11.c.XftFontClose(self.window.dpy, new_font);
            } else {
                x11.c.FcPatternDestroy(m);
            }
        }

        return f;
    }

    fn drawRun(self: *Renderer, term: *Term, buf: []const u32, x: i32, y: i32, font: *x11.c.XftFont, fg: *x11.c.XftColor, glyph: Glyph, width_pixels: i32) !void {
        if (buf.len == 0) return;

        // Draw string
        x11.c.XftDrawString32(self.draw, fg, font, x, y + self.ascent, buf.ptr, @intCast(buf.len));

        // Draw decorations
        if (glyph.attr.underline) {
            const underline_fg_idx = if (glyph.ucolor[0] >= 0) custom: {
                const r = @as(u8, @intCast(@max(0, glyph.ucolor[0])));
                const g = @as(u8, @intCast(@max(0, glyph.ucolor[1])));
                const b = @as(u8, @intCast(@max(0, glyph.ucolor[2])));
                break :custom 0xFF000000 | (@as(u32, r) << 16) | (@as(u32, g) << 8) | @as(u32, b);
            } else glyph.fg;

            var underline_fg = try self.getColor(term, underline_fg_idx);

            const thickness = config.Config.cursor.thickness;
            const underline_y = y + self.ascent + 1;

            if (glyph.ustyle <= 0 or glyph.ustyle == 1) { // Single
                x11.c.XftDrawRect(self.draw, &underline_fg, x, underline_y, @intCast(width_pixels), thickness);
            } else if (glyph.ustyle == 1) { // Single (Duplicate case handled)
                x11.c.XftDrawRect(self.draw, &underline_fg, x, underline_y, @intCast(width_pixels), thickness);
            } else if (glyph.ustyle == 2) { // Double
                x11.c.XftDrawRect(self.draw, &underline_fg, x, underline_y, @intCast(width_pixels), thickness);
                x11.c.XftDrawRect(self.draw, &underline_fg, x, underline_y + thickness * 2, @intCast(width_pixels), thickness);
            } else if (glyph.ustyle == 3) { // Curly
                const amp = @max(1, @as(i32, @intCast(thickness)));
                const cy = underline_y + amp;
                const char_w = @as(i32, @intCast(self.char_width));
                var current_x = x;
                while (current_x < x + width_pixels) {
                    var points: [4]x11.c.XPoint = undefined;
                    points[0] = .{ .x = @intCast(current_x), .y = @intCast(cy) };
                    points[1] = .{ .x = @intCast(current_x + @divTrunc(char_w, 4)), .y = @intCast(cy - amp) };
                    points[2] = .{ .x = @intCast(current_x + @divTrunc(3 * char_w, 4)), .y = @intCast(cy + amp) };
                    points[3] = .{ .x = @intCast(current_x + char_w), .y = @intCast(cy) };

                    _ = x11.c.XSetForeground(self.window.dpy, self.window.gc, underline_fg.pixel);
                    _ = x11.c.XSetLineAttributes(self.window.dpy, self.window.gc, 0, x11.c.LineSolid, x11.c.CapButt, x11.c.JoinMiter);
                    _ = x11.c.XDrawLines(self.window.dpy, self.window.buf, self.window.gc, &points, 4, x11.c.CoordModeOrigin);
                    current_x += char_w;
                }
            } else if (glyph.ustyle == 4) { // Dotted
                const dash_width_u = @divTrunc(self.char_width, 4);
                var cx: i32 = x;
                while (cx < x + width_pixels) {
                    for (0..2) |k| {
                        const dash_x = cx + @as(i32, @intCast(k * dash_width_u * 2));
                        if (dash_x < x + width_pixels)
                            x11.c.XftDrawRect(self.draw, &underline_fg, dash_x, underline_y, dash_width_u, thickness);
                    }
                    cx += @intCast(self.char_width);
                }
            }
        }

        if (glyph.attr.struck) {
            x11.c.XftDrawRect(self.draw, fg, x, y + @divTrunc(self.ascent * 2, 3), @intCast(width_pixels), 1);
        }
    }

    pub fn render(self: *Renderer, term: *Term, selector: *selection.Selector) !?x11.c.XRectangle {
        if (term.line == null) return null;

        // Default background color
        var default_bg = try self.getColor(term, 259);

        const hborder = @as(i32, @intCast(self.window.hborder_px));
        const vborder = @as(i32, @intCast(self.window.vborder_px));
        const grid_w = @as(i32, @intCast(term.col)) * @as(i32, @intCast(self.char_width));
        const grid_h = @as(i32, @intCast(term.row)) * @as(i32, @intCast(self.char_height));

        // 清除四周多余区域及边框
        // 1. 顶部区域
        if (vborder > 0)
            x11.c.XftDrawRect(self.draw, &default_bg, 0, 0, @intCast(self.window.width), @intCast(vborder));
        // 2. 底部区域
        const bottom_y = vborder + grid_h;
        if (bottom_y < @as(i32, @intCast(self.window.height))) {
            x11.c.XftDrawRect(self.draw, &default_bg, 0, bottom_y, @intCast(self.window.width), @intCast(@as(i32, @intCast(self.window.height)) - bottom_y));
        }
        // 3. 左侧区域
        if (hborder > 0)
            x11.c.XftDrawRect(self.draw, &default_bg, 0, vborder, @intCast(hborder), @intCast(grid_h));
        // 4. 右侧区域
        const right_x = hborder + grid_w;
        if (right_x < @as(i32, @intCast(self.window.width))) {
            x11.c.XftDrawRect(self.draw, &default_bg, right_x, vborder, @intCast(@as(i32, @intCast(self.window.width)) - right_x), @intCast(grid_h));
        }

        var min_y: ?usize = null;
        var max_y: ?usize = null;

        // Iterate over rows
        for (0..term.row) |y| {
            // Determine which line to draw
            const line_data = screen_mod.getVisibleLine(term, y);

            // 脏标记检查逻辑优化：
            // 只有在非滚动查看状态且没有活动的文本选择时，才通过脏标记跳过渲染。
            // 在备用屏幕 (vi/btop) 下，脏标记仍然是有效的，因为 Parser 同样会正确设置 dirty 标志。
            if (term.scr == 0 and term.selection.mode == .idle) {
                if (term.dirty) |dirty| {
                    if (y < dirty.len and !dirty[y]) continue;
                }
            }

            // Update dirty range
            if (min_y == null) min_y = y;
            max_y = y;

            const y_pos = @as(i32, @intCast(y * self.char_height)) + vborder;

            // Clear the dirty grid row with default background
            x11.c.XftDrawRect(self.draw, &default_bg, hborder, y_pos, @intCast(grid_w), @intCast(self.char_height));

            // 第一阶段：绘制所有非默认背景
            for (0..@min(term.col, line_data.len)) |x| {
                const glyph = line_data[x];
                const x_pos = @as(i32, @intCast(x * self.char_width)) + hborder;

                var bg_idx = glyph.bg;

                var reverse = glyph.attr.reverse != term.mode.reverse;
                if (selector.isSelected(term, x, y)) {
                    reverse = !reverse;
                }

                if (reverse) {
                    bg_idx = glyph.fg;
                }

                if (bg_idx != config.Config.colors.default_background) {
                    var bg_col = try self.getColor(term, bg_idx);
                    x11.c.XftDrawRect(self.draw, &bg_col, x_pos, y_pos, @intCast(self.char_width), @intCast(self.char_height));
                }
            }

            // 第二阶段：绘制所有字符 (批量绘制优化)
            var run_len: usize = 0;
            var run_buf: [1024]u32 = undefined;
            var run_x: i32 = 0;
            var run_font: *x11.c.XftFont = undefined;
            var run_fg: x11.c.XftColor = undefined;
            var run_glyph: Glyph = undefined;
            var run_allocated_faint: bool = false;

            for (0..@min(term.col, line_data.len)) |x| {
                const glyph = line_data[x];
                const x_pos = @as(i32, @intCast(x * self.char_width)) + hborder;

                if (glyph.attr.wide_dummy) continue;

                var fg_idx = glyph.fg;
                var bg_idx = glyph.bg;

                if (glyph.attr.bold) {
                    if (fg_idx < 8) {
                        fg_idx += 8;
                    } else if (fg_idx == config.Config.colors.default_foreground) {
                        fg_idx = 15;
                    }
                }

                var reverse = glyph.attr.reverse != term.mode.reverse;
                if (selector.isSelected(term, x, y)) {
                    reverse = !reverse;
                }

                if (reverse) {
                    const tmp = fg_idx;
                    fg_idx = bg_idx;
                    bg_idx = tmp;
                }

                if (glyph.attr.blink and config.Config.cursor.blink_interval_ms > 0) {
                    const blink_state = @mod(@divFloor(std.time.milliTimestamp(), config.Config.cursor.blink_interval_ms), 2) == 0;
                    if (!blink_state) {
                        // Skip invisible blinking text, but must flush current run first
                        if (run_len > 0) {
                            try self.drawRun(term, run_buf[0..run_len], run_x, y_pos, run_font, &run_fg, run_glyph, @intCast(run_len * self.char_width));
                            run_len = 0;
                            if (run_allocated_faint) {
                                x11.c.XftColorFree(self.window.dpy, self.window.vis, self.window.cmap, &run_fg);
                                run_allocated_faint = false;
                            }
                        }
                        continue;
                    }
                }

                var font: *x11.c.XftFont = undefined;
                var fg: x11.c.XftColor = undefined;
                var allocated_faint = false;

                if (boxdraw.BoxDraw.isBoxDraw(glyph.u)) {
                    if (run_len > 0) {
                        try self.drawRun(term, run_buf[0..run_len], run_x, y_pos, run_font, &run_fg, run_glyph, @intCast(run_len * self.char_width));
                        run_len = 0;
                        if (run_allocated_faint) {
                            x11.c.XftColorFree(self.window.dpy, self.window.vis, self.window.cmap, &run_fg);
                            run_allocated_faint = false;
                        }
                    }

                    var b_fg = try self.getColor(term, fg_idx);
                    var b_bg = try self.getColor(term, bg_idx);
                    try self.drawBoxChar(glyph.u, x_pos, y_pos, @intCast(self.char_width), @intCast(self.char_height), &b_fg, &b_bg, glyph.attr.bold);
                    continue;
                }

                font = self.getFontForGlyph(glyph.u, glyph.attr);
                fg = try self.getColor(term, fg_idx);

                if (glyph.attr.faint) {
                    var col_faint = fg.color;
                    col_faint.red /= 2;
                    col_faint.green /= 2;
                    col_faint.blue /= 2;
                    var new_fg: x11.c.XftColor = undefined;
                    if (x11.c.XftColorAllocValue(self.window.dpy, self.window.vis, self.window.cmap, &col_faint, &new_fg) != 0) {
                        fg = new_fg;
                        allocated_faint = true;
                    }
                }

                var compatible = true;
                if (run_len == 0) {
                    compatible = false;
                } else {
                    if (run_font != font) compatible = false;
                    if (run_fg.pixel != fg.pixel) compatible = false;
                    if (run_glyph.attr.underline != glyph.attr.underline) compatible = false;
                    if (glyph.attr.underline) {
                        if (run_glyph.ustyle != glyph.ustyle) compatible = false;
                        if (!std.meta.eql(run_glyph.ucolor, glyph.ucolor)) compatible = false;
                    }
                    if (run_glyph.attr.struck != glyph.attr.struck) compatible = false;
                }

                if (!compatible) {
                    if (run_len > 0) {
                        try self.drawRun(term, run_buf[0..run_len], run_x, y_pos, run_font, &run_fg, run_glyph, @intCast(run_len * self.char_width));
                        run_len = 0;
                        if (run_allocated_faint) {
                            x11.c.XftColorFree(self.window.dpy, self.window.vis, self.window.cmap, &run_fg);
                            run_allocated_faint = false;
                        }
                    }

                    run_x = x_pos;
                    run_font = font;
                    run_fg = fg;
                    run_glyph = glyph;
                    run_allocated_faint = allocated_faint;
                } else {
                    if (allocated_faint) {
                        x11.c.XftColorFree(self.window.dpy, self.window.vis, self.window.cmap, &fg);
                    }
                }

                if (glyph.u != ' ' and glyph.u != 0) {
                    run_buf[run_len] = @as(u32, glyph.u);
                } else {
                    run_buf[run_len] = ' '; // Draw space for empty/space cells
                }
                run_len += 1;

                if (run_len >= run_buf.len) {
                    try self.drawRun(term, run_buf[0..run_len], run_x, y_pos, run_font, &run_fg, run_glyph, @intCast(run_len * self.char_width));
                    run_x += @as(i32, @intCast(run_len * self.char_width));
                    run_len = 0;
                }
            }

            if (run_len > 0) {
                try self.drawRun(term, run_buf[0..run_len], run_x, y_pos, run_font, &run_fg, run_glyph, @intCast(run_len * self.char_width));
                if (run_allocated_faint) {
                    x11.c.XftColorFree(self.window.dpy, self.window.vis, self.window.cmap, &run_fg);
                }
            }

            if (term.dirty) |dirty| {
                dirty[y] = false;
            }
        }

        if (min_y) |min| {
            const max = max_y orelse min;

            var rect = x11.c.XRectangle{
                .x = 0,
                .y = @intCast(@as(i32, @intCast(min * self.char_height)) + vborder),
                .width = @intCast(self.window.width),
                .height = @intCast((max - min + 1) * self.char_height),
            };

            // Include top border if drawing first line
            if (min == 0) {
                rect.y = 0;
                rect.height += @intCast(vborder);
            }

            // Include bottom border if drawing last line
            if (max == term.row - 1) {
                const total_h = @as(i32, @intCast(self.window.height));
                const current_bottom = @as(i32, @intCast(rect.y)) + @as(i32, @intCast(rect.height));
                if (total_h > current_bottom) {
                    rect.height += @intCast(total_h - current_bottom);
                }
            }

            return rect;
        }

        return null;
    }

    pub fn renderCursor(self: *Renderer, term: *Term) !void {
        if (term.mode.hide_cursor) return;

        const cx = term.c.x;
        const cy = term.c.y;

        if (cx >= term.col or cy >= term.row) return;

        const hborder = @as(i32, @intCast(self.window.hborder_px));
        const vborder = @as(i32, @intCast(self.window.vborder_px));
        const x_pos = @as(i32, @intCast(cx * self.char_width)) + hborder;
        const screen_y = if (term.scr > 0 and !term.mode.alt_screen) @as(isize, @intCast(cy)) - @as(isize, @intCast(term.scr)) else @as(isize, @intCast(cy));
        if (screen_y < 0 or screen_y >= @as(isize, @intCast(term.row))) return;
        const y_pos = @as(i32, @intCast(screen_y)) * @as(i32, @intCast(self.char_height)) + vborder;

        if (config.Config.cursor.blink_interval_ms == 0) {
            self.cursor_blink_state = true;
        }

        var style = term.cursor_style;

        // Force hollow cursor when window is not focused
        if (!term.mode.focused) {
            style = .steady_st_cursor;
        }

        const is_blinking_style = style.shouldBlink();

        // 如果是闪烁样式且当前在不可见阶段，则不绘制
        if (is_blinking_style and !self.cursor_blink_state) {
            return;
        }

        const screen = term.line;
        var glyph = Glyph{};
        if (screen) |scr| {
            if (cy < scr.len and cx < scr[cy].len) {
                glyph = scr[cy][cx];
            }
        }

        const cursor_fg_idx: u32 = 259;
        var cursor_bg_idx: u32 = 256;

        if (term.mode.reverse) {
            if (is_blinking_style and self.cursor_blink_state) {
                cursor_bg_idx = 258;
            } else {
                cursor_bg_idx = 259;
            }
        }

        var draw_col = try self.getColor(term, cursor_bg_idx);

        switch (style) {
            .blinking_block, .blinking_block_default => { // blinking block
                x11.c.XftDrawRect(self.draw, &draw_col, x_pos, y_pos, @intCast(self.char_width), @intCast(self.char_height));
                if (glyph.u != ' ' and glyph.u != 0) {
                    var fg = try self.getColor(term, cursor_fg_idx);
                    const char = @as(u32, glyph.u);
                    const font = self.getFontForGlyph(glyph.u, glyph.attr);
                    x11.c.XftDrawString32(self.draw, &fg, font, x_pos, y_pos + self.ascent, &char, 1);
                }
            },
            .steady_block => { // steady block
                x11.c.XftDrawRect(self.draw, &draw_col, x_pos, y_pos, @intCast(self.char_width), @intCast(self.char_height));
                if (glyph.u != ' ' and glyph.u != 0) {
                    var fg = try self.getColor(term, cursor_fg_idx);
                    const char = @as(u32, glyph.u);
                    const font = self.getFontForGlyph(glyph.u, glyph.attr);
                    x11.c.XftDrawString32(self.draw, &fg, font, x_pos, y_pos + self.ascent, &char, 1);
                }
            },
            .blinking_underline => { // blinking underline
                const thickness = config.Config.cursor.thickness;
                const y_line = y_pos + @as(i32, @intCast(self.char_height)) - @as(i32, @intCast(thickness));
                x11.c.XftDrawRect(self.draw, &draw_col, x_pos, y_line, @intCast(self.char_width), thickness);
            },
            .steady_underline => { // steady underline
                const thickness = config.Config.cursor.thickness;
                const y_line = y_pos + @as(i32, @intCast(self.char_height)) - @as(i32, @intCast(thickness));
                x11.c.XftDrawRect(self.draw, &draw_col, x_pos, y_line, @intCast(self.char_width), thickness);
            },
            .blinking_bar => { // blinking bar
                const thickness = config.Config.cursor.thickness;
                x11.c.XftDrawRect(self.draw, &draw_col, x_pos, y_pos, thickness, @intCast(self.char_height));
            },
            .steady_bar => { // steady bar
                const thickness = config.Config.cursor.thickness;
                x11.c.XftDrawRect(self.draw, &draw_col, x_pos, y_pos, thickness, @intCast(self.char_height));
            },
            .blinking_st_cursor, .steady_st_cursor => { // st cursor (hollow box)
                const thickness = config.Config.cursor.thickness;
                x11.c.XftDrawRect(self.draw, &draw_col, x_pos, y_pos, @intCast(self.char_width), thickness);
                x11.c.XftDrawRect(self.draw, &draw_col, x_pos, y_pos + @as(i32, @intCast(self.char_height)) - @as(i32, @intCast(thickness)), @intCast(self.char_width), thickness);
                x11.c.XftDrawRect(self.draw, &draw_col, x_pos, y_pos, thickness, @intCast(self.char_height));
                x11.c.XftDrawRect(self.draw, &draw_col, x_pos + @as(i32, @intCast(self.char_width)) - @as(i32, @intCast(thickness)), y_pos, thickness, @intCast(self.char_height));
                if (glyph.u != ' ' and glyph.u != 0) {
                    var fg = try self.getColor(term, 258);
                    const char = @as(u32, glyph.u);
                    const font = self.getFontForGlyph(glyph.u, glyph.attr);
                    x11.c.XftDrawString32(self.draw, &fg, font, x_pos, y_pos + self.ascent, &char, 1);
                }
            },
        }
    }

    fn drawBoxChar(self: *Renderer, u: u21, x: i32, y: i32, w: i32, h: i32, color: *x11.c.XftColor, bg_color: *x11.c.XftColor, bold: bool) !void {
        const data = boxdraw.BoxDraw.getDrawData(u);
        if (data == 0) return;
        const mwh = @min(w, h);
        const base_s = @max(1, @divTrunc(mwh + 4, 8));
        const is_bold = (bold and config.Config.draw.boxdraw_bold) and mwh >= 6;
        const s: i32 = if (is_bold) @max(base_s + 1, @divTrunc(3 * base_s + 1, 2)) else base_s;
        const w2_line = @divTrunc(w - s + 1, 2);
        const h2_line = @divTrunc(h - s + 1, 2);
        const midx = x + w2_line;
        const midy = y + h2_line;
        const cat = data & ~@as(u16, boxdraw_data.BDB | 0xff);
        if (cat == boxdraw_data.BTR) {
            const type_ = data & 0xFF;

            // 目标：宽度和高度都是 1 个字符的宽度 (W x W 正方形区域)
            const side = @as(f32, @floatFromInt(w));
            const target_w = side;
            const target_h = side;

            // 居中于原始 WxH 区域 (通常 H > W)
            const tx = @as(f32, @floatFromInt(x)) + (@as(f32, @floatFromInt(w)) - target_w) / 2.0;
            const ty = @as(f32, @floatFromInt(y)) + (@as(f32, @floatFromInt(h)) - target_h) / 2.0;

            var points: [3]x11.c.XPoint = undefined;
            switch (type_) {
                1 => { // Up ▲
                    points[0] = x11.c.XPoint{ .x = @intFromFloat(tx + target_w / 2.0), .y = @intFromFloat(ty) };
                    points[1] = x11.c.XPoint{ .x = @intFromFloat(tx), .y = @intFromFloat(ty + target_h) };
                    points[2] = x11.c.XPoint{ .x = @intFromFloat(tx + target_w), .y = @intFromFloat(ty + target_h) };
                },
                2 => { // Down ▼
                    points[0] = x11.c.XPoint{ .x = @intFromFloat(tx), .y = @intFromFloat(ty) };
                    points[1] = x11.c.XPoint{ .x = @intFromFloat(tx + target_w), .y = @intFromFloat(ty) };
                    points[2] = x11.c.XPoint{ .x = @intFromFloat(tx + target_w / 2.0), .y = @intFromFloat(ty + target_h) };
                },
                3 => { // Left ◀
                    points[0] = x11.c.XPoint{ .x = @intFromFloat(tx + target_w), .y = @intFromFloat(ty) };
                    points[1] = x11.c.XPoint{ .x = @intFromFloat(tx + target_w), .y = @intFromFloat(ty + target_h) };
                    points[2] = x11.c.XPoint{ .x = @intFromFloat(tx), .y = @intFromFloat(ty + target_h / 2.0) };
                },
                4 => { // Right ▶
                    points[0] = x11.c.XPoint{ .x = @intFromFloat(tx), .y = @intFromFloat(ty) };
                    points[1] = x11.c.XPoint{ .x = @intFromFloat(tx), .y = @intFromFloat(ty + target_h) };
                    points[2] = x11.c.XPoint{ .x = @intFromFloat(tx + target_w), .y = @intFromFloat(ty + target_h / 2.0) };
                },
                else => {
                    std.log.debug("未知的三角形绘制类型: {d}", .{type_});
                    return;
                },
            }

            const gc = x11.c.XCreateGC(self.window.dpy, self.window.buf, 0, null);
            defer _ = x11.c.XFreeGC(self.window.dpy, gc);
            _ = x11.c.XSetForeground(self.window.dpy, gc, color.pixel);
            _ = x11.c.XFillPolygon(self.window.dpy, self.window.buf, gc, &points, 3, x11.c.Convex, x11.c.CoordModeOrigin);
            return;
        }
        if (cat == boxdraw_data.BRL) {
            const bw1 = @divTrunc(w + 1, 2);
            const bh1 = @divTrunc(h + 2, 4);
            const bh2 = @divTrunc(h + 1, 2);
            const bh3 = @divTrunc(3 * h + 2, 4);
            if (data & 1 != 0) x11.c.XftDrawRect(self.draw, color, x, y, @intCast(bw1), @intCast(bh1));
            if (data & 2 != 0) x11.c.XftDrawRect(self.draw, color, x, y + bh1, @intCast(bw1), @intCast(bh2 - bh1));
            if (data & 4 != 0) x11.c.XftDrawRect(self.draw, color, x, y + bh2, @intCast(bw1), @intCast(bh3 - bh2));
            if (data & 8 != 0) x11.c.XftDrawRect(self.draw, color, x + bw1, y, @intCast(w - bw1), @intCast(bh1));
            if (data & 16 != 0) x11.c.XftDrawRect(self.draw, color, x + bw1, y + bh1, @intCast(w - bw1), @intCast(bh2 - bh1));
            if (data & 32 != 0) x11.c.XftDrawRect(self.draw, color, x + bw1, y + bh1, @intCast(w - bw1), @intCast(bh2 - bh1)); // This was likely a placeholder
            if (data & 32 != 0) x11.c.XftDrawRect(self.draw, color, x + bw1, y + bh2, @intCast(w - bw1), @intCast(bh3 - bh2));
            if (data & 64 != 0) x11.c.XftDrawRect(self.draw, color, x, y + bh3, @intCast(bw1), @intCast(h - bh3));
            if (data & 128 != 0) x11.c.XftDrawRect(self.draw, color, x + bw1, y + bh3, @intCast(w - bw1), @intCast(h - bh3));
            return;
        }
        if (cat == boxdraw_data.BBD) {
            const d = @divTrunc(@as(i32, @intCast(data & 0xFF)) * h + 4, 8);
            x11.c.XftDrawRect(self.draw, color, x, y + d, @intCast(w), @intCast(h - d));
            return;
        } else if (cat == boxdraw_data.BBU) {
            const d = @divTrunc(@as(i32, @intCast(data & 0xFF)) * h + 4, 8);
            x11.c.XftDrawRect(self.draw, color, x, y, @intCast(w), @intCast(d));
            return;
        } else if (cat == boxdraw_data.BBL) {
            const d = @divTrunc(@as(i32, @intCast(data & 0xFF)) * w + 4, 8);
            x11.c.XftDrawRect(self.draw, color, x, y, @intCast(d), @intCast(h));
            return;
        } else if (cat == boxdraw_data.BBR) {
            const d = @divTrunc(@as(i32, @intCast(data & 0xFF)) * w + 4, 8);
            x11.c.XftDrawRect(self.draw, color, x + d, y, @intCast(w - d), @intCast(h));
            return;
        }
        if (cat == boxdraw_data.BBQ) {
            const qw = @divTrunc(w + 1, 2);
            const qh = @divTrunc(h + 1, 2);
            if (data & boxdraw_data.TL != 0) x11.c.XftDrawRect(self.draw, color, x, y, @intCast(qw), @intCast(qh));
            if (data & boxdraw_data.TR != 0) x11.c.XftDrawRect(self.draw, color, x + qw, y, @intCast(w - qw), @intCast(qh));
            if (data & boxdraw_data.BL != 0) x11.c.XftDrawRect(self.draw, color, x, y + qh, @intCast(qw), @intCast(h - qh));
            if (data & boxdraw_data.BR != 0) x11.c.XftDrawRect(self.draw, color, x + qw, y + qh, @intCast(w - qw), @intCast(h - qh));
            return;
        }
        if (data & boxdraw_data.BBS != 0) {
            const d = @as(u16, @intCast(data & 0xFF));
            var xrc = x11.c.XRenderColor{
                .red = @intCast(@divTrunc(@as(u32, color.*.color.red) * d + @as(u32, bg_color.*.color.red) * (4 - d) + 2, 4)),
                .green = @intCast(@divTrunc(@as(u32, color.*.color.green) * d + @as(u32, bg_color.*.color.green) * (4 - d) + 2, 4)),
                .blue = @intCast(@divTrunc(@as(u32, color.*.color.blue) * d + @as(u32, bg_color.*.color.blue) * (4 - d) + 2, 4)),
                .alpha = 0xFFFF,
            };
            var xfc: x11.c.XftColor = undefined;
            if (x11.c.XftColorAllocValue(self.window.dpy, self.window.vis, self.window.cmap, &xrc, &xfc) != 0) {
                x11.c.XftDrawRect(self.draw, &xfc, x, y, @intCast(w), @intCast(h));
                x11.c.XftColorFree(self.window.dpy, self.window.vis, self.window.cmap, &xfc);
            }
            return;
        }
        if (data & (boxdraw_data.BDL | boxdraw_data.BDA) != 0) {
            const light = data & (boxdraw_data.LL | boxdraw_data.LU | boxdraw_data.LR | boxdraw_data.LD);
            const double_ = data & (boxdraw_data.DL | boxdraw_data.DU | boxdraw_data.DR | boxdraw_data.DD);
            if (light != 0) {
                const arc = data & boxdraw_data.BDA != 0;
                const multi_light = light & (light -% 1) != 0;
                const multi_double = double_ & (double_ -% 1) != 0;
                const d_len: i32 = if (arc or (multi_double and !multi_light)) -s else 0;
                if (data & boxdraw_data.LL != 0) x11.c.XftDrawRect(self.draw, color, x, midy, @intCast(w2_line + s + d_len), @intCast(s));
                if (data & boxdraw_data.LU != 0) x11.c.XftDrawRect(self.draw, color, midx, y, @intCast(s), @intCast(h2_line + s + d_len));
                if (data & boxdraw_data.LR != 0) x11.c.XftDrawRect(self.draw, color, midx - d_len, midy, @intCast(w - w2_line + d_len), @intCast(s));
                if (data & boxdraw_data.LD != 0) x11.c.XftDrawRect(self.draw, color, midx, midy - d_len, @intCast(s), @intCast(h - h2_line + d_len));
            }
            if (double_ != 0) {
                const dl = data & boxdraw_data.DL != 0;
                const du = data & boxdraw_data.DU != 0;
                const dr = data & boxdraw_data.DR != 0;
                const dd = data & boxdraw_data.DD != 0;
                if (dl) {
                    const p: i32 = if (dd) -s else 0;
                    const n: i32 = if (du) -s else if (dd) s else 0;
                    x11.c.XftDrawRect(self.draw, color, x, midy + s, @intCast(w2_line + s + p), @intCast(s));
                    x11.c.XftDrawRect(self.draw, color, x, midy - s, @intCast(w2_line + s + n), @intCast(s));
                }
                if (du) {
                    const p: i32 = if (dl) -s else 0;
                    const n: i32 = if (dr) -s else if (dl) s else 0;
                    x11.c.XftDrawRect(self.draw, color, midx - s, y, @intCast(s), @intCast(h2_line + s + p));
                    x11.c.XftDrawRect(self.draw, color, midx + s, y, @intCast(s), @intCast(h2_line + s + n));
                }
                if (dr) {
                    const p: i32 = if (du) -s else 0;
                    const n: i32 = if (dd) -s else if (du) s else 0;
                    x11.c.XftDrawRect(self.draw, color, midx - p, midy - s, @intCast(w - w2_line + p), @intCast(s));
                    x11.c.XftDrawRect(self.draw, color, midx - n, midy + s, @intCast(w - w2_line + n), @intCast(s));
                }
                if (dd) {
                    const p: i32 = if (dr) -s else 0;
                    const n: i32 = if (dl) -s else if (dr) s else 0;
                    x11.c.XftDrawRect(self.draw, color, midx + s, midy - p, @intCast(s), @intCast(h - h2_line + p));
                    x11.c.XftDrawRect(self.draw, color, midx - s, midy - n, @intCast(s), @intCast(h - h2_line + n));
                }
            }
        }
    }

    pub fn resize(self: *Renderer) void {
        x11.c.XftDrawChange(self.draw, self.window.buf);
    }

    pub fn resetCursorBlink(self: *Renderer) void {
        self.cursor_blink_state = true;
        self.last_blink_time = std.time.milliTimestamp();
    }
};

fn u32ToRgb(color: u32) [3]u8 {
    return .{
        @truncate((color >> 16) & 0xFF),
        @truncate((color >> 8) & 0xFF),
        @truncate(color & 0xFF),
    };
}
