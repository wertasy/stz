//! SDL2 + FreeType 字符渲染系统
//!
//! 渲染器负责将终端屏幕缓冲区中的字符绘制到 SDL2 窗口上。

const std = @import("std");
const stz = @import("stz");

const sdl2 = stz.c.sdl2;
const ft = stz.c.ft;
const fc = stz.c.fc;
const hb = stz.c.hb;

const types = stz.types;
const config = stz.Config;
const Selector = stz.Selector;
const Terminal = stz.Terminal;
const unicode = stz.unicode;
const harfbuzz = stz.harfbuzz;
const boxdraw = @import("boxdraw.zig");
const boxdraw_data = @import("boxdraw_data.zig");

const Window = @import("window.zig");
const Glyph = types.Glyph;
const TextureAtlas = @import("texture_atlas.zig").TextureAtlas;
const GlyphInfo = @import("texture_atlas.zig").GlyphInfo;

pub const RendererError = error{
    FreeTypeInitFailed,
    FontLoadFailed,
    SurfaceCreateFailed,
    AtlasInitFailed,
};

const Renderer = @This();

window: *Window,
allocator: std.mem.Allocator,

// FreeType 库和字体
ft_lib: ft.FT_Library,
font: ft.FT_Face,
font_italic: ft.FT_Face,
font_bold: ft.FT_Face,
font_italic_bold: ft.FT_Face,
fallbacks: std.ArrayList(ft.FT_Face),

// 字符尺寸
char_width: u32,
char_height: u32,
ascent: i32,
descent: i32,

// 字体缩放
current_font_size: u32,
original_font_size: u32,

// 光标闪烁状态
cursor_blink_state: bool = true,
last_blink_time: i64 = 0,

// 颜色缓存 (使用 SDL_Color)
colors: [300]sdl2.SDL_Color,
loaded_colors: [300]bool,
truecolor_cache: std.AutoHashMap(u32, sdl2.SDL_Color),

// 字体缓存：key = (u21 << 32 | u16 attr), value = ft.FT_Face
font_cache: std.AutoHashMap(u64, ft.FT_Face),

// 纹理图集：存储所有字形，减少纹理切换
atlas: ?TextureAtlas = null,

// 图集尺寸配置（可调整）
atlas_size: u32 = 4096,
atlas_cell_size: u32,

// 性能统计
draw_call_count: u32 = 0,
last_frame_time_us: u64 = 0,
frame_count: u64 = 0,
last_fps_log_time: i64 = 0,

// HarfBuzz 文本整形引擎（用于连字支持）
hb_engine: harfbuzz.Self,
hb_transform_data: harfbuzz.TransformData,

pub fn init(window: *Window, allocator: std.mem.Allocator) !Renderer {
    // 初始化 FreeType 库
    var ft_lib: ft.FT_Library = undefined;
    if (ft.FT_Init_FreeType(&ft_lib) != 0) {
        std.log.err("FreeType 初始化失败", .{});
        return error.FreeTypeInitFailed;
    }

    // 加载主字体
    const font_path = try findFontPath(allocator, config.font.name);
    defer allocator.free(font_path);
    std.log.info("加载字体: {s}", .{font_path});

    var font: ft.FT_Face = undefined;
    if (ft.FT_New_Face(ft_lib, font_path.ptr, 0, &font) != 0) {
        std.log.err("字体加载失败: {s}", .{font_path});
        _ = ft.FT_Done_FreeType(ft_lib);
        return error.FontLoadFailed;
    }

    // 设置字体大小
    const font_size = config.font.size;
    if (ft.FT_Set_Pixel_Sizes(font, 0, @intCast(font_size)) != 0) {
        std.log.err("设置字体大小失败", .{});
        _ = ft.FT_Done_Face(font);
        _ = ft.FT_Done_FreeType(ft_lib);
        return error.FontLoadFailed;
    }

    const ascii_printable = " !\"#$%&'()*+,-./0123456789:;<=>?@ABCDEFGHIJKLMNOPQRSTUVWXYZ[\\ ]^_`abcdefghijklmnopqrstuvwxyz{|}~";

    var total_advance: i64 = 0;
    for (ascii_printable) |c| {
        _ = ft.FT_Load_Char(font, c, ft.FT_LOAD_RENDER);
        const glyph = font.*.glyph;
        const advance = glyph.*.advance.x >> 6;
        if (advance > 0) {
            total_advance += advance;
        }
    }

    const avg_width = if (ascii_printable.len > 0)
        @as(f32, @floatFromInt(total_advance)) / @as(f32, @floatFromInt(ascii_printable.len))
    else
        @as(f32, @floatFromInt(font.*.max_advance_width));

    const char_width = @max(1, @as(u32, @intFromFloat(@ceil(avg_width * config.font.cwscale))));

    const size_metrics = font.*.size.*.metrics;
    const char_height = @max(1, @as(u32, @intFromFloat(@ceil(@as(f32, @floatFromInt(size_metrics.height >> 6)) * config.font.chscale))));

    const ascent = @as(i32, @intCast(size_metrics.ascender >> 6));
    const descent = @as(i32, @intCast(size_metrics.descender >> 6));

    const font_italic = blk: {
        if (config.font.italic) {
            break :blk loadFontVariant(allocator, ft_lib, config.font.name, null, 100, font_size) catch |err| {
                std.log.warn("加载斜体字体失败，使用主字体: {}", .{err});
                break :blk font;
            };
        }
        break :blk font;
    };

    const font_bold = blk: {
        if (config.font.bold) {
            break :blk loadFontVariant(allocator, ft_lib, config.font.name, config.font.bold_weight, null, font_size) catch |err| {
                std.log.warn("加载粗体字体失败，使用主字体: {}", .{err});
                break :blk font;
            };
        }
        break :blk font;
    };

    const font_italic_bold = blk: {
        if (config.font.bold and config.font.italic) {
            break :blk loadFontVariant(allocator, ft_lib, config.font.name, config.font.bold_weight, 100, font_size) catch |err| {
                std.log.warn("加载斜粗体字体失败，使用主字体: {}", .{err});
                break :blk font;
            };
        }
        break :blk font;
    };

    var fallbacks = try std.ArrayList(ft.FT_Face).initCapacity(allocator, 4);
    errdefer {
        for (fallbacks.items) |f| {
            _ = ft.FT_Done_Face(f);
        }
        fallbacks.deinit(allocator);
    }

    for (config.font.fallback_fonts) |fallback_name| {
        const fallback_path = findFontPath(allocator, fallback_name) catch |err| {
            std.log.warn("无法找到回退字体: {s} ({})", .{ fallback_name, err });
            continue;
        };

        var fallback_face: ft.FT_Face = undefined;
        if (ft.FT_New_Face(ft_lib, fallback_path.ptr, 0, &fallback_face) != 0) {
            std.log.warn("加载回退字体失败: {s}", .{fallback_path});
            allocator.free(fallback_path);
            continue;
        }

        // 设置字体大小（对于彩色 emoji 字体可能失败，使用默认大小）
        if (ft.FT_Set_Pixel_Sizes(fallback_face, 0, @intCast(font_size)) != 0) {
            // 某些彩色 emoji 字体（如 Noto Color Emoji）使用 CBDT 格式
            // FT_Set_Pixel_Sizes 会失败，但字体仍然可用（使用默认大小）
            std.log.info("回退字体使用默认大小: {s}", .{fallback_path});
            // 不返回错误，继续使用字体
        }

        try fallbacks.append(allocator, fallback_face);
        std.log.info("加载回退字体: {s}", .{fallback_path});
        allocator.free(fallback_path);
    }

    window.cell_width = char_width;
    window.cell_height = char_height;

    // 初始化 HarfBuzz 文本整形引擎
    const hb_engine = harfbuzz.init(allocator) catch |err| {
        std.log.err("HarfBuzz 初始化失败: {}", .{err});
        _ = ft.FT_Done_FreeType(ft_lib);
        return error.FreeTypeInitFailed;
    };

    return Renderer{
        .window = window,
        .allocator = allocator,
        .ft_lib = ft_lib,
        .font = font,
        .font_italic = font_italic,
        .font_bold = font_bold,
        .font_italic_bold = font_italic_bold,
        .fallbacks = fallbacks,
        .char_width = char_width,
        .char_height = char_height,
        .ascent = ascent,
        .descent = descent,
        .current_font_size = font_size,
        .original_font_size = font_size,
        .cursor_blink_state = true,
        .last_blink_time = std.time.milliTimestamp(),
        .colors = undefined,
        .loaded_colors = [_]bool{false} ** 300,
        .truecolor_cache = std.AutoHashMap(u32, sdl2.SDL_Color).init(allocator),
        .font_cache = std.AutoHashMap(u64, ft.FT_Face).init(allocator),
        .atlas = null,
        .atlas_size = 4096,
        .atlas_cell_size = config.draw.atlas_cell_size,
        .hb_engine = hb_engine,
        .hb_transform_data = harfbuzz.TransformData.init(allocator),
    };
}

