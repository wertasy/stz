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
const stz = @import("stz");

const x11 = stz.c.x11;
const hb = stz.harfbuzz;
const types = stz.types;
const config = stz.Config;
const Selector = stz.Selector;
const boxdraw = @import("boxdraw.zig");
const boxdraw_data = @import("boxdraw_data.zig");
const Terminal = stz.Terminal;
const unicode = stz.unicode;

const Window = @import("window.zig");
const Glyph = types.Glyph;

pub const RendererError = error{
    XftDrawCreateFailed,
    FontLoadFailed,
    ColorAllocFailed,
};

const Renderer = @This();

window: *Window,
allocator: std.mem.Allocator,
draw: *x11.XftDraw,
font: *x11.XftFont,
font_italic: *x11.XftFont,
font_bold: *x11.XftFont,
font_italic_bold: *x11.XftFont,
fallbacks: std.ArrayList(*x11.XftFont),

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
colors: [300]x11.XftColor,
loaded_colors: [300]bool,
truecolor_cache: std.AutoArrayHashMap(u32, x11.XftColor),

// Glyph specs buffer for batch drawing
specs_buffer: std.ArrayList(x11.XftGlyphFontSpec),

// HarfBuzz transform data for ligatures
hb_tansformer: hb,
hb_data: hb.TransformData,

// Font cache: (u21 << 16 | u16) -> *XftFont
// Caches which font is used for a specific character and attribute combination
font_cache: std.AutoHashMap(u64, *x11.XftFont),

