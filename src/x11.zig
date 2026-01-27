//! X11 C API bindings
const std = @import("std");
const types = @import("types.zig");

pub const c = @cImport({
    @cInclude("X11/Xlib.h");
    @cInclude("X11/Xatom.h");
    @cInclude("X11/Xutil.h");
    @cInclude("X11/Xft/Xft.h");
    @cInclude("X11/cursorfont.h");
    @cInclude("X11/keysym.h");
    @cInclude("X11/XKBlib.h");
    @cInclude("fontconfig/fontconfig.h");
    @cInclude("hb.h");
    @cInclude("hb-ft.h");
});

// Helper function to get clipboard atom
pub fn getClipboardAtom(dpy: *c.Display) c.Atom {
    return c.XInternAtom(dpy, "CLIPBOARD", c.False);
}

// HarfBuzz 辅助数据结构
pub const HbTransformData = struct {
    buffer: ?*c.hb_buffer_t,
    glyphs: [*c]c.hb_glyph_info_t,
    positions: [*c]c.hb_glyph_position_t,
    count: c_uint,
};

// HarfBuzz 字体缓存
const HbFontEntry = struct {
    xfont: *c.XftFont,
    hbfont: *c.hb_font_t,
};

// 包装类型以处理可选字段
const HbFontEntryOpt = struct {
    xfont: *c.XftFont,
    hbfont: ?*c.hb_font_t,
};

var hb_font_cache: std.ArrayList(HbFontEntry) = undefined;
var hb_cache_allocator: ?std.mem.Allocator = null;
var hb_cache_initialized = false;

// 初始化 HarfBuzz 字体缓存
pub fn initHbCache(allocator: std.mem.Allocator) void {
    if (!hb_cache_initialized) {
        hb_cache_allocator = allocator;
        hb_font_cache = std.ArrayList(HbFontEntry).initCapacity(allocator, 16) catch return;
        hb_cache_initialized = true;
    }
}

// 清理 HarfBuzz 字体缓存
pub fn deinitHbCache() void {
    if (hb_cache_initialized) {
        for (hb_font_cache.items) |entry| {
            _ = c.hb_font_destroy(entry.hbfont);
            c.XftUnlockFace(entry.xfont);
        }
        const allocator = hb_cache_allocator orelse return;
        hb_font_cache.deinit(allocator);
        hb_cache_initialized = false;
        hb_cache_allocator = null;
    }
}

// 查找或创建 HarfBuzz 字体
pub fn hbfindfont(xfont: *c.XftFont) ?*c.hb_font_t {
    if (!hb_cache_initialized) return null;

    for (hb_font_cache.items) |entry| {
        if (entry.xfont == xfont) {
            return entry.hbfont;
        }
    }

    // 创建新的 HarfBuzz 字体
    const face = c.XftLockFace(xfont);
    if (face == null) return null;

    const hbfont = c.hb_ft_font_create(face, null);
    if (hbfont == null) {
        c.XftUnlockFace(xfont);
        return null;
    }

    // 获取 allocator
    const allocator = hb_cache_allocator orelse {
        c.hb_font_destroy(hbfont);
        c.XftUnlockFace(xfont);
        return null;
    };

    const hbfont_nonnull = hbfont orelse {
        c.XftUnlockFace(xfont);
        return null;
    };

    hb_font_cache.append(allocator, .{ .xfont = xfont, .hbfont = hbfont_nonnull }) catch {
        c.hb_font_destroy(hbfont_nonnull);
        c.XftUnlockFace(xfont);
        return null;
    };

    return hbfont_nonnull;
}

// HarfBuzz 形状转换
pub fn hbtransform(data: *HbTransformData, xfont: *c.XftFont, glyphs: []const types.Glyph, start: usize, length: usize) void {
    _ = length; // 这里的 length 是有效字符数，但我们通过遍历 glyphs 并跳过 dummy 来隐式处理
    const hbfont = hbfindfont(xfont) orelse return;

    const buffer = c.hb_buffer_create();
    if (buffer == null) return;

    c.hb_buffer_set_direction(buffer, c.HB_DIRECTION_LTR);
    c.hb_buffer_set_cluster_level(buffer, c.HB_BUFFER_CLUSTER_LEVEL_MONOTONE_CHARACTERS);
    c.hb_buffer_set_content_type(buffer, c.HB_BUFFER_CONTENT_TYPE_UNICODE);

    // 遍历所有字符，跳过 wide_dummy，并使用原始索引作为 cluster
    // start 参数是相对于 glyphs 切片的偏移量
    for (start..glyphs.len) |i| {
        if (!glyphs[i].attr.wide_dummy) {
            c.hb_buffer_add(buffer, glyphs[i].u, @intCast(i));
        }
    }
    // 注意：不再使用 hb_buffer_add_codepoints，因为它不支持自定义 cluster 映射（对于非连续索引）
    // 且我们需要跳过 dummy 字符

    c.hb_shape(hbfont, buffer, null, 0);

    var glyph_count: c_uint = 0;
    const info = c.hb_buffer_get_glyph_infos(buffer, &glyph_count);
    const pos = c.hb_buffer_get_glyph_positions(buffer, &glyph_count);

    // 保存 buffer 指针，不销毁它（调用者负责调用 hbcleanup）
    data.buffer = buffer;
    data.glyphs = info;
    data.positions = pos;
    data.count = glyph_count;
}

// 清理 HarfBuzz 变换数据
pub fn hbcleanup(data: *HbTransformData) void {
    if (data.buffer) |buf| {
        c.hb_buffer_destroy(buf);
        data.buffer = null;
    }
    data.glyphs = null;
    data.positions = null;
    data.count = 0;
}

pub fn getPrimaryAtom(dpy: *c.Display) c.Atom {
    return c.XInternAtom(dpy, "PRIMARY", c.False);
}

pub fn getStringAtom(dpy: *c.Display) c.Atom {
    return c.XInternAtom(dpy, "STRING", c.False);
}

pub fn getUtf8Atom(dpy: *c.Display) c.Atom {
    return c.XInternAtom(dpy, "UTF8_STRING", c.False);
}

pub fn getTargetsAtom(dpy: *c.Display) c.Atom {
    return c.XInternAtom(dpy, "TARGETS", c.False);
}

pub fn getDeleteWindowAtom(dpy: *c.Display) c.Atom {
    return c.XInternAtom(dpy, "WM_DELETE_WINDOW", c.False);
}