fn findFontPath(allocator: std.mem.Allocator, font_name: []const u8) ![:0]const u8 {
    return findFontPathWithStyle(allocator, font_name, null, null);
}

fn findFontPathWithStyle(allocator: std.mem.Allocator, font_name: []const u8, weight: ?i32, slant: ?i32) ![:0]const u8 {
    if (fc.FcInit() == 0) {
        std.log.err("FontConfig 初始化失败", .{});
        return error.FontLoadFailed;
    }
    defer fc.FcFini();

    const pattern = fc.FcNameParse(@ptrCast(font_name.ptr));
    defer fc.FcPatternDestroy(pattern);

    if (pattern == null) {
        std.log.err("无法解析字体名称: {s}", .{font_name});
        return error.FontLoadFailed;
    }

    if (weight) |w| {
        _ = fc.FcPatternAddInteger(pattern, fc.FC_WEIGHT, w);
    }
    if (slant) |s| {
        _ = fc.FcPatternAddInteger(pattern, fc.FC_SLANT, s);
    }

    _ = fc.FcConfigSubstitute(null, pattern, fc.FcMatchPattern);
    _ = fc.FcDefaultSubstitute(pattern);

    var result: fc.FcResult = undefined;
    const match = fc.FcFontMatch(null, pattern, &result);

    if (match == null) {
        std.log.err("未找到匹配的字体: {s}", .{font_name});
        return error.FontLoadFailed;
    }
    defer fc.FcPatternDestroy(match);

    var file_path: [*c]u8 = undefined;
    if (fc.FcPatternGetString(match, fc.FC_FILE, 0, &file_path) != fc.FcResultMatch) {
        std.log.err("无法获取字体文件路径", .{});
        return error.FontLoadFailed;
    }

    const path = std.mem.span(file_path);
    return allocator.dupeZ(u8, path);
}

fn loadFontVariant(allocator: std.mem.Allocator, ft_lib: ft.FT_Library, font_name: []const u8, weight: ?i32, slant: ?i32, font_size: u32) !ft.FT_Face {
    const font_path = try findFontPathWithStyle(allocator, font_name, weight, slant);
    defer allocator.free(font_path);

    std.log.info("加载字体变体: {s} (weight: {any}, slant: {any})", .{ font_path, weight, slant });

    var face: ft.FT_Face = undefined;
    if (ft.FT_New_Face(ft_lib, font_path.ptr, 0, &face) != 0) {
        std.log.err("字体变体加载失败: {s}", .{font_path});
        return error.FontLoadFailed;
    }

    if (ft.FT_Set_Pixel_Sizes(face, 0, @intCast(font_size)) != 0) {
        std.log.err("设置字体变体大小失败", .{});
        _ = ft.FT_Done_Face(face);
        return error.FontLoadFailed;
    }

    return face;
}

pub fn deinit(self: *Renderer) void {
    if (self.font_italic_bold != self.font) _ = ft.FT_Done_Face(self.font_italic_bold);
    if (self.font_bold != self.font) _ = ft.FT_Done_Face(self.font_bold);
    if (self.font_italic != self.font) _ = ft.FT_Done_Face(self.font_italic);
    _ = ft.FT_Done_Face(self.font);

    for (self.fallbacks.items) |f| {
        _ = ft.FT_Done_Face(f);
    }
    self.fallbacks.deinit(self.allocator);

    _ = ft.FT_Done_FreeType(self.ft_lib);

    self.truecolor_cache.deinit();
    self.font_cache.deinit();

    if (self.atlas) |*atlas| {
        atlas.deinit();
    }

    // 清理 HarfBuzz 资源
    self.hb_transform_data.deinit();
    self.hb_engine.deinit();
}

fn getColor(self: *Renderer, term: *Terminal, index: u32) !sdl2.SDL_Color {
    if (index >= 0x10000000) {
        if (self.truecolor_cache.get(index)) |color| {
            return color;
        }

        // 缓存淘汰策略：简单清空以防止无限增长
        // 增加缓存大小到 2048，降低清空频率，减少重复颜色查找
        if (self.truecolor_cache.count() > 2048) {
            self.truecolor_cache.clearRetainingCapacity();
        }

        const rgb = self.getIndexColor(term, index);
        const color = sdl2.SDL_Color{
            .r = rgb[0],
            .g = rgb[1],
            .b = rgb[2],
            .a = 255,
        };
        try self.truecolor_cache.put(index, color);
        return color;
    }

    if (index >= 300) return error.FontLoadFailed;

    if (self.loaded_colors[index]) {
        return self.colors[index];
    }

    const rgb = self.getIndexColor(term, index);
    self.colors[index] = sdl2.SDL_Color{
        .r = rgb[0],
        .g = rgb[1],
        .b = rgb[2],
        .a = 255,
    };
    self.loaded_colors[index] = true;
    return self.colors[index];
}

