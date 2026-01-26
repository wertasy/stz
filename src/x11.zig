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
pub const HbTransformData = extern struct {
    buffer: *c.hb_buffer_t,
    glyphs: [*c]c.hb_glyph_info_t,
    positions: [*c]c.hb_glyph_position_t,
    count: c_uint,
};

// HarfBuzz 字体缓存
const HbFontEntry = struct {
    xfont: *c.XftFont,
    hbfont: *c.hb_font_t,
};

var hb_font_cache: std.ArrayList(HbFontEntry) = undefined;
var hb_cache_initialized = false;

// 初始化 HarfBuzz 字体缓存
pub fn initHbCache(allocator: std.mem.Allocator) void {
    if (!hb_cache_initialized) {
        hb_font_cache = std.ArrayList(HbFontEntry).init(allocator);
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
        hb_font_cache.deinit();
        hb_cache_initialized = false;
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

    hb_font_cache.append(.{ .xfont = xfont, .hbfont = hbfont }) catch {
        c.hb_font_destroy(hbfont);
        c.XftUnlockFace(xfont);
        return null;
    };

    return hbfont;
}

// HarfBuzz 形状转换
pub fn hbtransform(data: *HbTransformData, xfont: *c.XftFont, glyphs: []const types.Glyph, start: usize, length: usize) void {
    const hbfont = hbfindfont(xfont) orelse return;

    const buffer = c.hb_buffer_create();
    defer c.hb_buffer_destroy(buffer);

    c.hb_buffer_set_direction(buffer, c.HB_DIRECTION_LTR);
    c.hb_buffer_set_cluster_level(buffer, c.HB_BUFFER_CLUSTER_LEVEL_MONOTONE_CHARACTERS);

    var runes: [256]u32 = undefined;
    for (0..length) |i| {
        runes[i] = glyphs[start + i].u;
    }
    c.hb_buffer_add_codepoints(buffer, &runes, @intCast(length), 0, @intCast(length));

    c.hb_shape(hbfont, buffer, null, 0);

    var glyph_count: c_uint = 0;
    const info = c.hb_buffer_get_glyph_infos(buffer, &glyph_count);
    const pos = c.hb_buffer_get_glyph_positions(buffer, &glyph_count);

    data.buffer = buffer;
    data.glyphs = info;
    data.positions = pos;
    data.count = glyph_count;
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