pub fn init(window: *Window, allocator: std.mem.Allocator) !Renderer {
    // Initialize buffer in window if not already
    window.resizeBuffer(window.width, window.height);

    const draw = x11.XftDrawCreate(window.dpy, window.buf, window.vis, window.cmap);
    if (draw == null) return error.XftDrawCreateFailed;

    // Load font
    var configured_font_name: [:0]const u8 = config.font.name; // e.g., "Monospace:size=12"

    // Try loading configured font

    var font = x11.XftFontOpenName(window.dpy, window.screen, configured_font_name);

    if (font == null) {
        std.log.warn("Failed to load configured font: {s}, trying default 'Monospace:pixelsize=14'", .{configured_font_name});
        configured_font_name = "Monospace:pixelsize=14";
        font = x11.XftFontOpenName(window.dpy, window.screen, configured_font_name);
    }

    if (font == null) {
        std.log.warn("Failed to load default font, trying backup 'fixed'", .{});
        font = x11.XftFontOpenName(window.dpy, window.screen, "fixed");
        if (font == null) return error.FontLoadFailed;
    }

    // Calculate character width using the same method as st:
    // Measure all ASCII printable characters together to account for kerning
    // This matches st's approach: entire string is measured together,
    // then divided by length to get average width per character
    const ascii_printable = " !\"#$%&'()*+,-./0123456789:;<=>?@ABCDEFGHIJKLMNOPQRSTUVWXYZ[\\]^_`abcdefghijklmnopqrstuvwxyz{|}~";
    var extents: x11.XGlyphInfo = undefined;
    x11.XftTextExtents8(window.dpy, font, ascii_printable, @intCast(ascii_printable.len), &extents);

    // Divide by string length to get average width (accounts for kerning/ligatures)
    const avg_width = if (ascii_printable.len > 0) @as(f32, @floatFromInt(extents.xOff)) / @as(f32, @floatFromInt(ascii_printable.len)) else @as(f32, @floatFromInt(font.*.max_advance_width));
    const char_width = @max(1, @as(u32, @intFromFloat(@ceil(avg_width * config.font.cwscale))));
    const char_height = @max(1, @as(u32, @intFromFloat(@ceil(@as(f32, @floatFromInt(font.*.ascent + font.*.descent)) * config.font.chscale))));

    // std.log.info("Font loaded. Metrics: avg_width={d:.2}, char_width={d}, char_height={d}, ascent={d}, descent={d}", .{ avg_width, char_width, char_height, font.*.ascent, font.*.descent });

    const ascent = font.*.ascent;
    const descent = font.*.descent;

    // Load font variants
    const pattern = x11.FcPatternDuplicate(font.*.pattern);

    // Italic
    const italic_pattern = x11.FcPatternDuplicate(pattern);
    _ = x11.FcPatternDel(italic_pattern, x11.FC_SLANT);
    _ = x11.FcPatternAddInteger(italic_pattern, x11.FC_SLANT, x11.FC_SLANT_ITALIC);
    var font_italic = x11.XftFontOpenPattern(window.dpy, italic_pattern);
    if (font_italic == null) font_italic = font;

    // Bold - 尝试使用完整字体名称加载粗体变体
    const bold_pattern = x11.FcPatternDuplicate(pattern);
    _ = x11.FcPatternDel(bold_pattern, x11.FC_WEIGHT);
    _ = x11.FcPatternAddInteger(bold_pattern, x11.FC_WEIGHT, config.font.bold_weight);

    // 尝试删除大小和样式限制，让 FontConfig 更容易匹配粗体变体
    _ = x11.FcPatternDel(bold_pattern, x11.FC_PIXEL_SIZE);
    _ = x11.FcPatternDel(bold_pattern, x11.FC_SIZE);
    _ = x11.FcPatternDel(bold_pattern, x11.FC_SLANT);

    var font_bold = x11.XftFontOpenPattern(window.dpy, bold_pattern);
    if (font_bold == null or font_bold == font) {
        // 备用方法：使用带 style=Bold 的完整字体名称
        var buf: [256]u8 = undefined;
        const font_name = std.fmt.bufPrintZ(&buf, "{s}:style=Bold:weight={d}", .{ config.font.name, config.font.bold_weight }) catch "Monospace:style=Bold";
        font_bold = x11.XftFontOpenName(window.dpy, window.screen, font_name);
        if (font_bold == null) {
            std.log.warn("粗体字体加载失败，回退到普通字体", .{});
            font_bold = font;
        }
    }

    // Italic Bold
    const ib_pattern = x11.FcPatternDuplicate(pattern);
    _ = x11.FcPatternDel(ib_pattern, x11.FC_SLANT);
    _ = x11.FcPatternAddInteger(ib_pattern, x11.FC_SLANT, x11.FC_SLANT_ITALIC);
    _ = x11.FcPatternDel(ib_pattern, x11.FC_WEIGHT);
    _ = x11.FcPatternAddInteger(ib_pattern, x11.FC_WEIGHT, config.font.bold_weight);
    var font_italic_bold = x11.XftFontOpenPattern(window.dpy, ib_pattern);
    if (font_italic_bold == null) font_italic_bold = font;

    x11.FcPatternDestroy(pattern);

    // 打印字体地址（调试用）
    // std.log.info("主字体: {*}", .{font});
    // std.log.info("粗体字体: {*}", .{font_bold});
    // std.log.info("斜体字体: {*}", .{font_italic});
    // std.log.info("斜粗字体: {*}", .{font_italic_bold});
    // std.log.info("字体是否相同: font==font_bold={any}, font==font_italic={any}", .{font == font_bold, font == font_italic});

    // Update window metrics
    window.cell_width = char_width;
    window.cell_height = char_height;

    // 加载回退字体，使用与 st 相同的算法
    var fallbacks = try std.ArrayList(*x11.XftFont).initCapacity(allocator, 4);
    errdefer {
        for (fallbacks.items) |f| x11.XftFontClose(window.dpy, f);
        fallbacks.deinit(allocator);
    }

    for (config.font.fallback_fonts) |font_name| {
        // 解析字体名称
        var fb_pattern: ?*x11.FcPattern = undefined;
        if (font_name[0] == '-') {
            fb_pattern = x11.XftXlfdParse(@ptrCast(font_name), 0, 0);
        } else {
            fb_pattern = x11.FcNameParse(@ptrCast(font_name));
        }

        if (fb_pattern == null) {
            std.log.warn("无法解析回退字体: {s}", .{font_name});
            continue;
        }

        defer x11.FcPatternDestroy(fb_pattern.?);

        // 调整字体大小：usedfontsize - defaultfontsize
        var fontval: f64 = 0;
        if (x11.FcPatternGetDouble(fb_pattern.?, x11.FC_PIXEL_SIZE, 0, &fontval) == x11.FcResultMatch) {
            var pixel_size: c_int = undefined;
            if (x11.FcPatternGetInteger(font.?.*.pattern, x11.FC_PIXEL_SIZE, 0, &pixel_size) == x11.FcResultMatch) {
                const sizeshift = @as(f64, @floatFromInt(pixel_size)) - @as(f64, @floatFromInt(config.font.size));
                if (sizeshift != 0) {
                    fontval += sizeshift;
                    _ = x11.FcPatternDel(fb_pattern.?, x11.FC_PIXEL_SIZE);
                    _ = x11.FcPatternDel(fb_pattern.?, x11.FC_SIZE);
                    _ = x11.FcPatternAddDouble(fb_pattern.?, x11.FC_PIXEL_SIZE, fontval);
                }
            }
        }

        _ = x11.FcPatternAddBool(fb_pattern.?, x11.FC_SCALABLE, 1);
        _ = x11.FcConfigSubstitute(null, fb_pattern.?, x11.FcMatchPattern);
        _ = x11.XftDefaultSubstitute(window.dpy, window.screen, fb_pattern.?);

        var result: x11.FcResult = undefined;
        const match = x11.FcFontMatch(null, fb_pattern.?, &result);

        if (match) |m| {
            if (x11.XftFontOpenPattern(window.dpy, m)) |f| {
                try fallbacks.append(allocator, f);
            } else {
                x11.FcPatternDestroy(m);
            }
        }
    }

    var specs_buffer = try std.ArrayList(x11.XftGlyphFontSpec).initCapacity(allocator, 256);
    errdefer specs_buffer.deinit(allocator);

    // 初始化 HarfBuzz 缓存

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
        .current_font_size = config.font.size,
        .original_font_size = config.font.size,
        .cursor_blink_state = true,
        .last_blink_time = std.time.milliTimestamp(),
        .colors = undefined,
        .loaded_colors = [_]bool{false} ** 300,
        .truecolor_cache = std.AutoArrayHashMap(u32, x11.XftColor).init(allocator),
        .specs_buffer = specs_buffer,
        .hb_tansformer = try hb.init(allocator),
        .hb_data = hb.TransformData.init(allocator),
        .font_cache = std.AutoHashMap(u64, *x11.XftFont).init(allocator),
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

    const pattern = x11.FcPatternDuplicate(self.font.*.pattern);
    defer x11.FcPatternDestroy(pattern);

    // Remove existing size
    _ = x11.FcPatternDel(pattern, x11.FC_PIXEL_SIZE);
    _ = x11.FcPatternDel(pattern, x11.FC_SIZE);

    // Add new size
    _ = x11.FcPatternAddInteger(pattern, x11.FC_PIXEL_SIZE, @intCast(size));

    const new_font = x11.XftFontOpenPattern(self.window.dpy, pattern);
    if (new_font == null) return; // Failed to load

    // Update successful, close old fonts and replace
    x11.XftFontClose(self.window.dpy, self.font);
    if (self.font_italic != self.font) x11.XftFontClose(self.window.dpy, self.font_italic);
    if (self.font_bold != self.font) x11.XftFontClose(self.window.dpy, self.font_bold);
    if (self.font_italic_bold != self.font) x11.XftFontClose(self.window.dpy, self.font_italic_bold);

    self.font = new_font.?;
    self.current_font_size = size;

    // Reload variants
    // Italic
    const italic_pattern = x11.FcPatternDuplicate(pattern);
    _ = x11.FcPatternDel(italic_pattern, x11.FC_SLANT);
    _ = x11.FcPatternAddInteger(italic_pattern, x11.FC_SLANT, x11.FC_SLANT_ITALIC);
    var font_italic = x11.XftFontOpenPattern(self.window.dpy, italic_pattern);
    if (font_italic == null) font_italic = self.font;
    self.font_italic = font_italic.?;

    // Bold
    const bold_pattern = x11.FcPatternDuplicate(pattern);
    _ = x11.FcPatternDel(bold_pattern, x11.FC_WEIGHT);
    _ = x11.FcPatternAddInteger(bold_pattern, x11.FC_WEIGHT, config.font.bold_weight);
    var font_bold = x11.XftFontOpenPattern(self.window.dpy, bold_pattern);
    if (font_bold == null) font_bold = self.font;
    self.font_bold = font_bold.?;

    // Italic Bold
    const ib_pattern = x11.FcPatternDuplicate(pattern);
    _ = x11.FcPatternDel(ib_pattern, x11.FC_SLANT);
    _ = x11.FcPatternAddInteger(ib_pattern, x11.FC_SLANT, x11.FC_SLANT_ITALIC);
    _ = x11.FcPatternDel(ib_pattern, x11.FC_WEIGHT);
    _ = x11.FcPatternAddInteger(ib_pattern, x11.FC_WEIGHT, config.font.bold_weight);
    var font_italic_bold = x11.XftFontOpenPattern(self.window.dpy, ib_pattern);
    if (font_italic_bold == null) font_italic_bold = self.font;
    self.font_italic_bold = font_italic_bold.?;

    // Recalculate metrics using the same method as init()
    const ascii_printable = " !\"#$%&'()*+,-./0123456789:;<=>?@ABCDEFGHIJKLMNOPQRSTUVWXYZ[\\]^_`abcdefghijklmnopqrstuvwxyz{|}~";
    var extents: x11.XGlyphInfo = undefined;
    x11.XftTextExtents8(self.window.dpy, self.font, ascii_printable, @intCast(ascii_printable.len), &extents);

    const avg_width = if (ascii_printable.len > 0) @as(f32, @floatFromInt(extents.xOff)) / @as(f32, @floatFromInt(ascii_printable.len)) else @as(f32, @floatFromInt(self.font.*.max_advance_width));
    self.char_width = @max(1, @as(u32, @intFromFloat(@ceil(avg_width * config.font.cwscale))));
    self.char_height = @max(1, @as(u32, @intFromFloat(@ceil(@as(f32, @floatFromInt(self.font.*.ascent + self.font.*.descent)) * config.font.chscale))));
    self.ascent = self.font.*.ascent;
    self.descent = self.font.*.descent;

    // Update window metrics
    self.window.cell_width = self.char_width;
    self.window.cell_height = self.char_height;

    // Clear font cache as old fonts are closed
    self.font_cache.clearRetainingCapacity();
}

pub fn deinit(self: *Renderer) void {
    x11.XftDrawDestroy(self.draw);
    if (self.font_italic != self.font) x11.XftFontClose(self.window.dpy, self.font_italic);
    if (self.font_bold != self.font) x11.XftFontClose(self.window.dpy, self.font_bold);
    if (self.font_italic_bold != self.font) x11.XftFontClose(self.window.dpy, self.font_italic_bold);
    x11.XftFontClose(self.window.dpy, self.font);
    for (self.fallbacks.items) |f| {
        x11.XftFontClose(self.window.dpy, f);
    }
    self.fallbacks.deinit(self.allocator);
    self.specs_buffer.deinit(self.allocator);
    // Free indexed colors
    for (0..300) |i| {
        if (self.loaded_colors[i]) {
            x11.XftColorFree(self.window.dpy, self.window.vis, self.window.cmap, &self.colors[i]);
        }
    }
    // Free truecolors
    var it = self.truecolor_cache.iterator();
    while (it.next()) |entry| {
        x11.XftColorFree(self.window.dpy, self.window.vis, self.window.cmap, entry.value_ptr);
    }
    self.truecolor_cache.deinit();

    // 清理 HarfBuzz 数据和缓存
    self.hb_data.deinit();
    self.hb_tansformer.deinit();
    self.font_cache.deinit();
}