fn getIndexColor(self: *Renderer, term: *Terminal, index: u32) [3]u8 {
    _ = self;
    if (index >= 0x10000000) {
        const r = @as(u8, @truncate((index >> 16) & 0xFF));
        const g = @as(u8, @truncate((index >> 8) & 0xFF));
        const b = @as(u8, @truncate(index & 0xFF));
        return .{ r, g, b };
    }
    if (index < 256) {
        return u32ToRgb(term.palette[index]);
    }
    if (index == config.colors.default_cursor_idx) return u32ToRgb(term.default_cs);
    if (index == config.colors.reverse_cursor_idx) return u32ToRgb(term.default_rev_cs);
    if (index == config.colors.default_foreground_idx) return u32ToRgb(term.default_fg);
    if (index == config.colors.default_background_idx) return u32ToRgb(term.default_bg);
    return .{ 0xFF, 0xFF, 0xFF };
}

fn u32ToRgb(color: u32) [3]u8 {
    return .{
        @as(u8, @truncate((color >> 16) & 0xFF)),
        @as(u8, @truncate((color >> 8) & 0xFF)),
        @as(u8, @truncate(color & 0xFF)),
    };
}

fn getFontForGlyph(self: *Renderer, u: u21, attr: types.GlyphAttr) ft.FT_Face {
    const key = (@as(u64, u) << 32) | @as(u16, @bitCast(attr));
    if (self.font_cache.get(key)) |cached_font| {
        return cached_font;
    }

    var face = self.font;
    const use_bold = attr.bold and !config.draw.disable_bold_font;

    if (use_bold and attr.italic) {
        face = self.font_italic_bold;
    } else if (use_bold) {
        face = self.font_bold;
    } else if (attr.italic) {
        face = self.font_italic;
    }

    if (ft.FT_Get_Char_Index(face, u) != 0) {
        self.font_cache.put(key, face) catch {};
        return face;
    }

    // 检查是否是 emoji，添加调试日志
    const is_emoji = (u >= 0x1F000 and u <= 0x1FAFF);
    if (is_emoji) {
        std.log.warn("Emoji 字符 U+{X} 未在主字体中找到，搜索 fallback 字体", .{u});
    }

    for (self.fallbacks.items, 0..) |fallback, idx| {
        const glyph_index = ft.FT_Get_Char_Index(fallback, u);
        if (glyph_index != 0) {
            if (is_emoji) {
                std.log.warn("Emoji U+{X} 在 fallback[{}] 中找到 (index: {})", .{ u, idx, glyph_index });
            }
            self.font_cache.put(key, fallback) catch {};
            return fallback;
        }
    }

    if (is_emoji) {
        std.log.err("Emoji U+{X} 未在任何 fallback 字体中找到，将显示为方块或空白", .{u});
    }

    self.font_cache.put(key, face) catch {};
    return face;
}

fn ensureAtlas(self: *Renderer, renderer: *sdl2.SDL_Renderer) !void {
    if (self.atlas == null) {
        std.log.info("初始化纹理图集: {}x{}, 单元格={}", .{
            self.atlas_size,
            self.atlas_size,
            self.atlas_cell_size,
        });
        self.atlas = try TextureAtlas.init(
            renderer,
            self.atlas_size,
            self.atlas_size,
            self.atlas_cell_size,
            self.allocator,
        );
    }
}

/// 绘制单个字符（核心渲染函数）- 使用纹理图集优化
/// 优化：不在此函数内设置颜色调制，由调用者统一处理以减少状态切换
fn drawTextGlyph(self: *Renderer, renderer: *sdl2.SDL_Renderer, codepoint: u21, x: i32, y: i32, attr: types.GlyphAttr) !void {
    try self.ensureAtlas(renderer);
    const atlas = &self.atlas.?;
    const face = self.getFontForGlyph(codepoint, attr);

    const glyph_info = atlas.getGlyphInfo(codepoint, attr) orelse blk: {
        const info = atlas.addGlyph(renderer, face, codepoint, attr) catch |err| {
            if (err == error.AtlasFull) {
                atlas.clear(renderer);
                break :blk atlas.addGlyph(renderer, face, codepoint, attr) catch |err2| {
                    std.log.err("重新添加字形失败: {}", .{err2});
                    return;
                };
            }
            return;
        };
        break :blk info;
    };

    if (glyph_info.width == 0 or glyph_info.height == 0) return;

    const src_rect = sdl2.SDL_Rect{
        .x = glyph_info.x,
        .y = glyph_info.y,
        .w = glyph_info.width,
        .h = glyph_info.height,
    };

    // 检测 Powerline 字符（U+E0B0-E0C0），使用垂直居中对齐
    const is_powerline = (codepoint >= 0xE0B0 and codepoint <= 0xE0C0) or
        (codepoint >= 0xE0FA and codepoint <= 0xE0FF);

    // 计算垂直位置：Powerline 字符使用居中对齐，其他字符使用基线对齐
    const y_offset = if (is_powerline)
        // 垂直居中：(单元格高度 - 字形高度) / 2
        y + @divFloor(@as(i32, @intCast(self.char_height - @as(u32, glyph_info.height))), 2) - 1
    else
        // 基线对齐
        y - glyph_info.bitmap_top + self.ascent;

    const dst_rect = sdl2.SDL_Rect{
        .x = x + glyph_info.bitmap_left,
        .y = y_offset,
        .w = glyph_info.width,
        .h = glyph_info.height,
    };

    if (sdl2.SDL_RenderCopy(renderer, atlas.texture, &src_rect, &dst_rect) != 0) {
        std.log.err("渲染字形失败: {s}", .{sdl2.SDL_GetError()});
    }
    self.draw_call_count += 1;
}

