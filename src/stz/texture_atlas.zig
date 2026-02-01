//! 纹理图集管理器
//!
//! 将多个字形位图合并到单一纹理中，减少纹理切换开销。
//! 使用网格布局策略，简单高效。

const std = @import("std");
const stz = @import("stz");
const sdl2 = stz.c.sdl2;
const ft = stz.c.ft;
const types = stz.types;

pub const GlyphInfo = struct {
    // 在图集中的位置（像素坐标）
    x: u16,
    y: u16,
    // 字形实际大小
    width: u8,
    height: u8,
    // 字形偏移量（用于正确渲染）
    bitmap_left: i8,
    bitmap_top: i8,
    // 纹理坐标（归一化 0.0-1.0，用于 SDL_RenderCopy 的 src_rect）
    tex_x: f32,
    tex_y: f32,
    tex_w: f32,
    tex_h: f32,
};

pub const TextureAtlasError = error{
    AtlasFull,
    TextureCreateFailed,
    InvalidGlyphSize,
};

/// 纹理图集 - 使用网格布局管理字形
pub const TextureAtlas = struct {
    // SDL 纹理
    texture: *sdl2.SDL_Texture,
    // 图集尺寸
    width: u32,
    height: u32,

    // 网格配置
    cell_size: u32, // 每个网格单元的大小（正方形）
    cols: u32, // 横向网格数
    rows: u32, // 纵向网格数

    // 分配器
    allocator: std.mem.Allocator,

    // 下一个可用的网格位置
    next_cell_idx: u32 = 0,

    // 字形信息缓存：key = (codepoint << 32 | attr_bits)
    glyph_cache: std.AutoHashMap(u64, GlyphInfo),

    // 统计信息
    glyphs_stored: u32 = 0,

    const Self = @This();

    /// 创建新的纹理图集
    ///
    /// 参数:
    ///   - renderer: SDL 渲染器
    ///   - width, height: 图集尺寸（推荐 1024x1024 或 2048x2048）
    ///   - cell_size: 网格单元大小（必须能容纳最大字形，推荐 64）
    ///   - allocator: 内存分配器
    pub fn init(
        renderer: *sdl2.SDL_Renderer,
        width: u32,
        height: u32,
        cell_size: u32,
        allocator: std.mem.Allocator,
    ) !Self {
        // 创建目标纹理（可渲染到）
        const texture = sdl2.SDL_CreateTexture(
            renderer,
            sdl2.SDL_PIXELFORMAT_ABGR8888,
            sdl2.SDL_TEXTUREACCESS_TARGET,
            @intCast(width),
            @intCast(height),
        ) orelse {
            std.log.err("创建纹理图集失败: {s}", .{sdl2.SDL_GetError()});
            return error.TextureCreateFailed;
        };

        // 设置纹理混合模式
        _ = sdl2.SDL_SetTextureBlendMode(texture, sdl2.SDL_BLENDMODE_BLEND);

        // 设置纹理缩放模式为线性过滤（Linear）以获得更平滑的字体边缘
        // 对于灰度字体渲染，线性过滤比最近邻更清晰
        _ = sdl2.SDL_SetTextureScaleMode(texture, sdl2.SDL_ScaleModeLinear);

        // 清空纹理为透明
        _ = sdl2.SDL_SetRenderTarget(renderer, texture);
        _ = sdl2.SDL_SetRenderDrawColor(renderer, 0, 0, 0, 0);
        _ = sdl2.SDL_RenderClear(renderer);
        _ = sdl2.SDL_SetRenderTarget(renderer, null);

        const cols = width / cell_size;
        const rows = height / cell_size;

        return Self{
            .texture = texture,
            .width = width,
            .height = height,
            .cell_size = cell_size,
            .cols = cols,
            .rows = rows,
            .allocator = allocator,
            .next_cell_idx = 0,
            .glyph_cache = std.AutoHashMap(u64, GlyphInfo).init(allocator),
            .glyphs_stored = 0,
        };
    }

    pub fn deinit(self: *Self) void {
        sdl2.SDL_DestroyTexture(self.texture);
        self.glyph_cache.deinit();
    }

    /// 计算缓存键
    fn makeCacheKey(codepoint: u21, attr: types.GlyphAttr) u64 {
        const attr_bits: u8 = @as(u8, @intFromBool(attr.bold)) << 1 |
            @as(u8, @intFromBool(attr.italic));
        return (@as(u64, codepoint) << 32) | @as(u64, attr_bits);
    }

    /// 查找空闲网格位置
    fn findFreeCell(self: *Self) ?u32 {
        if (self.next_cell_idx >= self.cols * self.rows) return null;
        const idx = self.next_cell_idx;
        self.next_cell_idx += 1;
        return idx;
    }

    /// 将网格索引转换为像素坐标
    fn cellToPixel(self: *Self, cell_idx: u32) struct { x: u32, y: u32 } {
        const col = cell_idx % self.cols;
        const row = cell_idx / self.cols;
        return .{
            .x = col * self.cell_size,
            .y = row * self.cell_size,
        };
    }

    /// 添加字形到图集
    ///
    /// 参数:
    ///   - renderer: SDL 渲染器
    ///   - face: FreeType 字体面
    ///   - codepoint: Unicode 码点
    ///   - attr: 字形属性
    ///
    /// 返回: 字形信息（包含纹理坐标）
    pub fn addGlyph(
        self: *Self,
        _: *sdl2.SDL_Renderer,
        face: ft.FT_Face,
        codepoint: u21,
        attr: types.GlyphAttr,
    ) !GlyphInfo {
        const cache_key = makeCacheKey(codepoint, attr);

        // 检查缓存
        if (self.glyph_cache.get(cache_key)) |info| {
            return info;
        }

        // 渲染字形 - 使用高质量渲染模式
        // FT_LOAD_COLOR: 启用彩色 emoji 支持（需要 BGRA 格式位图）
        // FT_LOAD_RENDER: 立即渲染位图
        // 注意：FT_LOAD_FORCE_AUTOHINT 和 FT_LOAD_TARGET_NORMAL 可能与彩色 emoji 冲突
        const load_flags = ft.FT_LOAD_RENDER | ft.FT_LOAD_COLOR;
        if (ft.FT_Load_Char(face, codepoint, load_flags) != 0) {
            std.log.warn("加载字形失败: U+{X}", .{codepoint});
            return error.InvalidGlyphSize;
        }

        const glyph = face.*.glyph;
        const bitmap = &glyph.*.bitmap;

        // 调试：打印 emoji 字形信息
        const is_emoji = (codepoint >= 0x1F000 and codepoint <= 0x1FAFF);
        if (is_emoji) {
            std.log.warn("Emoji U+{X} 字形信息: {}x{}, pixel_mode={}, pitch={}", .{
                codepoint,
                bitmap.width,
                bitmap.rows,
                bitmap.pixel_mode,
                bitmap.pitch,
            });
        }

        // 检查字形大小
        if (bitmap.width > self.cell_size or bitmap.rows > self.cell_size) {
            // 字形太大，无法放入当前网格
            std.log.warn("字形过大: {}x{} > 单元格 {} (U+{X})", .{
                bitmap.width,
                bitmap.rows,
                self.cell_size,
                codepoint,
            });
            return error.InvalidGlyphSize;
        }

        // 查找空闲位置
        const cell_idx = self.findFreeCell() orelse {
            return error.AtlasFull;
        };

        const pos = self.cellToPixel(cell_idx);

        // 创建临时纹理上传字形数据
        if (bitmap.width > 0 and bitmap.rows > 0) {
            // 检测位图格式：彩色 emoji 使用 FT_PIXEL_MODE_BGRA，普通字形使用 FT_PIXEL_MODE_GRAY
            const is_color = bitmap.*.pixel_mode == ft.FT_PIXEL_MODE_BGRA;

            const pixel_count = bitmap.width * bitmap.rows * 4;
            var pixels = try self.allocator.alloc(u8, pixel_count);
            defer self.allocator.free(pixels);

            if (is_color) {
                // 彩色 emoji：直接复制 BGRA 数据（无需转换）
                // FreeType 使用 BGRA 顺序，SDL2 期望 BGRA（SDL_PIXELFORMAT_ABGR8888）
                std.mem.copyForwards(u8, pixels, bitmap.buffer[0..pixel_count]);
            } else {
                // 灰度字形：转换灰度 -> RGBA (255, 255, 255, gray)
                var pixel_idx: usize = 0;
                var row: usize = 0;
                while (row < bitmap.rows) : (row += 1) {
                    var col: usize = 0;
                    while (col < bitmap.width) : (col += 1) {
                        const gray = bitmap.buffer[row * @as(usize, @intCast(bitmap.pitch)) + col];
                        pixels[pixel_idx + 0] = 255; // R
                        pixels[pixel_idx + 1] = 255; // G
                        pixels[pixel_idx + 2] = 255; // B
                        pixels[pixel_idx + 3] = gray; // A
                        pixel_idx += 4;
                    }
                }
            }

            // 直接更新图集纹理的一部分
            const update_rect = sdl2.SDL_Rect{
                .x = @intCast(pos.x),
                .y = @intCast(pos.y),
                .w = @intCast(bitmap.width),
                .h = @intCast(bitmap.rows),
            };
            if (sdl2.SDL_UpdateTexture(self.texture, &update_rect, pixels.ptr, @intCast(bitmap.width * 4)) != 0) {
                return error.TextureCreateFailed;
            }
        }

        self.glyphs_stored += 1;

        // 计算纹理坐标（归一化）
        const tex_x = @as(f32, @floatFromInt(pos.x)) / @as(f32, @floatFromInt(self.width));
        const tex_y = @as(f32, @floatFromInt(pos.y)) / @as(f32, @floatFromInt(self.height));
        const tex_w = @as(f32, @floatFromInt(bitmap.width)) / @as(f32, @floatFromInt(self.width));
        const tex_h = @as(f32, @floatFromInt(bitmap.rows)) / @as(f32, @floatFromInt(self.height));

        // 创建字形信息
        const info = GlyphInfo{
            .x = @intCast(pos.x),
            .y = @intCast(pos.y),
            .width = @intCast(bitmap.width),
            .height = @intCast(bitmap.rows),
            .bitmap_left = @intCast(glyph.*.bitmap_left),
            .bitmap_top = @intCast(glyph.*.bitmap_top),
            .tex_x = tex_x,
            .tex_y = tex_y,
            .tex_w = tex_w,
            .tex_h = tex_h,
        };

        // 存入缓存
        try self.glyph_cache.put(cache_key, info);

        return info;
    }

    /// 获取字形信息（如果不存在返回 null）
    pub fn getGlyphInfo(self: *Self, codepoint: u21, attr: types.GlyphAttr) ?GlyphInfo {
        const cache_key = makeCacheKey(codepoint, attr);
        return self.glyph_cache.get(cache_key);
    }

    /// 使用 FreeType 字形索引添加字形到图集（用于连字支持）
    ///
    /// 参数:
    ///   - face: FreeType 字体面（已加载字形）
    ///   - glyph_index: FreeType 字形索引
    ///   - attr: 字形属性
    ///
    /// 返回: 字形信息（包含纹理坐标）
    pub fn addGlyphWithLigatureIndex(
        self: *Self,
        face: ft.FT_Face,
        glyph_index: u32,
        attr: types.GlyphAttr,
    ) !GlyphInfo {
        // 对于连字，我们使用特殊的缓存键：(glyph_index << 32) | attr_bits | (1 << 63)
        // 设置最高位以区分 Unicode 码点和 FreeType 字形索引，避免冲突
        const attr_bits: u64 = @as(u64, @intFromBool(attr.bold)) << 1 | @as(u64, @intFromBool(attr.italic));
        const cache_key = (@as(u64, glyph_index) << 32) | attr_bits | (@as(u64, 1) << 63);

        // 检查缓存
        if (self.glyph_cache.get(cache_key)) |info| {
            return info;
        }

        // 字形已在调用者处加载，直接获取
        const glyph = face.*.glyph;
        const bitmap = &glyph.*.bitmap;

        // 检查字形大小
        if (bitmap.width > self.cell_size or bitmap.rows > self.cell_size) {
            std.log.warn("连字字形过大: {}x{} > 单元格 {}", .{
                bitmap.width,
                bitmap.rows,
                self.cell_size,
            });
            return error.InvalidGlyphSize;
        }

        // 查找空闲位置
        const cell_idx = self.findFreeCell() orelse {
            return error.AtlasFull;
        };

        const pos = self.cellToPixel(cell_idx);

        // 创建临时纹理上传字形数据
        if (bitmap.width > 0 and bitmap.rows > 0) {
            // 检测位图格式：彩色 emoji 使用 FT_PIXEL_MODE_BGRA，普通字形使用 FT_PIXEL_MODE_GRAY
            const is_color = bitmap.*.pixel_mode == ft.FT_PIXEL_MODE_BGRA;

            const pixel_count = bitmap.width * bitmap.rows * 4;
            var pixels = try self.allocator.alloc(u8, pixel_count);
            defer self.allocator.free(pixels);

            if (is_color) {
                // 彩色 emoji：直接复制 BGRA 数据（无需转换）
                // FreeType 使用 BGRA 顺序，SDL2 期望 BGRA（SDL_PIXELFORMAT_ABGR8888）
                std.mem.copyForwards(u8, pixels, bitmap.buffer[0..pixel_count]);
            } else {
                // 灰度字形：转换灰度 -> RGBA (255, 255, 255, gray)
                var pixel_idx: usize = 0;
                var row: usize = 0;
                while (row < bitmap.rows) : (row += 1) {
                    var col: usize = 0;
                    while (col < bitmap.width) : (col += 1) {
                        const gray = bitmap.buffer[row * @as(usize, @intCast(bitmap.pitch)) + col];
                        pixels[pixel_idx + 0] = 255; // R
                        pixels[pixel_idx + 1] = 255; // G
                        pixels[pixel_idx + 2] = 255; // B
                        pixels[pixel_idx + 3] = gray; // A
                        pixel_idx += 4;
                    }
                }
            }

            // 直接更新图集纹理的一部分
            const update_rect = sdl2.SDL_Rect{
                .x = @intCast(pos.x),
                .y = @intCast(pos.y),
                .w = @intCast(bitmap.width),
                .h = @intCast(bitmap.rows),
            };
            if (sdl2.SDL_UpdateTexture(self.texture, &update_rect, pixels.ptr, @intCast(bitmap.width * 4)) != 0) {
                return error.TextureCreateFailed;
            }
        }

        self.glyphs_stored += 1;

        // 计算纹理坐标（归一化）
        const tex_x = @as(f32, @floatFromInt(pos.x)) / @as(f32, @floatFromInt(self.width));
        const tex_y = @as(f32, @floatFromInt(pos.y)) / @as(f32, @floatFromInt(self.height));
        const tex_w = @as(f32, @floatFromInt(bitmap.width)) / @as(f32, @floatFromInt(self.width));
        const tex_h = @as(f32, @floatFromInt(bitmap.rows)) / @as(f32, @floatFromInt(self.height));

        // 创建字形信息
        const info = GlyphInfo{
            .x = @intCast(pos.x),
            .y = @intCast(pos.y),
            .width = @intCast(bitmap.width),
            .height = @intCast(bitmap.rows),
            .bitmap_left = @intCast(glyph.*.bitmap_left),
            .bitmap_top = @intCast(glyph.*.bitmap_top),
            .tex_x = tex_x,
            .tex_y = tex_y,
            .tex_w = tex_w,
            .tex_h = tex_h,
        };

        // 存入缓存
        try self.glyph_cache.put(cache_key, info);

        return info;
    }

    /// 清空图集（当满时调用）
    pub fn clear(self: *Self, renderer: *sdl2.SDL_Renderer) void {
        self.next_cell_idx = 0;
        self.glyph_cache.clearRetainingCapacity();
        self.glyphs_stored = 0;

        // 清空纹理
        _ = sdl2.SDL_SetRenderTarget(renderer, self.texture);
        _ = sdl2.SDL_SetRenderDrawColor(renderer, 0, 0, 0, 0);
        _ = sdl2.SDL_RenderClear(renderer);
        _ = sdl2.SDL_SetRenderTarget(renderer, null);
    }
};