fn getColor(self: *Renderer, term: *Terminal, index: u32) !x11.XftColor {
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
            x11.XftColorFree(self.window.dpy, self.window.vis, self.window.cmap, &entry.value);
        }

        var temp_color: x11.XftColor = undefined;
        const rgb = self.getIndexColor(term, index);
        const render_color = x11.XRenderColor{
            .red = @as(u16, rgb[0]) * 257,
            .green = @as(u16, rgb[1]) * 257,
            .blue = @as(u16, rgb[2]) * 257,
            .alpha = 0xFFFF,
        };
        if (x11.XftColorAllocValue(self.window.dpy, self.window.vis, self.window.cmap, &render_color, &temp_color) == 0) {
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
    var allocated = false;

    // Try allocating by name first (for config colors)
    var name: ?[:0]const u8 = null;

    if (index < 8) {
        name = config.colors.normal[index];
    } else if (index < 16) {
        name = config.colors.bright[index - 8];
    } else if (index == config.colors.default_foreground_idx) {
        if (term.default_fg == 0) name = config.colors.foreground;
    } else if (index == config.colors.default_background_idx) {
        if (term.default_bg == 0) name = config.colors.background;
    } else if (index == config.colors.default_cursor_idx) {
        if (term.default_cs == 0) name = config.colors.cursor;
    } else if (index == config.colors.reverse_cursor_idx) {
        if (term.default_rev_cs == 0) name = config.colors.cursor_text;
    }

    if (name) |n| {
        if (x11.XftColorAllocName(self.window.dpy, self.window.vis, self.window.cmap, n, &self.colors[index]) != 0) {
            allocated = true;
        } else {
            std.log.warn("Failed to allocate color by name: {s}", .{n});
        }
    }

    if (!allocated) {
        // Map index to RGB
        const rgb = self.getIndexColor(term, index);
        const render_color = x11.XRenderColor{
            .red = @as(u16, rgb[0]) * 257,
            .green = @as(u16, rgb[1]) * 257,
            .blue = @as(u16, rgb[2]) * 257,
            .alpha = 0xFFFF,
        };

        if (x11.XftColorAllocValue(self.window.dpy, self.window.vis, self.window.cmap, &render_color, &self.colors[index]) == 0) {
            return error.ColorAllocFailed;
        }
    }

    self.loaded_colors[index] = true;
    return self.colors[index];
}

fn getIndexColor(self: *Renderer, term: *Terminal, index: u32) [3]u8 {
    _ = self;

    // 24 位真彩色 (0xFFRRGGBB 格式)
    if (index >= 0x10000000) {
        const r = @as(u8, @truncate((index >> 16) & 0xFF));
        const g = @as(u8, @truncate((index >> 8) & 0xFF));
        const b = @as(u8, @truncate(index & 0xFF));
        return .{ r, g, b };
    }

    // 256 色调色板 (0-255)
    if (index < 256) {
        return u32ToRgb(term.palette[index]);
    }

    // 光标颜色
    if (index == config.colors.default_cursor_idx) return u32ToRgb(term.default_cs);
    // 反转光标颜色
    if (index == config.colors.reverse_cursor_idx) return u32ToRgb(term.default_rev_cs);
    // 前景色
    if (index == config.colors.default_foreground_idx) return u32ToRgb(term.default_fg);
    // 背景色
    if (index == config.colors.default_background_idx) return u32ToRgb(term.default_bg);

    // 默认白色
    return .{ 0xFF, 0xFF, 0xFF };
}

fn getFontForGlyph(self: *Renderer, u: u21, attr: types.GlyphAttr) *x11.XftFont {
    // Check cache first
    const key = (@as(u64, u) << 16) | @as(u16, @bitCast(attr));
    if (self.font_cache.get(key)) |cached_font| {
        return cached_font;
    }

    var f = self.font;
    const use_bold = attr.bold and !config.draw.disable_bold_font;

    if (use_bold and attr.italic) {
        f = self.font_italic_bold;
    } else if (use_bold) {
        f = self.font_bold;
    } else if (attr.italic) {
        f = self.font_italic;
    }

    // 调试：当使用粗体字体时记录日志（只记录部分 ASCII 字符以避免过多日志）
    // if (attr.bold and u < 128) {
    //     std.log.warn("getFontForGlyph: char={u} ({c}), bold={any}, italic={any}, use_bold={any}, font={*}, font_bold={*}, is_bold_font={any}", .{u, @as(u8, @truncate(u)), attr.bold, attr.italic, use_bold, f, self.font_bold, f == self.font_bold});
    // }

    if (x11.XftCharExists(self.window.dpy, f, u) != 0) {
        self.font_cache.put(key, f) catch {};
        return f;
    }

    for (self.fallbacks.items) |fb| {
        if (x11.XftCharExists(self.window.dpy, fb, u) != 0) {
            self.font_cache.put(key, fb) catch {};
            return fb;
        }
    }

    // Dynamic fallback via FontConfig
    const fc_charset = x11.FcCharSetCreate();
    defer x11.FcCharSetDestroy(fc_charset);
    if (x11.FcCharSetAddChar(fc_charset, u) == 0) {
        self.font_cache.put(key, f) catch {};
        return f;
    }

    const pattern = x11.FcPatternDuplicate(self.font.pattern);
    if (pattern == null) {
        self.font_cache.put(key, f) catch {};
        return f;
    }
    defer x11.FcPatternDestroy(pattern);

    _ = x11.FcPatternDel(pattern, x11.FC_CHARSET);
    if (x11.FcPatternAddCharSet(pattern, x11.FC_CHARSET, fc_charset) == 0) {
        self.font_cache.put(key, f) catch {};
        return f;
    }

    // Add style attributes
    if (attr.italic) {
        _ = x11.FcPatternDel(pattern, x11.FC_SLANT);
        _ = x11.FcPatternAddInteger(pattern, x11.FC_SLANT, x11.FC_SLANT_ITALIC);
    }
    if (attr.bold and !config.draw.disable_bold_font) {
        _ = x11.FcPatternDel(pattern, x11.FC_WEIGHT);
        _ = x11.FcPatternAddInteger(pattern, x11.FC_WEIGHT, config.font.bold_weight);
    }

    _ = x11.FcConfigSubstitute(null, pattern, x11.FcMatchPattern);
    _ = x11.XftDefaultSubstitute(self.window.dpy, self.window.screen, pattern);

    var result: x11.FcResult = undefined;
    const match = x11.FcFontMatch(null, pattern, &result);

    if (match) |m| {
        const font_open = x11.XftFontOpenPattern(self.window.dpy, m);
        if (font_open) |new_font| {
            if (x11.XftCharExists(self.window.dpy, new_font, u) != 0) {
                self.fallbacks.append(self.allocator, new_font) catch {
                    x11.XftFontClose(self.window.dpy, new_font);
                    self.font_cache.put(key, f) catch {};
                    return f;
                };
                self.font_cache.put(key, new_font) catch {};
                return new_font;
            }
            x11.XftFontClose(self.window.dpy, new_font);
        } else {
            x11.FcPatternDestroy(m);
        }
    }

    self.font_cache.put(key, f) catch {};
    return f;
}