/// 使用 HarfBuzz 字形索引绘制字形（支持连字）
fn drawLigatureGlyph(self: *Renderer, renderer: *sdl2.SDL_Renderer, face: ft.FT_Face, glyph_index: u32, codepoint: u21, x: i32, y: i32, x_offset: i32, attr: types.GlyphAttr) !void {
    try self.ensureAtlas(renderer);
    const atlas = &self.atlas.?;

    // 加载字形（使用 FreeType 字形索引）
    if (glyph_index == 0) {
        // HarfBuzz 无法在当前字体中找到对应字形，回退到普通渲染（支持备选字体）
        try self.drawTextGlyph(renderer, codepoint, x, y, attr);
        return;
    }

    if (ft.FT_Load_Glyph(face, glyph_index, ft.FT_LOAD_RENDER | ft.FT_LOAD_TARGET_NORMAL | ft.FT_LOAD_FORCE_AUTOHINT) != 0) {
        return;
    }

    const glyph = face.*.glyph;
    const bitmap = &glyph.*.bitmap;

    if (bitmap.width > atlas.cell_size or bitmap.rows > atlas.cell_size) {
        return;
    }

    // 检测 Powerline 字符（U+E0B0-E0C0，U+E0FA-E0FF），使用垂直居中对齐
    const is_powerline = (codepoint >= 0xE0B0 and codepoint <= 0xE0C0) or
        (codepoint >= 0xE0FA and codepoint <= 0xE0FF);

    // 添加到图集
    const glyph_info = atlas.addGlyphWithLigatureIndex(face, glyph_index, attr) catch |err| {
        if (err == error.AtlasFull) {
            atlas.clear(renderer);
            const info = atlas.addGlyphWithLigatureIndex(face, glyph_index, attr) catch |err2| {
                std.log.err("重新添加连字字形失败: {}", .{err2});
                return;
            };
            return self.renderLigatureGlyphInternal(renderer, atlas, info, x, y, x_offset, is_powerline);
        }
        return;
    };

    if (glyph_info.width == 0 or glyph_info.height == 0) return;

    try self.renderLigatureGlyphInternal(renderer, atlas, glyph_info, x, y, x_offset, is_powerline);
}

fn renderLigatureGlyphInternal(self: *Renderer, renderer: *sdl2.SDL_Renderer, atlas: *const TextureAtlas, glyph_info: GlyphInfo, x: i32, y: i32, x_offset: i32, is_powerline: bool) !void {
    const src_rect = sdl2.SDL_Rect{
        .x = glyph_info.x,
        .y = glyph_info.y,
        .w = glyph_info.width,
        .h = glyph_info.height,
    };

    // 计算垂直位置：Powerline 字符使用居中对齐，其他字符使用基线对齐
    const y_offset = if (is_powerline)
        // 垂直居中：(单元格高度 - 字形高度) / 2
        y + @divFloor(@as(i32, @intCast(self.char_height - @as(u32, glyph_info.height))), 2)
    else
        // 基线对齐
        y - glyph_info.bitmap_top + self.ascent;

    const dst_rect = sdl2.SDL_Rect{
        .x = x + glyph_info.bitmap_left + x_offset,
        .y = y_offset,
        .w = glyph_info.width,
        .h = glyph_info.height,
    };

    if (sdl2.SDL_RenderCopy(renderer, atlas.texture, &src_rect, &dst_rect) != 0) {
        std.log.err("渲染连字字形失败: {s}", .{sdl2.SDL_GetError()});
    }
    self.draw_call_count += 1;
}

