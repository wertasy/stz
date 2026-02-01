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
    // 字形在图集中的实际大小
    width: u16,
    height: u16,
    // 字形偏移量（用于正确渲染）
    bitmap_left: i16,
    bitmap_top: i16,
    // 纹理坐标（归一化 0.0-1.0，用于 SDL_RenderCopy 的 src_rect）
    tex_x: f32,
    tex_y: f32,
    tex_w: f32,
    tex_h: f32,

    // 是否是彩色字形 (emoji)
    is_color: bool = false,

    // 渲染尺寸和偏移（可能经过缩放）
    render_w: u16,
    render_h: u16,
    render_left: i16,
    render_top: i16,
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
    pub fn init(
        renderer: *sdl2.SDL_Renderer,
        width: u32,
        height: u32,
        cell_size: u32,
        allocator: std.mem.Allocator,
    ) !Self {
        // 使用 ABGR8888 格式 (Little Endian: [R, G, B, A])
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

        _ = sdl2.SDL_SetTextureBlendMode(texture, sdl2.SDL_BLENDMODE_BLEND);
        _ = sdl2.SDL_SetTextureScaleMode(texture, sdl2.SDL_ScaleModeLinear);

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

    fn makeCacheKey(codepoint: u64, attr: types.GlyphAttr, is_ligature: bool) u64 {
        const attr_bits: u64 = @as(u64, @intFromBool(attr.bold)) << 1 | @as(u64, @intFromBool(attr.italic));
        var key = (codepoint << 32) | attr_bits;
        if (is_ligature) key |= (@as(u64, 1) << 63);
        return key;
    }

    fn findFreeCell(self: *Self) ?u32 {
        if (self.next_cell_idx >= self.cols * self.rows) return null;
        const idx = self.next_cell_idx;
        self.next_cell_idx += 1;
        return idx;
    }

    fn cellToPixel(self: *Self, cell_idx: u32) struct { x: u32, y: u32 } {
        const col = cell_idx % self.cols;
        const row = cell_idx / self.cols;
        return .{
            .x = col * self.cell_size,
            .y = row * self.cell_size,
        };
    }

    pub fn addGlyph(
        self: *Self,
        _: *sdl2.SDL_Renderer,
        face: ft.FT_Face,
        codepoint: u21,
        attr: types.GlyphAttr,
        target_size: u32,
    ) !GlyphInfo {
        const cache_key = makeCacheKey(codepoint, attr, false);
        if (self.glyph_cache.get(cache_key)) |info| return info;

        const load_flags = ft.FT_LOAD_RENDER | ft.FT_LOAD_COLOR;
        if (ft.FT_Load_Char(face, codepoint, load_flags) != 0) {
            std.log.warn("加载字形失败: U+{X}", .{codepoint});
            return error.InvalidGlyphSize;
        }

        const glyph = face.*.glyph;
        const bitmap = &glyph.*.bitmap;
        const is_color = bitmap.*.pixel_mode == ft.FT_PIXEL_MODE_BGRA;

        const cell_idx = self.findFreeCell() orelse return error.AtlasFull;
        const pos = self.cellToPixel(cell_idx);

        var scale: f32 = 1.0;
        if (is_color) {
            const face_height = @as(f32, @floatFromInt(face.*.size.*.metrics.height)) / 64.0;
            if (face_height > 0) {
                scale = @as(f32, @floatFromInt(target_size)) / face_height;
            }
        }

        if (bitmap.width > 0 and bitmap.rows > 0) {
            const pixel_count = bitmap.width * bitmap.rows * 4;
            var pixels = try self.allocator.alloc(u8, pixel_count);
            defer self.allocator.free(pixels);

            if (is_color) {
                // 彩色 emoji：从 BGRA (FreeType) 转换为 RGBA (ABGR8888 on Little Endian)
                // FreeType 为 [B, G, R, A]，ABGR8888 为 [R, G, B, A]
                var i: usize = 0;
                while (i < pixel_count) : (i += 4) {
                    pixels[i + 0] = bitmap.buffer[i + 2]; // R
                    pixels[i + 1] = bitmap.buffer[i + 1]; // G
                    pixels[i + 2] = bitmap.buffer[i + 0]; // B
                    pixels[i + 3] = bitmap.buffer[i + 3]; // A
                }
            } else {
                var pixel_idx: usize = 0;
                var row: usize = 0;
                while (row < bitmap.rows) : (row += 1) {
                    var col: usize = 0;
                    while (col < bitmap.width) : (col += 1) {
                        const gray = bitmap.buffer[row * @as(usize, @intCast(bitmap.pitch)) + col];
                        pixels[pixel_idx + 0] = 255;
                        pixels[pixel_idx + 1] = 255;
                        pixels[pixel_idx + 2] = 255;
                        pixels[pixel_idx + 3] = gray;
                        pixel_idx += 4;
                    }
                }
            }

            const update_rect = sdl2.SDL_Rect{ .x = @intCast(pos.x), .y = @intCast(pos.y), .w = @intCast(bitmap.width), .h = @intCast(bitmap.rows) };
            if (sdl2.SDL_UpdateTexture(self.texture, &update_rect, pixels.ptr, @intCast(bitmap.width * 4)) != 0) {
                return error.TextureCreateFailed;
            }
        }

        self.glyphs_stored += 1;
        const info = GlyphInfo{
            .x = @intCast(pos.x),
            .y = @intCast(pos.y),
            .width = @intCast(bitmap.width),
            .height = @intCast(bitmap.rows),
            .bitmap_left = @intCast(glyph.*.bitmap_left),
            .bitmap_top = @intCast(glyph.*.bitmap_top),
            .tex_x = @as(f32, @floatFromInt(pos.x)) / @as(f32, @floatFromInt(self.width)),
            .tex_y = @as(f32, @floatFromInt(pos.y)) / @as(f32, @floatFromInt(self.height)),
            .tex_w = @as(f32, @floatFromInt(bitmap.width)) / @as(f32, @floatFromInt(self.width)),
            .tex_h = @as(f32, @floatFromInt(bitmap.rows)) / @as(f32, @floatFromInt(self.height)),
            .is_color = is_color,
            .render_w = @intFromFloat(@ceil(@as(f32, @floatFromInt(bitmap.width)) * scale)),
            .render_h = @intFromFloat(@ceil(@as(f32, @floatFromInt(bitmap.rows)) * scale)),
            .render_left = @intFromFloat(@ceil(@as(f32, @floatFromInt(glyph.*.bitmap_left)) * scale)),
            .render_top = @intFromFloat(@ceil(@as(f32, @floatFromInt(glyph.*.bitmap_top)) * scale)),
        };
        try self.glyph_cache.put(cache_key, info);
        return info;
    }

    pub fn getGlyphInfo(self: *Self, codepoint: u21, attr: types.GlyphAttr) ?GlyphInfo {
        const cache_key = makeCacheKey(codepoint, attr, false);
        return self.glyph_cache.get(cache_key);
    }

    pub fn addGlyphWithLigatureIndex(
        self: *Self,
        face: ft.FT_Face,
        glyph_index: u32,
        attr: types.GlyphAttr,
        target_size: u32,
    ) !GlyphInfo {
        const cache_key = makeCacheKey(glyph_index, attr, true);
        if (self.glyph_cache.get(cache_key)) |info| return info;

        const glyph = face.*.glyph;
        const bitmap = &glyph.*.bitmap;
        const is_color = bitmap.*.pixel_mode == ft.FT_PIXEL_MODE_BGRA;

        const cell_idx = self.findFreeCell() orelse return error.AtlasFull;
        const pos = self.cellToPixel(cell_idx);

        var scale: f32 = 1.0;
        if (is_color) {
            const face_height = @as(f32, @floatFromInt(face.*.size.*.metrics.height)) / 64.0;
            if (face_height > 0) {
                scale = @as(f32, @floatFromInt(target_size)) / face_height;
            }
        }

        if (bitmap.width > 0 and bitmap.rows > 0) {
            const pixel_count = bitmap.width * bitmap.rows * 4;
            var pixels = try self.allocator.alloc(u8, pixel_count);
            defer self.allocator.free(pixels);

            if (is_color) {
                // 从 BGRA 转换为 RGBA
                var i: usize = 0;
                while (i < pixel_count) : (i += 4) {
                    pixels[i + 0] = bitmap.buffer[i + 2]; // R
                    pixels[i + 1] = bitmap.buffer[i + 1]; // G
                    pixels[i + 2] = bitmap.buffer[i + 0]; // B
                    pixels[i + 3] = bitmap.buffer[i + 3]; // A
                }
            } else {
                var pixel_idx: usize = 0;
                var row: usize = 0;
                while (row < bitmap.rows) : (row += 1) {
                    var col: usize = 0;
                    while (col < bitmap.width) : (col += 1) {
                        const gray = bitmap.buffer[row * @as(usize, @intCast(bitmap.pitch)) + col];
                        pixels[pixel_idx + 0] = 255;
                        pixels[pixel_idx + 1] = 255;
                        pixels[pixel_idx + 2] = 255;
                        pixels[pixel_idx + 3] = gray;
                        pixel_idx += 4;
                    }
                }
            }

            const update_rect = sdl2.SDL_Rect{ .x = @intCast(pos.x), .y = @intCast(pos.y), .w = @intCast(bitmap.width), .h = @intCast(bitmap.rows) };
            if (sdl2.SDL_UpdateTexture(self.texture, &update_rect, pixels.ptr, @intCast(bitmap.width * 4)) != 0) {
                return error.TextureCreateFailed;
            }
        }

        self.glyphs_stored += 1;
        const info = GlyphInfo{
            .x = @intCast(pos.x),
            .y = @intCast(pos.y),
            .width = @intCast(bitmap.width),
            .height = @intCast(bitmap.rows),
            .bitmap_left = @intCast(glyph.*.bitmap_left),
            .bitmap_top = @intCast(glyph.*.bitmap_top),
            .tex_x = @as(f32, @floatFromInt(pos.x)) / @as(f32, @floatFromInt(self.width)),
            .tex_y = @as(f32, @floatFromInt(pos.y)) / @as(f32, @floatFromInt(self.height)),
            .tex_w = @as(f32, @floatFromInt(bitmap.width)) / @as(f32, @floatFromInt(self.width)),
            .tex_h = @as(f32, @floatFromInt(bitmap.rows)) / @as(f32, @floatFromInt(self.height)),
            .is_color = is_color,
            .render_w = @intFromFloat(@ceil(@as(f32, @floatFromInt(bitmap.width)) * scale)),
            .render_h = @intFromFloat(@ceil(@as(f32, @floatFromInt(bitmap.rows)) * scale)),
            .render_left = @intFromFloat(@ceil(@as(f32, @floatFromInt(glyph.*.bitmap_left)) * scale)),
            .render_top = @intFromFloat(@ceil(@as(f32, @floatFromInt(glyph.*.bitmap_top)) * scale)),
        };
        try self.glyph_cache.put(cache_key, info);
        return info;
    }

    pub fn clear(self: *Self, renderer: *sdl2.SDL_Renderer) void {
        self.next_cell_idx = 0;
        self.glyph_cache.clearRetainingCapacity();
        self.glyphs_stored = 0;
        _ = sdl2.SDL_SetRenderTarget(renderer, self.texture);
        _ = sdl2.SDL_SetRenderDrawColor(renderer, 0, 0, 0, 0);
        _ = sdl2.SDL_RenderClear(renderer);
        _ = sdl2.SDL_SetRenderTarget(renderer, null);
    }
};