pub fn render(self: *Renderer, term: *Terminal, selector: *Selector) !?x11.XRectangle {
    if (term.screen == null) return null;

    // Default background color
    var default_bg = try self.getColor(term, config.colors.default_background_idx);

    const hborder = @as(i32, @intCast(self.window.hborder_px));
    const vborder = @as(i32, @intCast(self.window.vborder_px));
    const grid_w = @as(i32, @intCast(term.col)) * @as(i32, @intCast(self.char_width));
    const grid_h = @as(i32, @intCast(term.row)) * @as(i32, @intCast(self.char_height));

    // 清除四周多余区域及边框
    // 1. 顶部区域
    if (vborder > 0)
        x11.XftDrawRect(self.draw, &default_bg, 0, 0, @intCast(self.window.width), @intCast(vborder));
    // 2. 底部区域
    const bottom_y = vborder + grid_h;
    if (bottom_y < @as(i32, @intCast(self.window.height))) {
        x11.XftDrawRect(self.draw, &default_bg, 0, bottom_y, @intCast(self.window.width), @intCast(@as(i32, @intCast(self.window.height)) - bottom_y));
    }
    // 3. 左侧区域
    if (hborder > 0)
        x11.XftDrawRect(self.draw, &default_bg, 0, vborder, @intCast(hborder), @intCast(grid_h));
    // 4. 右侧区域
    const right_x = hborder + grid_w;
    if (right_x < @as(i32, @intCast(self.window.width))) {
        x11.XftDrawRect(self.draw, &default_bg, right_x, vborder, @intCast(@as(i32, @intCast(self.window.width)) - right_x), @intCast(grid_h));
    }

    var min_y: ?usize = null;
    var max_y: ?usize = null;

    // Iterate over rows
    // std.log.debug("Rendering... rows={d} cols={d}", .{term.row, term.col});
    for (0..term.row) |y| {
        // Determine which line to draw
        const line_data = term.getVisibleLine(y);

        // 脏标记检查逻辑优化：
        // 只有在非滚动查看状态且没有活动的文本选择时，才通过脏标记跳过渲染。
        // 在备用屏幕 (vi/btop) 下，脏标记仍然是有效的，因为 Parser 同样会正确设置 dirty 标志。
        if (term.scroll == 0 and term.selection.mode == .idle) {
            if (term.dirty) |dirty| {
                if (y < dirty.len and !dirty[y]) continue;
            }
        }

        // Update dirty range
        if (min_y == null) min_y = y;
        max_y = y;

        const y_pos = @as(i32, @intCast(y * self.char_height)) + vborder;

        // Clear the dirty grid row with default background
        x11.XftDrawRect(self.draw, &default_bg, hborder, y_pos, @intCast(grid_w), @intCast(self.char_height));

        // 绘制所有字符
        try self.drawLine(line_data[0..@min(term.col, line_data.len)], 0, y, @min(term.col, line_data.len), term, selector);

        if (term.dirty) |dirty| {
            dirty[y] = false;
        }
    }

    if (min_y) |min| {
        const max = max_y orelse min;

        var rect = x11.XRectangle{
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

pub fn renderCursor(self: *Renderer, term: *Terminal) !void {
    if (term.mode.hide_cursor) return;

    const cx = term.cursor.x;
    const cy = term.cursor.y;

    if (cx >= term.col or cy >= term.row) return;

    const hborder = @as(i32, @intCast(self.window.hborder_px));
    const vborder = @as(i32, @intCast(self.window.vborder_px));
    const x_pos = @as(i32, @intCast(cx * self.char_width)) + hborder;
    const screen_y = if (term.scroll > 0 and !term.mode.alt_screen) @as(isize, @intCast(cy)) - @as(isize, @intCast(term.scroll)) else @as(isize, @intCast(cy));
    if (screen_y < 0 or screen_y >= @as(isize, @intCast(term.row))) return;
    const y_pos = @as(i32, @intCast(screen_y)) * @as(i32, @intCast(self.char_height)) + vborder;

    if (config.cursor.blink_interval_ms == 0) {
        self.cursor_blink_state = true;
    }

    var style = term.cursor_style;

    // Force hollow cursor when window is not focused
    if (!term.mode.focused) {
        style = .steady_st_cursor;
    }

    const is_blinking_style = style.shouldBlink();

    // 如果是闪烁样式且当前在不可见阶段，则不绘制
    // 但是：如果窗口失去焦点，光标应该始终可见（使用 steady 样式）
    if (is_blinking_style and !self.cursor_blink_state) {
        return;
    }

    const screen = term.screen;
    var glyph = Glyph{};
    if (screen) |scr| {
        if (cy < scr.len and cx < scr[cy].len) {
            glyph = scr[cy][cx];
        }
    }

    var cursor_fg_idx: u32 = config.colors.default_background_idx;
    var cursor_bg_idx: u32 = config.colors.default_cursor_idx;

    if (term.mode.reverse) {
        cursor_bg_idx = config.colors.reverse_cursor_idx;
        cursor_fg_idx = config.colors.default_cursor_idx;
    }

    var draw_col = try self.getColor(term, cursor_bg_idx);

    const is_wide = glyph.attr.wide;
    const cursor_width = if (is_wide) self.char_width * 2 else self.char_width;

    switch (style) {
        .blinking_block, .blinking_block_default => { // blinking block
            x11.XftDrawRect(self.draw, &draw_col, x_pos, y_pos, @intCast(cursor_width), @intCast(self.char_height));
            if (glyph.codepoint != ' ' and glyph.codepoint != 0) {
                var fg = try self.getColor(term, cursor_fg_idx);
                const codepoint = @as(u32, glyph.codepoint);
                const font = self.getFontForGlyph(glyph.codepoint, glyph.attr);

                var utf8_buf: [4]u8 = undefined;
                const len = try unicode.encode(@intCast(codepoint), &utf8_buf);

                var char_x = x_pos;
                if (is_wide) {
                    var glyph_extents: x11.XGlyphInfo = undefined;
                    x11.XftTextExtentsUtf8(self.window.dpy, font, &utf8_buf, @intCast(len), &glyph_extents);
                    const glyph_width = @as(i32, glyph_extents.xOff);
                    const offset_x = @divTrunc(@as(i32, @intCast(cursor_width)) - glyph_width, 2);
                    char_x += offset_x;
                }
                x11.XftDrawStringUtf8(self.draw, &fg, font, char_x, y_pos + self.ascent, &utf8_buf, @intCast(len));
            }
        },
        .steady_block => { // steady block
            x11.XftDrawRect(self.draw, &draw_col, x_pos, y_pos, @intCast(cursor_width), @intCast(self.char_height));
            if (glyph.codepoint != ' ' and glyph.codepoint != 0) {
                var fg = try self.getColor(term, cursor_fg_idx);
                const codepoint = @as(u32, glyph.codepoint);
                const font = self.getFontForGlyph(glyph.codepoint, glyph.attr);

                var utf8_buf: [4]u8 = undefined;
                const len = try unicode.encode(@intCast(codepoint), &utf8_buf);

                var char_x = x_pos;
                if (is_wide) {
                    var glyph_extents: x11.XGlyphInfo = undefined;
                    x11.XftTextExtentsUtf8(self.window.dpy, font, &utf8_buf, @intCast(len), &glyph_extents);
                    const glyph_width = @as(i32, glyph_extents.xOff);
                    const offset_x = @divTrunc(@as(i32, @intCast(cursor_width)) - glyph_width, 2);
                    char_x += offset_x;
                }
                x11.XftDrawStringUtf8(self.draw, &fg, font, char_x, y_pos + self.ascent, &utf8_buf, @intCast(len));
            }
        },
        .blinking_underline => { // blinking underline
            const thickness = config.cursor.thickness;
            const y_line = y_pos + @as(i32, @intCast(self.char_height)) - @as(i32, @intCast(thickness));
            x11.XftDrawRect(self.draw, &draw_col, x_pos, y_line, @intCast(cursor_width), thickness);
        },
        .steady_underline => { // steady underline
            const thickness = config.cursor.thickness;
            const y_line = y_pos + @as(i32, @intCast(self.char_height)) - @as(i32, @intCast(thickness));
            x11.XftDrawRect(self.draw, &draw_col, x_pos, y_line, @intCast(cursor_width), thickness);
        },
        .blinking_bar => { // blinking bar
            const thickness = config.cursor.thickness;
            x11.XftDrawRect(self.draw, &draw_col, x_pos, y_pos, thickness, @intCast(self.char_height));
        },
        .steady_bar => { // steady bar
            const thickness = config.cursor.thickness;
            x11.XftDrawRect(self.draw, &draw_col, x_pos, y_pos, thickness, @intCast(self.char_height));
        },
        .blinking_st_cursor, .steady_st_cursor => { // st cursor (hollow box)
            const thickness = config.cursor.thickness;
            x11.XftDrawRect(self.draw, &draw_col, x_pos, y_pos, @intCast(cursor_width), thickness);
            x11.XftDrawRect(self.draw, &draw_col, x_pos, y_pos + @as(i32, @intCast(self.char_height)) - @as(i32, @intCast(thickness)), @intCast(cursor_width), thickness);
            x11.XftDrawRect(self.draw, &draw_col, x_pos, y_pos, thickness, @intCast(self.char_height));
            x11.XftDrawRect(self.draw, &draw_col, x_pos + @as(i32, @intCast(cursor_width)) - @as(i32, @intCast(thickness)), y_pos, thickness, @intCast(self.char_height));
            if (glyph.codepoint != ' ' and glyph.codepoint != 0) {
                var fg = try self.getColor(term, cursor_fg_idx);
                const codepoint = @as(u32, glyph.codepoint);
                const font = self.getFontForGlyph(glyph.codepoint, glyph.attr);

                var utf8_buf: [4]u8 = undefined;
                const len = try unicode.encode(@intCast(codepoint), &utf8_buf);

                var char_x = x_pos;
                if (is_wide) {
                    var glyph_extents: x11.XGlyphInfo = undefined;
                    x11.XftTextExtentsUtf8(self.window.dpy, font, &utf8_buf, @intCast(len), &glyph_extents);
                    const glyph_width = @as(i32, glyph_extents.xOff);
                    const offset_x = @divTrunc(@as(i32, @intCast(cursor_width)) - glyph_width, 2);
                    char_x += offset_x;
                }
                x11.XftDrawStringUtf8(self.draw, &fg, font, char_x, y_pos + self.ascent, &utf8_buf, @intCast(len));
            }
        },
    }
}

// Helper to draw a filled arc for boxdraw corners using XFillPolygon
fn drawBoxArc(self: *Renderer, x: i32, y: i32, w: i32, h: i32, s: i32, color: *x11.XftColor, corner_radius: i32, quadrant: u2) !void {
    const s_f = @as(f32, @floatFromInt(s));
    const r_f = @as(f32, @floatFromInt(corner_radius));
    const cx = @as(f32, @floatFromInt(x)) + @as(f32, @floatFromInt(w)) / 2.0;
    const cy = @as(f32, @floatFromInt(y)) + @as(f32, @floatFromInt(h)) / 2.0;

    const r_out = r_f + s_f / 2.0;
    const r_in = @max(0.0, r_f - s_f / 2.0);

    var xc: f32 = 0;
    var yc: f32 = 0;
    var start_angle: f32 = 0;

    // Quadrant 0: ╭ (LD+LR) -> Center @ Bottom Right (Relative to arc center), Arc is Top-Left
    // Quadrant 1: ╮ (LD+LL) -> Center @ Bottom Left, Arc is Top-Right
    // Quadrant 2: ╯ (LU+LL) -> Center @ Top Left, Arc is Bottom-Right
    // Quadrant 3: ╰ (LU+LR) -> Center @ Top Right, Arc is Bottom-Left
    switch (quadrant) {
        0 => { // ╭
            xc = cx + r_f;
            yc = cy + r_f;
            start_angle = 90;
        },
        1 => { // ╮
            xc = cx - r_f;
            yc = cy + r_f;
            start_angle = 0;
        },
        2 => { // ╯
            xc = cx - r_f;
            yc = cy - r_f;
            start_angle = 270;
        },
        3 => { // ╰
            xc = cx + r_f;
            yc = cy - r_f;
            start_angle = 180;
        },
    }

    const steps = 16;
    var points: [32]x11.XPoint = undefined;
    const angle_step = 90.0 / @as(f32, @floatFromInt(steps - 1));

    // Outer arc
    for (0..steps) |i| {
        const theta_deg = start_angle + @as(f32, @floatFromInt(i)) * angle_step;
        const theta = theta_deg * std.math.pi / 180.0;
        points[i] = .{
            .x = @intFromFloat(xc + r_out * @cos(theta)),
            .y = @intFromFloat(yc - r_out * @sin(theta)), // Y is down
        };
    }

    // Inner arc (reverse)
    for (0..steps) |i| {
        const theta_deg = start_angle + (90.0 - @as(f32, @floatFromInt(i)) * angle_step);
        const theta = theta_deg * std.math.pi / 180.0;
        points[steps + i] = .{
            .x = @intFromFloat(xc + r_in * @cos(theta)),
            .y = @intFromFloat(yc - r_in * @sin(theta)),
        };
    }

    const gc = x11.XCreateGC(self.window.dpy, self.window.buf, 0, null);
    defer _ = x11.XFreeGC(self.window.dpy, gc);
    _ = x11.XSetForeground(self.window.dpy, gc, color.pixel);
    _ = x11.XFillPolygon(self.window.dpy, self.window.buf, gc, &points, points.len, x11.Nonconvex, x11.CoordModeOrigin);
}

fn drawBoxChar(self: *Renderer, u: u21, x: i32, y: i32, w: i32, h: i32, color: *x11.XftColor, bg_color: *x11.XftColor, bold: bool) !void {
    const data = boxdraw.BoxDraw.getDrawData(u);
    if (data == 0) return;
    const mwh = @min(w, h);
    const base_s = @max(1, @divTrunc(mwh + 4, 8));
    const is_bold = (bold and config.draw.boxdraw_bold) and mwh >= 6;
    const s: i32 = if (is_bold) @max(base_s + 1, @divTrunc(3 * base_s + 1, 2)) else base_s;
    const w2_line = @divTrunc(w - s + 1, 2);
    const h2_line = @divTrunc(h - s + 1, 2);
    const midx = x + w2_line;
    const midy = y + h2_line;
    const cat = data & ~@as(u16, boxdraw_data.BOLD | 0xff);
    if (cat == boxdraw_data.TRIANGLE) {
        const type_ = data & 0xFF;

        // 目标：宽度和高度都是 1 个字符的宽度 (W x W 正方形区域)
        const side = @as(f32, @floatFromInt(w));
        const target_w = side;
        const target_h = side;

        // 居中于原始 WxH 区域 (通常 H > W)
        const tx = @as(f32, @floatFromInt(x)) + (@as(f32, @floatFromInt(w)) - target_w) / 2.0;
        const ty = @as(f32, @floatFromInt(y)) + (@as(f32, @floatFromInt(h)) - target_h) / 2.0;

        var points: [3]x11.XPoint = undefined;
        switch (type_) {
            1 => { // Up ▲
                points[0] = x11.XPoint{ .x = @intFromFloat(tx + target_w / 2.0), .y = @intFromFloat(ty) };
                points[1] = x11.XPoint{ .x = @intFromFloat(tx), .y = @intFromFloat(ty + target_h) };
                points[2] = x11.XPoint{ .x = @intFromFloat(tx + target_w), .y = @intFromFloat(ty + target_h) };
            },
            2 => { // Down ▼
                points[0] = x11.XPoint{ .x = @intFromFloat(tx), .y = @intFromFloat(ty) };
                points[1] = x11.XPoint{ .x = @intFromFloat(tx + target_w), .y = @intFromFloat(ty) };
                points[2] = x11.XPoint{ .x = @intFromFloat(tx + target_w / 2.0), .y = @intFromFloat(ty + target_h) };
            },
            3 => { // Left ◀
                points[0] = x11.XPoint{ .x = @intFromFloat(tx + target_w), .y = @intFromFloat(ty) };
                points[1] = x11.XPoint{ .x = @intFromFloat(tx + target_w), .y = @intFromFloat(ty + target_h) };
                points[2] = x11.XPoint{ .x = @intFromFloat(tx), .y = @intFromFloat(ty + target_h / 2.0) };
            },
            4 => { // Right ▶
                points[0] = x11.XPoint{ .x = @intFromFloat(tx), .y = @intFromFloat(ty) };
                points[1] = x11.XPoint{ .x = @intFromFloat(tx), .y = @intFromFloat(ty + target_h) };
                points[2] = x11.XPoint{ .x = @intFromFloat(tx + target_w), .y = @intFromFloat(ty + target_h / 2.0) };
            },
            else => {
                std.log.debug("未知的三角形绘制类型: {d}", .{type_});
                return;
            },
        }

        const gc = x11.XCreateGC(self.window.dpy, self.window.buf, 0, null);
        defer _ = x11.XFreeGC(self.window.dpy, gc);
        _ = x11.XSetForeground(self.window.dpy, gc, color.pixel);
        _ = x11.XFillPolygon(self.window.dpy, self.window.buf, gc, &points, 3, x11.Convex, x11.CoordModeOrigin);
        return;
    }
    if (cat == boxdraw_data.BRAILLE) {
        const bw1 = @divTrunc(w + 1, 2);
        const bh1 = @divTrunc(h + 2, 4);
        const bh2 = @divTrunc(h + 1, 2);
        const bh3 = @divTrunc(3 * h + 2, 4);
        if (data & 1 != 0) x11.XftDrawRect(self.draw, color, x, y, @intCast(bw1), @intCast(bh1));
        if (data & 2 != 0) x11.XftDrawRect(self.draw, color, x, y + bh1, @intCast(bw1), @intCast(bh2 - bh1));
        if (data & 4 != 0) x11.XftDrawRect(self.draw, color, x, y + bh2, @intCast(bw1), @intCast(bh3 - bh2));
        if (data & 8 != 0) x11.XftDrawRect(self.draw, color, x + bw1, y, @intCast(w - bw1), @intCast(bh1));
        if (data & 16 != 0) x11.XftDrawRect(self.draw, color, x + bw1, y + bh1, @intCast(w - bw1), @intCast(bh2 - bh1));
        if (data & 32 != 0) x11.XftDrawRect(self.draw, color, x + bw1, y + bh1, @intCast(w - bw1), @intCast(bh2 - bh1)); // This was likely a placeholder
        if (data & 32 != 0) x11.XftDrawRect(self.draw, color, x + bw1, y + bh2, @intCast(w - bw1), @intCast(bh3 - bh2));
        if (data & 64 != 0) x11.XftDrawRect(self.draw, color, x, y + bh3, @intCast(bw1), @intCast(h - bh3));
        if (data & 128 != 0) x11.XftDrawRect(self.draw, color, x + bw1, y + bh3, @intCast(w - bw1), @intCast(h - bh3));
        return;
    }
    if (cat == boxdraw_data.BLOCK_DOWN) {
        const d = @divTrunc(@as(i32, @intCast(data & 0xFF)) * h + 4, 8);
        x11.XftDrawRect(self.draw, color, x, y + d, @intCast(w), @intCast(h - d));
        return;
    } else if (cat == boxdraw_data.BLOCK_UPPER) {
        const d = @divTrunc(@as(i32, @intCast(data & 0xFF)) * h + 4, 8);
        x11.XftDrawRect(self.draw, color, x, y, @intCast(w), @intCast(d));
        return;
    } else if (cat == boxdraw_data.BLOCK_LEFT) {
        const d = @divTrunc(@as(i32, @intCast(data & 0xFF)) * w + 4, 8);
        x11.XftDrawRect(self.draw, color, x, y, @intCast(d), @intCast(h));
        return;
    } else if (cat == boxdraw_data.BLOCK_RIGHT) {
        const d = @divTrunc(@as(i32, @intCast(data & 0xFF)) * w + 4, 8);
        x11.XftDrawRect(self.draw, color, x + d, y, @intCast(w - d), @intCast(h));
        return;
    }
    if (cat == boxdraw_data.BLOCK_QUADRANT) {
        const qw = @divTrunc(w + 1, 2);
        const qh = @divTrunc(h + 1, 2);
        if (data & boxdraw_data.TOP_LEFT != 0) x11.XftDrawRect(self.draw, color, x, y, @intCast(qw), @intCast(qh));
        if (data & boxdraw_data.TOP_RIGHT != 0) x11.XftDrawRect(self.draw, color, x + qw, y, @intCast(w - qw), @intCast(qh));
        if (data & boxdraw_data.BOTTOM_LEFT != 0) x11.XftDrawRect(self.draw, color, x, y + qh, @intCast(qw), @intCast(h - qh));
        if (data & boxdraw_data.BOTTOM_RIGHT != 0) x11.XftDrawRect(self.draw, color, x + qw, y + qh, @intCast(w - qw), @intCast(h - qh));
        return;
    }
    if (data & boxdraw_data.BLOCK_SHADE != 0) {
        const d = @as(u16, @intCast(data & 0xFF));
        var xrc = x11.XRenderColor{
            .red = @intCast(@divTrunc(@as(u32, color.*.color.red) * d + @as(u32, bg_color.*.color.red) * (4 - d) + 2, 4)),
            .green = @intCast(@divTrunc(@as(u32, color.*.color.green) * d + @as(u32, bg_color.*.color.green) * (4 - d) + 2, 4)),
            .blue = @intCast(@divTrunc(@as(u32, color.*.color.blue) * d + @as(u32, bg_color.*.color.blue) * (4 - d) + 2, 4)),
            .alpha = 0xFFFF,
        };
        var xfc: x11.XftColor = undefined;
        if (x11.XftColorAllocValue(self.window.dpy, self.window.vis, self.window.cmap, &xrc, &xfc) != 0) {
            x11.XftDrawRect(self.draw, &xfc, x, y, @intCast(w), @intCast(h));
            x11.XftColorFree(self.window.dpy, self.window.vis, self.window.cmap, &xfc);
        }
        return;
    }
    if (data & (boxdraw_data.LINE | boxdraw_data.ARC) != 0) {
        const light = data & (boxdraw_data.LIGHT_LEFT | boxdraw_data.LIGHT_UP | boxdraw_data.LIGHT_RIGHT | boxdraw_data.LIGHT_DOWN);
        const double_ = data & (boxdraw_data.DOUBLE_LEFT | boxdraw_data.DOUBLE_UP | boxdraw_data.DOUBLE_RIGHT | boxdraw_data.DOUBLE_DOWN);
        if (light != 0) {
            const arc = data & boxdraw_data.ARC != 0;
            const multi_light = light & (light -% 1) != 0;
            const multi_double = double_ & (double_ -% 1) != 0;

            // // 圆角半径：尽可能大，最大为 min(w,h)/2
            // const corner_radius: i32 = @divTrunc(@min(w, h), 2);
            // const d_len: i32 = if (arc) -(@as(i32, @intFromFloat(@as(f32, @floatFromInt(corner_radius)) + @as(f32, @floatFromInt(s)) / 2.0))) else if (multi_double and !multi_light) -s else 0;
            const d_len: i32 = if (arc or (multi_double and !multi_light)) -s else 0;

            // // 先绘制直线（如果有）
            if (data & boxdraw_data.LIGHT_LEFT != 0) x11.XftDrawRect(self.draw, color, x, midy, @intCast(w2_line + s + d_len), @intCast(s));
            if (data & boxdraw_data.LIGHT_UP != 0) x11.XftDrawRect(self.draw, color, midx, y, @intCast(s), @intCast(h2_line + s + d_len));
            if (data & boxdraw_data.LIGHT_RIGHT != 0) x11.XftDrawRect(self.draw, color, midx - d_len, midy, @intCast(w - w2_line + d_len), @intCast(s));
            if (data & boxdraw_data.LIGHT_DOWN != 0) x11.XftDrawRect(self.draw, color, midx, midy - d_len, @intCast(s), @intCast(h - h2_line + d_len));

            // // 绘制圆角弧
            // if (arc and corner_radius > 0) {
            //     // ╭ (U+256D, BDA+LD+LR): 左上圆角，边线向下和向右
            //     if ((data & boxdraw_data.LD) != 0 and (data & boxdraw_data.LR) != 0) {
            //         try self.drawBoxArc(x, y, w, h, s, color, corner_radius, 0);
            //     }
            //     // ╮ (U+256E, BDA+LD+LL): 右上圆角，边线向下和向左
            //     if ((data & boxdraw_data.LD) != 0 and (data & boxdraw_data.LL) != 0) {
            //         try self.drawBoxArc(x, y, w, h, s, color, corner_radius, 1);
            //     }
            //     // ╯ (U+256F, BDA+LU+LL): 右下圆角，边线向上和向左
            //     if ((data & boxdraw_data.LU) != 0 and (data & boxdraw_data.LL) != 0) {
            //         try self.drawBoxArc(x, y, w, h, s, color, corner_radius, 2);
            //     }
            //     // ╰ (U+2570, BDA+LU+LR): 左下圆角，边线向上和向右
            //     if ((data & boxdraw_data.LU) != 0 and (data & boxdraw_data.LR) != 0) {
            //         try self.drawBoxArc(x, y, w, h, s, color, corner_radius, 3);
            //     }
            // }
        }
        if (double_ != 0) {
            const dl = data & boxdraw_data.DOUBLE_LEFT != 0;
            const du = data & boxdraw_data.DOUBLE_UP != 0;
            const dr = data & boxdraw_data.DOUBLE_RIGHT != 0;
            const dd = data & boxdraw_data.DOUBLE_DOWN != 0;
            if (dl) {
                const p: i32 = if (dd) -s else 0;
                const n: i32 = if (du) -s else if (dd) s else 0;
                x11.XftDrawRect(self.draw, color, x, midy + s, @intCast(w2_line + s + p), @intCast(s));
                x11.XftDrawRect(self.draw, color, x, midy - s, @intCast(w2_line + s + n), @intCast(s));
            }
            if (du) {
                const p: i32 = if (dl) -s else 0;
                const n: i32 = if (dr) -s else if (dl) s else 0;
                x11.XftDrawRect(self.draw, color, midx - s, y, @intCast(s), @intCast(h2_line + s + p));
                x11.XftDrawRect(self.draw, color, midx + s, y, @intCast(s), @intCast(h2_line + s + n));
            }
            if (dr) {
                const p: i32 = if (du) -s else 0;
                const n: i32 = if (dd) -s else if (du) s else 0;
                x11.XftDrawRect(self.draw, color, midx - p, midy - s, @intCast(w - w2_line + p), @intCast(s));
                x11.XftDrawRect(self.draw, color, midx - n, midy + s, @intCast(w - w2_line + n), @intCast(s));
            }
            if (dd) {
                const p: i32 = if (dr) -s else 0;
                const n: i32 = if (dl) -s else if (dr) s else 0;
                x11.XftDrawRect(self.draw, color, midx + s, midy - p, @intCast(s), @intCast(h - h2_line + p));
                x11.XftDrawRect(self.draw, color, midx - s, midy - n, @intCast(s), @intCast(h - h2_line + n));
            }
        }
    }
}

pub fn resize(self: *Renderer) void {
    x11.XftDrawChange(self.draw, self.window.buf);
}

pub fn resetCursorBlink(self: *Renderer) void {
    self.cursor_blink_state = true;
    self.last_blink_time = std.time.milliTimestamp();
}

/// 立即重置光标闪烁为可见状态，用于用户输入时确保光标始终可见
pub fn forceCursorVisible(self: *Renderer) void {
    self.cursor_blink_state = true;
    self.last_blink_time = std.time.milliTimestamp();
}

// 批量绘制一行字符
// 类似 st 的 xdrawline 函数
fn drawLine(self: *Renderer, line: []Glyph, x1: usize, y1: usize, x2: usize, term: *Terminal, selector: *Selector) !void {
    if (x1 >= x2) return;

    self.specs_buffer.clearRetainingCapacity();

    var i: usize = 0;
    var ox: usize = x1;
    var base = line[x1];
    var current_reverse = false;

    for (x1..x2) |x| {
        if (x >= line.len) break;
        var new = line[x];
        if (new.attr.wide_dummy) continue;

        const selected = selector.isSelected(term, x, y1);
        if (selected) {
            new.attr.reverse = !new.attr.reverse;
        }

        const effective_reverse = new.attr.reverse != term.mode.reverse;

        if (i > 0 and (current_reverse != effective_reverse or base.attrsCmp(new))) {
            try self.drawGlyphFontSpecs(line, ox, y1, term, i, current_reverse);
            i = 0;
        }

        if (i == 0) {
            ox = x;
            base = new;
            current_reverse = effective_reverse;
        }
        i += 1;
    }

    if (i > 0) {
        try self.drawGlyphFontSpecs(line, ox, y1, term, i, current_reverse);
    }
}

// 绘制一批相同属性的字符
fn drawGlyphFontSpecs(self: *Renderer, line: []Glyph, x1: usize, y: usize, term: *Terminal, len: usize, reverse: bool) !void {
    if (len == 0) return;

    self.specs_buffer.clearRetainingCapacity();
    try self.specs_buffer.ensureTotalCapacity(self.allocator, len);

    const hborder = @as(i32, @intCast(self.window.hborder_px));
    const vborder = @as(i32, @intCast(self.window.vborder_px));
    const winy = @as(i32, @intCast(y)) * @as(i32, @intCast(self.char_height)) + vborder;

    const base = line[x1];
    var fg_idx = base.fg;
    var bg_idx = base.bg;

    // 粗体处理：根据配置选择使用粗体字体或亮色模拟
    if (base.attr.bold and config.draw.disable_bold_font) {
        // 传统方案：使用亮色代替粗体（st 的默认行为）
        if (fg_idx < 8) {
            fg_idx += 8;
        } else if (fg_idx == config.colors.default_foreground_idx) {
            fg_idx = 15;
        }
    }

    if (reverse) {
        const temp = fg_idx;
        fg_idx = bg_idx;
        bg_idx = temp;
    }

    var fg_col = try self.getColor(term, fg_idx);
    var bg_col = try self.getColor(term, bg_idx);

    // 计算总宽度用于绘制背景、下划线和删除线
    var total_width: usize = 0;
    var x: usize = x1;
    var i: usize = 0;
    while (i < len and x < line.len) {
        if (line[x].attr.wide_dummy) {
            x += 1;
            continue;
        }

        if (line[x].attr.wide) {
            total_width += 2;
        } else {
            total_width += 1;
        }

        i += 1;
        x += 1;

        if (line[x - 1].attr.wide and x < line.len and line[x].attr.wide_dummy) {
            x += 1;
        }
    }

    const hborder_x = @as(i32, @intCast(x1 * self.char_width)) + hborder;

    // 绘制背景
    x11.XftDrawRect(self.draw, &bg_col, hborder_x, winy, @intCast(total_width * self.char_width), @intCast(self.char_height));

    // boxdraw 使用特殊绘制，直接调用 drawBoxChar()
    if (base.attr.boxdraw) {
        x = x1;
        i = 0;
        while (i < len and x < line.len) {
            const glyph = line[x];
            if (glyph.attr.wide_dummy) {
                x += 1;
                continue;
            }

            const x_pos = @as(i32, @intCast(x * self.char_width)) + hborder;
            const y_pos = winy;

            // 直接调用 drawBoxChar 绘制几何图形，不使用字体
            try self.drawBoxChar(glyph.codepoint, x_pos, y_pos, @intCast(self.char_width), @intCast(self.char_height), &fg_col, &bg_col, base.attr.bold);

            x += 1;
            i += 1;
        }
    } else {
        // 使用 HarfBuzz 进行文本整形（支持 ligatures）
        const font = self.getFontForGlyph(base.codepoint, base.attr);
        // 传递完整切片（包含 dummy），长度由 x - x1 决定
        self.hb_tansformer.transform(&self.hb_data, font, line[x1..x], 0, len);

        const winx = @as(f32, @floatFromInt(hborder_x));
        const yp = @as(f32, @floatFromInt(winy + self.ascent));
        var xp = winx;
        var cluster_xp = xp;
        var cluster_yp = yp;
        const runewidth = if (base.attr.wide) @as(f32, @floatFromInt(self.char_width)) * 2.0 else @as(f32, @floatFromInt(self.char_width));

        if (self.hb_data.count > 0) {
            for (0..self.hb_data.count) |code_idx| {
                const idx = self.hb_data.glyphs[code_idx].cluster;

                if (line[x1 + idx].attr.wide_dummy) continue;

                if (code_idx > 0 and idx != self.hb_data.glyphs[code_idx - 1].cluster) {
                    // 智能步进：结合逻辑宽度 (runewidth) 和视觉宽度 (cluster_xp - xp)
                    // 这解决了当 wcwidth=1 但字体实际宽度为 2 时的覆盖问题
                    const visual_advance = cluster_xp - xp;
                    const cells = @round(visual_advance / @as(f32, @floatFromInt(self.char_width)));
                    const grid_advance = @max(1.0, cells) * @as(f32, @floatFromInt(self.char_width));

                    xp += @max(runewidth, grid_advance);
                    cluster_xp = xp;
                    cluster_yp = yp;
                }

                if (self.hb_data.glyphs[code_idx].codepoint != 0) {
                    const x_offset = @as(f32, @floatFromInt(self.hb_data.positions[code_idx].x_offset)) / 64.0;
                    const y_offset = -@as(f32, @floatFromInt(self.hb_data.positions[code_idx].y_offset)) / 64.0;
                    const x_advance = @as(f32, @floatFromInt(self.hb_data.positions[code_idx].x_advance)) / 64.0;
                    const y_advance = @as(f32, @floatFromInt(self.hb_data.positions[code_idx].y_advance)) / 64.0;

                    self.specs_buffer.appendAssumeCapacity(.{
                        .font = font,
                        .glyph = self.hb_data.glyphs[code_idx].codepoint,
                        .x = @as(i16, @intFromFloat(cluster_xp + x_offset)),
                        .y = @as(i16, @intFromFloat(cluster_yp + y_offset)),
                    });

                    cluster_xp += x_advance;
                    cluster_yp += y_advance;
                } else {
                    // HarfBuzz 无法在当前字体中找到字形，尝试回退字体
                    const glyph = line[x1 + idx];
                    const fallback_font = self.getFontForGlyph(glyph.codepoint, glyph.attr);
                    const glyph_index = x11.XftCharIndex(self.window.dpy, fallback_font, glyph.codepoint);

                    if (glyph_index != 0) {
                        self.specs_buffer.appendAssumeCapacity(.{
                            .font = fallback_font,
                            .glyph = glyph_index,
                            .x = @as(i16, @intFromFloat(cluster_xp)),
                            .y = @as(i16, @intFromFloat(cluster_yp)),
                        });
                    }
                }
            }
        }
    }

    // 批量绘制字形
    if (self.specs_buffer.items.len > 0) {
        x11.XftDrawGlyphFontSpec(self.draw, &fg_col, self.specs_buffer.items.ptr, @intCast(self.specs_buffer.items.len));
    }

    // 绘制下划线
    if (base.attr.underline or base.url_id > 0) {
        const thickness = config.cursor.thickness;
        const underline_y = winy + self.ascent + 1;

        if (base.ustyle <= 0 or base.ustyle == 1) {
            x11.XftDrawRect(self.draw, &fg_col, hborder_x, underline_y, @intCast(total_width * self.char_width), thickness);
        } else if (base.ustyle == 2) {
            x11.XftDrawRect(self.draw, &fg_col, hborder_x, underline_y, @intCast(total_width * self.char_width), thickness);
            x11.XftDrawRect(self.draw, &fg_col, hborder_x, underline_y + thickness * 2, @intCast(total_width * self.char_width), thickness);
        }
    }

    // 绘制删除线
    if (base.attr.struck) {
        x11.XftDrawRect(self.draw, &fg_col, hborder_x, winy + @divTrunc(self.ascent * 2, 3), @intCast(total_width * self.char_width), 1);
    }

    if (base.attr.underline and base.ustyle == 3) {
        const underline_y = winy + self.ascent + 1;
        const width = @as(i32, @intCast(total_width * self.char_width));

        // 创建 GC 用于绘制线条
        var gc_values = std.mem.zeroes(x11.XGCValues);
        gc_values.foreground = fg_col.pixel;
        gc_values.line_width = @intCast(config.cursor.thickness); // 与下划线保持一致
        gc_values.line_style = x11.LineSolid;
        gc_values.cap_style = x11.CapButt;

        const gc = x11.XCreateGC(
            self.window.dpy,
            x11.XftDrawDrawable(self.draw),
            x11.GCForeground | x11.GCLineWidth | x11.GCLineStyle | x11.GCCapStyle,
            &gc_values,
        );
        defer _ = x11.XFreeGC(self.window.dpy, gc);

        // 计算波浪线参数
        const wave_height = 3; // 波浪线高度（像素）
        const wave_width = @as(i32, @intCast(@max(2, @divTrunc(self.char_width, 2)))); // 每个波浪的宽度

        // 计算波浪线点数
        const num_waves = @divTrunc(width, wave_width) + 2;
        const num_points = @as(usize, @intCast(num_waves * 2));

        // 使用栈内存优化：绝大多数情况使用固定缓冲区
        // 2048 个点足以覆盖约 8000 像素宽度的波浪线 (假设波浪宽 8px)
        var stack_points: [2048]x11.XPoint = undefined;
        var heap_points: ?[]x11.XPoint = null;
        defer if (heap_points) |ptr| term.allocator.free(ptr);

        var points_slice: []x11.XPoint = undefined;

        if (num_points <= stack_points.len) {
            points_slice = stack_points[0..num_points];
        } else {
            heap_points = try term.allocator.alloc(x11.XPoint, num_points);
            points_slice = heap_points.?;
        }

        var point_idx: usize = 0;
        var current_x: i32 = hborder_x; // 从字符起始位置开始
        const end_x = hborder_x + width;
        var rising = true; // 当前是上升还是下降

        // 生成波浪线点
        while (current_x < end_x and point_idx < num_points) {
            // 波浪线在 underline_y 到 underline_y + wave_height 之间波动
            // 最高点对齐到下划线位置
            const y_offset: i32 = if (rising)
                0 // 最高点，对齐到下划线
            else
                wave_height; // 最低点

            // 当前点
            points_slice[point_idx] = .{
                .x = @as(c_short, @intCast(current_x)),
                .y = @as(c_short, @intCast(underline_y + y_offset)),
            };
            point_idx += 1;

            // 下一个点
            current_x += wave_width;
            if (current_x > end_x) current_x = end_x;

            points_slice[point_idx] = .{
                .x = @as(c_short, @intCast(current_x)),
                .y = @as(c_short, @intCast(underline_y + (wave_height - y_offset))), // 相反方向
            };
            point_idx += 1;

            rising = !rising; // 切换方向
        }

        // 绘制波浪线
        if (point_idx > 1) {
            _ = x11.XDrawLines(
                self.window.dpy,
                x11.XftDrawDrawable(self.draw),
                gc,
                points_slice.ptr,
                @intCast(point_idx),
                x11.CoordModeOrigin,
            );
        }
    }

    // 重置 HarfBuzz 数据
    self.hb_data.reset();
}

fn u32ToRgb(color: u32) [3]u8 {
    return .{
        @truncate((color >> 16) & 0xFF),
        @truncate((color >> 8) & 0xFF),
        @truncate(color & 0xFF),
    };
}