pub fn render(self: *Renderer, term: *Terminal, selector: *Selector, include_cursor: bool) !?sdl2.SDL_Rect {
    const start_time = std.time.microTimestamp();
    self.draw_call_count = 0;

    if (term.screen == null) return null;
    const renderer = self.window.renderer;
    try self.ensureAtlas(renderer);

    if (self.window.texture) |tex| {
        if (sdl2.SDL_SetRenderTarget(renderer, tex) != 0) {
            std.log.err("设置渲染目标失败: {s}", .{sdl2.SDL_GetError()});
            return null;
        }
    } else return null;

    const default_bg = try self.getColor(term, config.colors.default_background_idx);
    const hborder = @as(i32, @intCast(self.window.hborder_px));
    const vborder = @as(i32, @intCast(self.window.vborder_px));
    const grid_w = @as(i32, @intCast(term.col)) * @as(i32, @intCast(self.char_width));
    const grid_h = @as(i32, @intCast(term.row)) * @as(i32, @intCast(self.char_height));

    // 清除边框
    _ = sdl2.SDL_SetRenderDrawColor(renderer, default_bg.r, default_bg.g, default_bg.b, 255);
    if (vborder > 0) {
        _ = sdl2.SDL_RenderFillRect(renderer, &sdl2.SDL_Rect{ .x = 0, .y = 0, .w = @intCast(self.window.width), .h = @intCast(vborder) });
        const bottom_y = vborder + grid_h;
        if (bottom_y < @as(i32, @intCast(self.window.height))) {
            _ = sdl2.SDL_RenderFillRect(renderer, &sdl2.SDL_Rect{ .x = 0, .y = bottom_y, .w = @intCast(self.window.width), .h = @intCast(@as(i32, @intCast(self.window.height)) - bottom_y) });
        }
    }
    if (hborder > 0) {
        _ = sdl2.SDL_RenderFillRect(renderer, &sdl2.SDL_Rect{ .x = 0, .y = vborder, .w = @intCast(hborder), .h = @intCast(grid_h) });
        const right_x = hborder + grid_w;
        if (right_x < @as(i32, @intCast(self.window.width))) {
            _ = sdl2.SDL_RenderFillRect(renderer, &sdl2.SDL_Rect{ .x = right_x, .y = vborder, .w = @intCast(@as(i32, @intCast(self.window.width)) - right_x), .h = @intCast(grid_h) });
        }
    }

    var min_y: ?usize = null;
    var max_y: ?usize = null;
    const has_selection = term.selection.mode != .idle;

    for (0..term.row) |y| {
        const line_data = term.getVisibleLine(y);
        if (term.scroll == 0 and !has_selection) {
            if (term.dirty) |dirty| {
                if (y < dirty.len and !dirty[y]) continue;
            }
        }

        if (min_y == null) min_y = y;
        max_y = y;

        const y_pos = @as(i32, @intCast(y * self.char_height)) + vborder;
        _ = sdl2.SDL_SetRenderDrawColor(renderer, default_bg.r, default_bg.g, default_bg.b, 255);
        _ = sdl2.SDL_RenderFillRect(renderer, &sdl2.SDL_Rect{ .x = hborder, .y = y_pos, .w = @intCast(grid_w), .h = @intCast(self.char_height) });

        var x: usize = 0;
        const line_len = @min(term.col, line_data.len);
        while (x < line_len) {
            const glyph = line_data[x];
            if (glyph.attr.wide_dummy) {
                x += 1;
                continue;
            }

            const selected = if (has_selection) selector.isSelected(term, x, y) else false;
            var effective_reverse = glyph.attr.reverse != term.mode.reverse;
            if (selected) effective_reverse = !effective_reverse;

            const bg_idx = if (effective_reverse) glyph.fg else glyph.bg;
            const bg_color = try self.getColor(term, bg_idx);
            const is_bold = glyph.attr.bold;
            const is_italic = glyph.attr.italic;

            const start_x = x;
            x += 1;

            while (x < line_len) {
                const next_glyph = line_data[x];
                const next_selected = if (has_selection) selector.isSelected(term, x, y) else false;
                var next_rev = next_glyph.attr.reverse != term.mode.reverse;
                if (next_selected) next_rev = !next_rev;
                const next_bg = if (next_rev) next_glyph.fg else next_glyph.bg;
                if (next_bg == bg_idx and next_glyph.attr.bold == is_bold and next_glyph.attr.italic == is_italic) {
                    x += 1;
                } else break;
            }

            const run_width = @as(u32, @intCast(x - start_x)) * self.char_width;

            _ = sdl2.SDL_SetRenderDrawColor(renderer, bg_color.r, bg_color.g, bg_color.b, 255);
            _ = sdl2.SDL_RenderFillRect(renderer, &sdl2.SDL_Rect{ .x = @as(i32, @intCast(start_x * self.char_width)) + hborder, .y = y_pos, .w = @intCast(run_width), .h = @intCast(self.char_height) });

            var last_fg: ?sdl2.SDL_Color = null;
            const atlas_tex = self.atlas.?.texture;

            // 获取此区域使用的字体面 (使用第一个字符作为参考)
            const face = self.getFontForGlyph(glyph.codepoint, glyph.attr);

            // 对此区域使用 HarfBuzz 进行文本整形以支持连字
            // 构建此区域的字形数组（跳过 wide_dummy）
            var ligature_glyphs = try std.ArrayList(types.Glyph).initCapacity(self.allocator, x - start_x);
            defer ligature_glyphs.deinit(self.allocator);

            var lx = start_x;
            while (lx < x) : (lx += 1) {
                const lg = line_data[lx];
                if (!lg.attr.wide_dummy) {
                    ligature_glyphs.appendAssumeCapacity(lg);
                }
            }

            // 如果有字符需要绘制
            if (ligature_glyphs.items.len > 0) {
                // 重置 HarfBuzz buffer 确保状态干净
                self.hb_transform_data.reset();

                // 使用 HarfBuzz 进行文本整形
                self.hb_engine.transform(&self.hb_transform_data, face, ligature_glyphs.items, 0, ligature_glyphs.items.len);

                const hb_glyphs = self.hb_transform_data.glyphs;
                defer self.hb_transform_data.reset();
                const hb_positions = self.hb_transform_data.positions;
                const hb_count = self.hb_transform_data.count;

                if (hb_glyphs != null and hb_positions != null and hb_count > 0) {
                    // 使用 HarfBuzz 整形结果进行渲染（支持连字）
                    // cluster 值是 ligature_glyphs 数组的连续索引
                    var lig_idx: usize = 0;
                    var cluster_valid = true;

                    while (lig_idx < hb_count) : (lig_idx += 1) {
                        // 获取 HarfBuzz 字形信息
                        const hb_glyph = hb_glyphs[lig_idx];
                        const hb_pos = hb_positions[lig_idx];
                        const cluster = hb_glyph.cluster;

                        // cluster 指向 ligature_glyphs 数组中的字符
                        if (cluster >= ligature_glyphs.items.len) {
                            // cluster 超出范围，使用普通渲染
                            cluster_valid = false;
                            break;
                        }

                        const lg = ligature_glyphs.items[cluster];

                        // 计算该字符在原始行中的位置（考虑前面的宽字符）
                        var orig_x = start_x;
                        for (0..cluster) |orig_idx| {
                            if (!ligature_glyphs.items[orig_idx].attr.wide) {
                                orig_x += 1;
                            } else {
                                orig_x += 2;
                            }
                        }

                        const l_sel = if (has_selection) selector.isSelected(term, orig_x, y) else false;
                        var l_rev = lg.attr.reverse != term.mode.reverse;
                        if (l_sel) l_rev = !l_rev;
                        const l_fg_idx = if (l_rev) lg.bg else lg.fg;
                        const l_fg = try self.getColor(term, l_fg_idx);

                        if (last_fg == null or last_fg.?.r != l_fg.r or last_fg.?.g != l_fg.g or last_fg.?.b != l_fg.b) {
                            _ = sdl2.SDL_SetTextureColorMod(atlas_tex, l_fg.r, l_fg.g, l_fg.b);
                            last_fg = l_fg;
                        }

                        // 绘制连字字形
                        if (lg.codepoint != ' ' and lg.codepoint != 0) {
                            // 检查是否是框线字符
                            if (config.draw.boxdraw and lg.attr.boxdraw and boxdraw.BoxDraw.isBoxDraw(lg.codepoint)) {
                                const cell_x = @as(i32, @intCast(orig_x * self.char_width)) + hborder;
                                try self.drawBoxChar(renderer, lg.codepoint, cell_x, y_pos, l_fg);
                            } else {
                                const x_offset = @as(i32, @intCast(hb_pos.x_offset)) >> 6;
                                const cell_x = @as(i32, @intCast(orig_x * self.char_width)) + hborder;
                                try self.drawLigatureGlyph(renderer, face, hb_glyph.codepoint, lg.codepoint, cell_x, y_pos, x_offset, lg.attr);
                            }
                        }
                    }

                    // 如果 cluster 无效，回退到普通渲染
                    if (!cluster_valid) {
                        lx = start_x;
                        while (lx < x) : (lx += 1) {
                            const dg = line_data[lx];
                            if (dg.attr.wide_dummy) continue;
                            const d_sel = if (has_selection) selector.isSelected(term, lx, y) else false;
                            var d_rev = dg.attr.reverse != term.mode.reverse;
                            if (d_sel) d_rev = !d_rev;
                            const fg_idx = if (d_rev) dg.bg else dg.fg;
                            const fg = try self.getColor(term, fg_idx);
                            if (last_fg == null or last_fg.?.r != fg.r or last_fg.?.g != fg.g or last_fg.?.b != fg.b) {
                                _ = sdl2.SDL_SetTextureColorMod(atlas_tex, fg.r, fg.g, fg.b);
                                last_fg = fg;
                            }
                            if (dg.codepoint != ' ' and dg.codepoint != 0) {
                                // 检查是否是框线字符
                                if (config.draw.boxdraw and dg.attr.boxdraw and boxdraw.BoxDraw.isBoxDraw(dg.codepoint)) {
                                    try self.drawBoxChar(renderer, dg.codepoint, @as(i32, @intCast(lx * self.char_width)) + hborder, y_pos, fg);
                                } else {
                                    try self.drawTextGlyph(renderer, dg.codepoint, @as(i32, @intCast(lx * self.char_width)) + hborder, y_pos, dg.attr);
                                }
                            }
                        }
                    }
                } else {
                    // 整形失败，回退到普通渲染
                    lx = start_x;
                    while (lx < x) : (lx += 1) {
                        const dg = line_data[lx];
                        if (dg.attr.wide_dummy) continue;
                        const d_sel = if (has_selection) selector.isSelected(term, lx, y) else false;
                        var d_rev = dg.attr.reverse != term.mode.reverse;
                        if (d_sel) d_rev = !d_rev;
                        const fg_idx = if (d_rev) dg.bg else dg.fg;
                        const fg = try self.getColor(term, fg_idx);
                        if (last_fg == null or last_fg.?.r != fg.r or last_fg.?.g != fg.g or last_fg.?.b != fg.b) {
                            _ = sdl2.SDL_SetTextureColorMod(atlas_tex, fg.r, fg.g, fg.b);
                            last_fg = fg;
                        }
                        if (dg.codepoint != ' ' and dg.codepoint != 0) {
                            // 检查是否是框线字符
                            if (config.draw.boxdraw and dg.attr.boxdraw and boxdraw.BoxDraw.isBoxDraw(dg.codepoint)) {
                                try self.drawBoxChar(renderer, dg.codepoint, @as(i32, @intCast(lx * self.char_width)) + hborder, y_pos, fg);
                            } else {
                                try self.drawTextGlyph(renderer, dg.codepoint, @as(i32, @intCast(lx * self.char_width)) + hborder, y_pos, dg.attr);
                            }
                        }
                    }
                }
            }
        }
        if (term.dirty) |dirty| dirty[y] = false;
    }

    if (min_y) |min| {
        const max = max_y orelse min;
        var rect = sdl2.SDL_Rect{ .x = 0, .y = @intCast(@as(i32, @intCast(min * self.char_height)) + vborder), .w = @intCast(self.window.width), .h = @intCast((max - min + 1) * self.char_height) };
        if (min == 0) {
            rect.y = 0;
            rect.h += @intCast(vborder);
        }
        if (max == term.row - 1) {
            const total_h = @as(i32, @intCast(self.window.height));
            if (total_h > rect.y + rect.h) rect.h += @intCast(total_h - (rect.y + rect.h));
        }
        if (include_cursor and !term.mode.hide_cursor) try self.renderCursorInternal(renderer, term);
        _ = sdl2.SDL_SetRenderTarget(renderer, null);
        self.last_frame_time_us = @intCast(std.time.microTimestamp() - start_time);
        self.frame_count += 1;
        const now = std.time.milliTimestamp();
        if (now - self.last_fps_log_time >= 1000) {
            self.last_fps_log_time = now;
        }
        return rect;
    }
    _ = sdl2.SDL_SetRenderTarget(renderer, null);
    return null;
}

