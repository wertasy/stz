const std = @import("std");
const stz = @import("stz");
const types = stz.types;

const hb = stz.c.hb;
const sdl2 = stz.c.sdl2;
const ft = stz.c.ft;

// HarfBuzz 字体缓存
const FontPair = struct {
    font: ?*anyopaque, // FreeType FT_Face (stored as opaque pointer)
    hbfont: *hb.hb_font_t,
};

// HarfBuzz 辅助数据结构
pub const TransformData = struct {
    buffer: ?*hb.hb_buffer_t = null,
    glyphs: [*c]hb.hb_glyph_info_t = null,
    positions: [*c]hb.hb_glyph_position_t = null,
    count: c_uint = 0,

    pub fn init(_: std.mem.Allocator) TransformData {
        return .{
            .buffer = hb.hb_buffer_create(),
        };
    }

    // 重置 HarfBuzz 变换数据
    pub fn reset(data: *TransformData) void {
        if (data.buffer) |buf| {
            hb.hb_buffer_reset(buf);
        }
        data.glyphs = null;
        data.positions = null;
        data.count = 0;
    }

    // 清理 HarfBuzz 变换数据
    pub fn deinit(data: *TransformData) void {
        if (data.buffer) |buf| {
            hb.hb_buffer_destroy(buf);
            data.buffer = null;
        }
        data.glyphs = null;
        data.positions = null;
        data.count = 0;
    }
};

pub const Self = @This();

allocator: ?std.mem.Allocator = null,
hb_font_cache: std.ArrayList(FontPair) = undefined,

// 初始化 HarfBuzz 字体缓存
pub fn init(allocator: std.mem.Allocator) !Self {
    return .{
        .allocator = allocator,
        .hb_font_cache = try std.ArrayList(FontPair).initCapacity(allocator, 16),
    };
}

// HarfBuzz 形状转换
pub fn transform(self: *Self, data: *TransformData, font: ?*anyopaque, glyphs: []const types.Glyph, start: usize, length: usize) void {
    _ = length; // 这里的 length 是有效字符数，但我们通过遍历 glyphs 并跳过 dummy 来隐式处理
    const hbfont = self.findFont(font) orelse return;

    const buffer = data.buffer;
    hb.hb_buffer_reset(buffer);

    hb.hb_buffer_set_direction(buffer, hb.HB_DIRECTION_LTR);
    hb.hb_buffer_set_cluster_level(buffer, hb.HB_BUFFER_CLUSTER_LEVEL_MONOTONE_CHARACTERS);
    hb.hb_buffer_set_content_type(buffer, hb.HB_BUFFER_CONTENT_TYPE_UNICODE);

    // 遍历所有字符，跳过 wide_dummy，使用连续的 cluster 索引
    // cluster 索引指向 ligature_glyphs 数组（跳过了 wide_dummy 的数组）
    var cluster_idx: usize = 0;
    for (start..glyphs.len) |i| {
        // 跳过 wide_dummy，不添加到 buffer
        if (glyphs[i].attr.wide_dummy) {
            continue;
        }
        hb.hb_buffer_add(buffer, glyphs[i].codepoint, @intCast(cluster_idx));
        cluster_idx += 1;
    }

    hb.hb_shape(hbfont, buffer, null, 0);

    var glyph_count: c_uint = 0;
    const info = hb.hb_buffer_get_glyph_infos(buffer, &glyph_count);
    const pos = hb.hb_buffer_get_glyph_positions(buffer, &glyph_count);

    data.buffer = buffer;
    data.glyphs = info;
    data.positions = pos;
    data.count = glyph_count;
}

// 查找或创建 HarfBuzz 字体
fn findFont(self: *Self, font: ?*anyopaque) ?*hb.hb_font_t {
    for (self.hb_font_cache.items) |entry| {
        if (entry.font == font) {
            return entry.hbfont;
        }
    }

    // 创建新的 HarfBuzz 字体
    if (font) |f| {
        const face: ft.FT_Face = @ptrCast(@alignCast(f));
        // HarfBuzz 的 cimport 可能使用不同的 FT_Face 类型定义
        // 使用 @ptrCast 强制转换
        const hb_ft_face: hb.FT_Face = @ptrCast(@alignCast(face));
        const hbfont = hb.hb_ft_font_create(hb_ft_face, null) orelse return null;

        // 设置字体为 FreeType 加载模式
        hb.hb_ft_font_set_funcs(hbfont);

        self.hb_font_cache.append(self.allocator.?, .{
            .font = f,
            .hbfont = hbfont,
        }) catch {
            hb.hb_font_destroy(hbfont);
            return null;
        };
        return hbfont;
    }

    return null;
}

// 清理 HarfBuzz 字体缓存
pub fn deinit(self: *Self) void {
    for (self.hb_font_cache.items) |entry| {
        _ = hb.hb_font_destroy(entry.hbfont);
        // SDL2_ttf 的字体不需要解锁
    }
    const allocator = self.allocator orelse return;
    self.hb_font_cache.deinit(allocator);
    self.allocator = null;
}
