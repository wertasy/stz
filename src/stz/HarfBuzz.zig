const std = @import("std");
const stz = @import("stz");
const types = stz.types;

const hb = stz.c.hb;
const x11 = stz.c.x11;

// HarfBuzz 字体缓存
const FontPair = struct {
    xfont: *x11.XftFont,
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

const Self = @This();

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
pub fn transform(self: *Self, data: *TransformData, xfont: *x11.XftFont, glyphs: []const types.Glyph, start: usize, length: usize) void {
    _ = length; // 这里的 length 是有效字符数，但我们通过遍历 glyphs 并跳过 dummy 来隐式处理
    const hbfont = self.findFont(xfont) orelse return;

    const buffer = data.buffer;
    hb.hb_buffer_reset(buffer);

    hb.hb_buffer_set_direction(buffer, hb.HB_DIRECTION_LTR);
    hb.hb_buffer_set_cluster_level(buffer, hb.HB_BUFFER_CLUSTER_LEVEL_MONOTONE_CHARACTERS);
    hb.hb_buffer_set_content_type(buffer, hb.HB_BUFFER_CONTENT_TYPE_UNICODE);

    // 遍历所有字符，保留 wide_dummy (替换为空格)，以保持索引对齐 (st 逻辑)
    // start 参数是相对于 glyphs 切片的偏移量
    for (start..glyphs.len) |i| {
        // 跳过 wide_dummy，不添加到 buffer
        if (glyphs[i].attr.wide_dummy) {
            continue;
        }
        hb.hb_buffer_add(buffer, glyphs[i].codepoint, @intCast(i));
    }
    // 注意：不再使用 hb_buffer_add_codepoints，因为它不支持自定义 cluster 映射（对于非连续索引）

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
fn findFont(self: *Self, xfont: *x11.XftFont) ?*hb.hb_font_t {
    for (self.hb_font_cache.items) |entry| {
        if (entry.xfont == xfont) {
            return entry.hbfont;
        }
    }

    // 创建新的 HarfBuzz 字体
    const face = x11.XftLockFace(xfont);
    if (face == null) return null;

    const hbfont = hb.hb_ft_font_create(@ptrCast(face), null);
    if (hbfont == null) {
        x11.XftUnlockFace(xfont);
        return null;
    }

    // 获取 allocator
    const allocator = self.allocator orelse {
        hb.hb_font_destroy(hbfont);
        x11.XftUnlockFace(xfont);
        return null;
    };

    const hbfont_nonnull = hbfont orelse {
        x11.XftUnlockFace(xfont);
        return null;
    };

    self.hb_font_cache.append(allocator, .{ .xfont = xfont, .hbfont = hbfont_nonnull }) catch {
        hb.hb_font_destroy(hbfont_nonnull);
        x11.XftUnlockFace(xfont);
        return null;
    };

    return hbfont_nonnull;
}

// 清理 HarfBuzz 字体缓存
pub fn deinit(self: *Self) void {
    for (self.hb_font_cache.items) |entry| {
        _ = hb.hb_font_destroy(entry.hbfont);
        x11.XftUnlockFace(entry.xfont);
    }
    const allocator = self.allocator orelse return;
    self.hb_font_cache.deinit(allocator);
    self.allocator = null;
}