fn renderCursorInternal(self: *Renderer, sdl_renderer: *sdl2.SDL_Renderer, term: *Terminal) !void {
    if (term.mode.hide_cursor) return;
    const cx = term.cursor.x;
    const cy = term.cursor.y;
    if (cx >= term.col or cy >= term.row) return;

    const hborder = @as(i32, @intCast(self.window.hborder_px));
    const vborder = @as(i32, @intCast(self.window.vborder_px));

    // 计算实际显示的行号（处理滚动）
    // stz 的 scroll 表示向上滚动的行数，内容向下移动
    const screen_y_idx = if (!term.mode.alt_screen)
        @as(isize, @intCast(cy)) - @as(isize, @intCast(term.scroll))
    else
        @as(isize, @intCast(cy));

    if (screen_y_idx < 0 or screen_y_idx >= @as(isize, @intCast(term.row))) return;

    const y_pos = @as(i32, @intCast(screen_y_idx)) * @as(i32, @intCast(self.char_height)) + vborder;

    if (config.cursor.blink_interval_ms != 0 and !self.cursor_blink_state and term.cursor_style.shouldBlink()) return;

    const style = if (!term.mode.focused) types.CursorStyle.steady_st_cursor else term.cursor_style;
    // 既然进入了此函数，term.screen 必然非 null
    var glyph = term.screen.?[cy][cx];
    var real_cx = cx;

    // 处理宽字符：如果光标在 wide_dummy 上，则回退到前一个单元格
    if (glyph.attr.wide_dummy) {
        if (cx > 0) {
            real_cx -= 1;
            glyph = term.screen.?[cy][real_cx];
        }
    }

    const x_pos_adjusted = @as(i32, @intCast(real_cx * self.char_width)) + hborder;

    const cursor_fg_idx: u32 = if (term.mode.reverse) config.colors.default_cursor_idx else config.colors.default_background_idx;
    const cursor_bg_idx: u32 = if (term.mode.reverse) config.colors.reverse_cursor_idx else config.colors.default_cursor_idx;

    const draw_col = try self.getColor(term, cursor_bg_idx);
    const cursor_width = if (glyph.attr.wide) self.char_width * 2 else self.char_width;

    _ = sdl2.SDL_SetRenderDrawColor(sdl_renderer, draw_col.r, draw_col.g, draw_col.b, 255);

    switch (style) {
        .blinking_block, .blinking_block_default, .steady_block => {
            _ = sdl2.SDL_RenderFillRect(sdl_renderer, &sdl2.SDL_Rect{ .x = x_pos_adjusted, .y = y_pos, .w = @intCast(cursor_width), .h = @intCast(self.char_height) });
            if (glyph.codepoint != ' ' and glyph.codepoint != 0) {
                const fg = try self.getColor(term, cursor_fg_idx);
                _ = sdl2.SDL_SetTextureColorMod(self.atlas.?.texture, fg.r, fg.g, fg.b);
                try self.drawTextGlyph(sdl_renderer, glyph.codepoint, x_pos_adjusted, y_pos, glyph.attr);
            }
        },
        .blinking_underline, .steady_underline => {
            _ = sdl2.SDL_RenderFillRect(sdl_renderer, &sdl2.SDL_Rect{ .x = x_pos_adjusted, .y = y_pos + @as(i32, @intCast(self.char_height)) - @as(i32, @intCast(config.cursor.thickness)), .w = @intCast(cursor_width), .h = config.cursor.thickness });
        },
        .blinking_bar, .steady_bar => {
            // 条状光标始终位于逻辑列 cx，但如果 cx 是 wide_dummy，则保持在当前位置（cx）
            const bar_x = @as(i32, @intCast(cx * self.char_width)) + hborder;
            _ = sdl2.SDL_RenderFillRect(sdl_renderer, &sdl2.SDL_Rect{ .x = bar_x, .y = y_pos, .w = config.cursor.thickness, .h = @intCast(self.char_height) });
        },
        .blinking_st_cursor, .steady_st_cursor => {
            const t = config.cursor.thickness;
            _ = sdl2.SDL_RenderFillRect(sdl_renderer, &sdl2.SDL_Rect{ .x = x_pos_adjusted, .y = y_pos, .w = @intCast(cursor_width), .h = t });
            _ = sdl2.SDL_RenderFillRect(sdl_renderer, &sdl2.SDL_Rect{ .x = x_pos_adjusted, .y = y_pos + @as(i32, @intCast(self.char_height)) - @as(i32, @intCast(t)), .w = @intCast(cursor_width), .h = t });
            _ = sdl2.SDL_RenderFillRect(sdl_renderer, &sdl2.SDL_Rect{ .x = x_pos_adjusted, .y = y_pos, .w = t, .h = @intCast(self.char_height) });
            _ = sdl2.SDL_RenderFillRect(sdl_renderer, &sdl2.SDL_Rect{ .x = x_pos_adjusted + @as(i32, @intCast(cursor_width)) - @as(i32, @intCast(t)), .y = y_pos, .w = t, .h = @intCast(self.char_height) });
            if (glyph.codepoint != ' ' and glyph.codepoint != 0) {
                const fg = try self.getColor(term, cursor_fg_idx);
                _ = sdl2.SDL_SetTextureColorMod(self.atlas.?.texture, fg.r, fg.g, fg.b);
                try self.drawTextGlyph(sdl_renderer, glyph.codepoint, x_pos_adjusted, y_pos, glyph.attr);
            }
        },
    }
}

pub fn resize(self: *Renderer) void {
    _ = self;
}
pub fn resetCursorBlink(self: *Renderer) void {
    self.cursor_blink_state = true;
    self.last_blink_time = std.time.milliTimestamp();
}

/// 绘制框线字符
/// 使用像素级渲染而非字体渲染，确保边框对齐和一致
fn drawBoxChar(self: *Renderer, renderer: *sdl2.SDL_Renderer, codepoint: u21, x: i32, y: i32, fg_color: sdl2.SDL_Color) !void {
    const data = boxdraw.BoxDraw.getDrawData(codepoint);
    if (data == 0) return;

    _ = sdl2.SDL_SetRenderDrawColor(renderer, fg_color.r, fg_color.g, fg_color.b, 255);

    const cw = @as(i32, @intCast(self.char_width));
    const ch = @as(i32, @intCast(self.char_height));

    // 获取类别标志（高 8 位）
    const category = data & 0xFF00;

    // 根据类别绘制
    if (category == boxdraw_data.LINE) {
        // 获取线条标志
        const bd = data & 0x00FF;

        // 计算线条粗细
        const is_bold = (data & boxdraw_data.BOLD) != 0;
        const lw: i32 = if (is_bold) 3 else 1;

        // 计算 double line 的偏移量
        const double_offset: i32 = if ((data & boxdraw_data.DOUBLE_LEFT) != 0 or (data & boxdraw_data.DOUBLE_RIGHT) != 0) 3 else 1;

        // 绘制水平线
        if ((bd & (boxdraw_data.LIGHT_LEFT | boxdraw_data.LIGHT_RIGHT)) != 0) {
            const y_line = y + @divTrunc(ch, 2) - @divTrunc(lw, 2);
            if ((bd & boxdraw_data.LIGHT_LEFT) != 0) {
                _ = sdl2.SDL_RenderDrawLine(renderer, x, y_line, x + cw, y_line);
                if (lw > 1) {
                    _ = sdl2.SDL_RenderDrawLine(renderer, x, y_line + 1, x + cw, y_line + 1);
                }
            }
            if ((bd & boxdraw_data.DOUBLE_LEFT) != 0) {
                _ = sdl2.SDL_RenderDrawLine(renderer, x, y_line - double_offset, x + cw, y_line - double_offset);
                _ = sdl2.SDL_RenderDrawLine(renderer, x, y_line + double_offset, x + cw, y_line + double_offset);
            }
        }

        // 绘制垂直线
        if ((bd & (boxdraw_data.LIGHT_UP | boxdraw_data.LIGHT_DOWN)) != 0) {
            const x_line = x + @divTrunc(cw, 2) - @divTrunc(lw, 2);
            if ((bd & boxdraw_data.LIGHT_UP) != 0) {
                _ = sdl2.SDL_RenderDrawLine(renderer, x_line, y, x_line, y + ch);
                if (lw > 1) {
                    _ = sdl2.SDL_RenderDrawLine(renderer, x_line + 1, y, x_line + 1, y + ch);
                }
            }
            if ((bd & boxdraw_data.DOUBLE_UP) != 0) {
                _ = sdl2.SDL_RenderDrawLine(renderer, x_line - double_offset, y, x_line - double_offset, y + ch);
                _ = sdl2.SDL_RenderDrawLine(renderer, x_line + double_offset, y, x_line + double_offset, y + ch);
            }
        }

        // 绘制 HEAVY 线条（绘制两条线实现）
        if ((bd & boxdraw_data.HEAVY_LEFT) != 0 and (bd & boxdraw_data.LIGHT_LEFT) == 0) {
            const y_line = y + @divTrunc(ch, 2) - 1;
            _ = sdl2.SDL_RenderDrawLine(renderer, x, y_line, x + cw, y_line);
            _ = sdl2.SDL_RenderDrawLine(renderer, x, y_line + 1, x + cw, y_line + 1);
            _ = sdl2.SDL_RenderDrawLine(renderer, x, y_line + 2, x + cw, y_line + 2);
        }
        if ((bd & boxdraw_data.HEAVY_UP) != 0 and (bd & boxdraw_data.LIGHT_UP) == 0) {
            const x_line = x + @divTrunc(cw, 2) - 1;
            _ = sdl2.SDL_RenderDrawLine(renderer, x_line, y, x_line, y + ch);
            _ = sdl2.SDL_RenderDrawLine(renderer, x_line + 1, y, x_line + 1, y + ch);
            _ = sdl2.SDL_RenderDrawLine(renderer, x_line + 2, y, x_line + 2, y + ch);
        }
    } else if (category == boxdraw_data.BLOCK_QUADRANT) {
        // 绘制四分之一块
        const bd = data & 0x00FF;
        const half_w = @divTrunc(cw, 2);
        const half_h = @divTrunc(ch, 2);

        if ((bd & boxdraw_data.TOP_LEFT) != 0) {
            _ = sdl2.SDL_RenderFillRect(renderer, &sdl2.SDL_Rect{ .x = x, .y = y, .w = half_w, .h = half_h });
        }
        if ((bd & boxdraw_data.TOP_RIGHT) != 0) {
            _ = sdl2.SDL_RenderFillRect(renderer, &sdl2.SDL_Rect{ .x = x + half_w, .y = y, .w = half_w, .h = half_h });
        }
        if ((bd & boxdraw_data.BOTTOM_LEFT) != 0) {
            _ = sdl2.SDL_RenderFillRect(renderer, &sdl2.SDL_Rect{ .x = x, .y = y + half_h, .w = half_w, .h = half_h });
        }
        if ((bd & boxdraw_data.BOTTOM_RIGHT) != 0) {
            _ = sdl2.SDL_RenderFillRect(renderer, &sdl2.SDL_Rect{ .x = x + half_w, .y = y + half_h, .w = half_w, .h = half_h });
        }
    } else if (category == boxdraw_data.BRAILLE) {
        // Braille 模式 (U+2800-U+28FF)
        const pattern = @as(u8, @truncate(codepoint));
        const cell_w = @divFloor(cw, 2);
        const cell_h = @divFloor(ch, 4);
        const dot_w = @divTrunc(cell_w, 2);
        const dot_h = @divTrunc(cell_h, 2);

        // Braille 点的位置
        // 左列: dots 1,2,3 (y=0,1,2)
        // 右列: dots 4,5,6 (y=0,1,2)
        // 第 4 行: dots 7,8 (y=3)
        for (0..8) |dot_idx| {
            if ((pattern & (@as(u8, 1) << @intCast(dot_idx))) != 0) {
                const col = if (dot_idx < 6) (dot_idx % 3) else 0;
                const row = if (dot_idx < 6) @divFloor(dot_idx, 3) else 3;
                const dot_x = x + @as(i32, @intCast(col)) * cell_w + @divTrunc(cell_w - dot_w, 2);
                const dot_y = y + @as(i32, @intCast(row)) * cell_h + @divTrunc(cell_h - dot_h, 2);
                _ = sdl2.SDL_RenderFillRect(renderer, &sdl2.SDL_Rect{ .x = dot_x, .y = dot_y, .w = dot_w, .h = dot_h });
            }
        }
    } else if (category == boxdraw_data.BLOCK_SHADE) {
        // 阴影块
        const shade = data & 0x00FF;

        // 根据阴影级别填充
        var density: i32 = 0;
        if (shade == 0x00) {
            density = 0; // 空心
        } else if (shade == 0x01) {
            density = 25; // 轻阴影 25%
        } else if (shade == 0x02) {
            density = 50; // 中等阴影 50%
        } else if (shade == 0x03) {
            density = 75; // 重阴影 75%
        } else if (shade == 0x04) {
            density = 100; // 实心
        } else {
            density = 0;
        }

        if (density == 100) {
            _ = sdl2.SDL_RenderFillRect(renderer, &sdl2.SDL_Rect{ .x = x, .y = y, .w = cw, .h = ch });
        } else if (density > 0) {
            // 绘制点阵模式
            const step = @max(1, @divFloor(100, density));
            var py = y;
            while (py < y + ch) : (py += step) {
                var px = x;
                while (px < x + cw) : (px += step) {
                    _ = sdl2.SDL_RenderDrawPoint(renderer, px, py);
                }
            }
        }
    }
}
pub fn zoom(self: *Renderer, zoom_in: bool) !void {
    // 缩放步长为 2 像素
    const step: i32 = 2;

    var new_size: i32 = @as(i32, @intCast(self.current_font_size));
    if (zoom_in) {
        new_size += step;
    } else {
        new_size -= step;
    }

    // 限制最小字体大小为 6
    if (new_size < 6) return;

    // 更新字体大小并重新加载
    try self.reloadFonts(@as(u32, @intCast(new_size)));
}

pub fn resetZoom(self: *Renderer) !void {
    // 恢复到原始字体大小
    try self.reloadFonts(self.original_font_size);
}

/// 重新加载所有字体并更新渲染器尺寸
fn reloadFonts(self: *Renderer, new_size: u32) !void {
    // 更新所有字体的像素大小
    if (ft.FT_Set_Pixel_Sizes(self.font, 0, @intCast(new_size)) != 0) {
        return error.FontLoadFailed;
    }
    if (self.font_italic != self.font) {
        if (ft.FT_Set_Pixel_Sizes(self.font_italic, 0, @intCast(new_size)) != 0) {
            return error.FontLoadFailed;
        }
    }
    if (self.font_bold != self.font) {
        if (ft.FT_Set_Pixel_Sizes(self.font_bold, 0, @intCast(new_size)) != 0) {
            return error.FontLoadFailed;
        }
    }
    if (self.font_italic_bold != self.font) {
        if (ft.FT_Set_Pixel_Sizes(self.font_italic_bold, 0, @intCast(new_size)) != 0) {
            return error.FontLoadFailed;
        }
    }
    for (self.fallbacks.items) |fallback| {
        // 彩色 emoji 字体可能不支持动态缩放，忽略失败
        _ = ft.FT_Set_Pixel_Sizes(fallback, 0, @intCast(new_size));
    }

    // 重新计算字符尺寸
    const ascii_printable = " !\"#$%&'()*+,-./0123456789:;<=>?@ABCDEFGHIJKLMNOPQRSTUVWXYZ[\\ ]^_`abcdefghijklmnopqrstuvwxyz{|}~";
    var total_advance: i64 = 0;
    for (ascii_printable) |c| {
        _ = ft.FT_Load_Char(self.font, c, ft.FT_LOAD_RENDER);
        const glyph = self.font.*.glyph;
        const advance = glyph.*.advance.x >> 6;
        if (advance > 0) {
            total_advance += advance;
        }
    }

    const avg_width = if (ascii_printable.len > 0)
        @as(f32, @floatFromInt(total_advance)) / @as(f32, @floatFromInt(ascii_printable.len))
    else
        @as(f32, @floatFromInt(self.font.*.max_advance_width));

    const char_width = @max(1, @as(u32, @intFromFloat(@ceil(avg_width * config.font.cwscale))));

    const size_metrics = self.font.*.size.*.metrics;
    const char_height = @max(1, @as(u32, @intFromFloat(@ceil(@as(f32, @floatFromInt(size_metrics.height >> 6)) * config.font.chscale))));

    const ascent = @as(i32, @intCast(size_metrics.ascender >> 6));
    const descent = @as(i32, @intCast(size_metrics.descender >> 6));

    // 更新渲染器尺寸
    self.current_font_size = new_size;
    self.char_width = char_width;
    self.char_height = char_height;
    self.ascent = ascent;
    self.descent = descent;

    // 更新窗口单元格尺寸
    self.window.cell_width = char_width;
    self.window.cell_height = char_height;

    // 清除字体缓存和纹理图集
    self.font_cache.clearRetainingCapacity();
    if (self.atlas) |*atlas| {
        atlas.clear(self.window.sdl_renderer);
    }

    std.log.info("字体缩放: {} -> {} ({} x {})", .{ self.current_font_size, new_size, char_width, char_height });
}
